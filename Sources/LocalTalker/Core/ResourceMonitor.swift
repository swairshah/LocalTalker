import Foundation
import Combine

/// Polls CPU and memory usage for a target process (llama-server) and the system overall.
@MainActor
final class ResourceMonitor: ObservableObject {

    struct Stats {
        var processCPU: Double = 0        // llama-server CPU %
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

        // Process stats via `ps`
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
        // "used" = active + wired + compressed (matches Activity Monitor)
        let usedGB = (active + wired + compressed) / (1024 * 1024 * 1024)

        return (totalGB, usedGB)
    }

    // MARK: - Process stats (ps)

    private static func processStats(pid: Int32) async -> (cpu: Double, memMB: Double) {
        // Use ps for simplicity — low overhead at 3s intervals
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "%cpu=,rss="]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (0, 0)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return (0, 0)
        }

        // ps output: "  12.3 123456"  (cpu%, rss in KB)
        let parts = output.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2,
              let cpu = Double(parts[0]),
              let rssKB = Double(parts[1]) else {
            return (0, 0)
        }

        return (cpu, rssKB / 1024.0)
    }
}
