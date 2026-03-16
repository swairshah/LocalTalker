import Foundation
import Combine

/// Polls CPU and memory usage for a target process (llama-server) and the system overall.
@MainActor
final class ResourceMonitor: ObservableObject {

    struct Stats {
        var processCPU: Double = 0        // llama-server CPU % (instantaneous)
        var processMemoryMB: Double = 0   // llama-server RSS in MB
        var systemMemoryUsedGB: Double = 0
        var systemMemoryTotalGB: Double = 0
    }

    @Published private(set) var stats = Stats()
    @Published private(set) var isMonitoring = false

    private var timer: Timer?
    private var pidProvider: (() -> Int32?)?

    /// Start monitoring. `pidProvider` returns the current llama-server PID (or nil).
    func start(pidProvider: @escaping () -> Int32?) {
        self.pidProvider = pidProvider
        isMonitoring = true
        // Immediate first sample
        Task { await sample() }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sample()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    private func sample() async {
        // System memory via host_statistics64
        let sysMem = Self.systemMemory()
        stats.systemMemoryTotalGB = sysMem.total
        stats.systemMemoryUsedGB = sysMem.used

        // Process stats
        guard let pid = pidProvider?() else {
            stats.processCPU = 0
            stats.processMemoryMB = 0
            return
        }
        let procStats = await Self.processStats(pid: pid)
        stats.processCPU = procStats.cpu
        stats.processMemoryMB = procStats.memMB
    }

    // MARK: - System memory (Mach API)

    private static func systemMemory() -> (total: Double, used: Double) {
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / (1024 * 1024 * 1024)

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &size)
            }
        }

        guard result == KERN_SUCCESS else { return (totalGB, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vmStats.active_count) * pageSize
        let wired = Double(vmStats.wire_count) * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize
        let usedGB = (active + wired + compressed) / (1024 * 1024 * 1024)

        return (totalGB, usedGB)
    }

    // MARK: - Process stats (top -l 1 for instantaneous CPU)

    private static func processStats(pid: Int32) async -> (cpu: Double, memMB: Double) {
        // Use `top -l 1 -pid PID -stats cpu,mem` for instantaneous CPU%.
        // `ps -o %cpu` gives a lifetime average which reads 0 for mostly-idle servers.
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        proc.arguments = ["-l", "2", "-pid", "\(pid)", "-stats", "cpu,mem"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (0, 0)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return (0, 0)
        }

        // top outputs 2 samples (first is always cumulative, second is instantaneous).
        // Format: header lines then "CPU  MEM" lines.
        // We want the last data line.
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                // Data lines are like "12.3  100M" or "0.0  2560M+"
                let first = line.split(whereSeparator: { $0.isWhitespace }).first ?? ""
                return Double(first) != nil
            }

        guard let last = lines.last else { return (0, 0) }

        let parts = last.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return (0, 0) }

        let cpu = Double(parts[0]) ?? 0

        // Memory from top: "2560M", "2560M+", "12G", "500K" etc.
        let memStr = String(parts[1]).replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        let memMB: Double
        if memStr.hasSuffix("G") {
            memMB = (Double(memStr.dropLast()) ?? 0) * 1024
        } else if memStr.hasSuffix("M") {
            memMB = Double(memStr.dropLast()) ?? 0
        } else if memStr.hasSuffix("K") {
            memMB = (Double(memStr.dropLast()) ?? 0) / 1024
        } else {
            memMB = (Double(memStr) ?? 0) / (1024 * 1024) // bytes
        }

        return (cpu, memMB)
    }
}
