import Foundation
import Combine

/// Polls CPU and memory usage for all LocalTalker sub-processes and the system.
@MainActor
final class ResourceMonitor: ObservableObject {

    struct ProcessStats: Identifiable {
        let id: String       // component name
        let label: String    // display label
        var cpu: Double = 0
        var memMB: Double = 0
        var active: Bool = false
    }

    struct SystemStats {
        var usedGB: Double = 0
        var totalGB: Double = 0
    }

    /// Per-component stats (LLM, TTS, STT, App).
    @Published private(set) var processes: [ProcessStats] = [
        ProcessStats(id: "llm", label: "LLM"),
        ProcessStats(id: "tts", label: "TTS"),
        ProcessStats(id: "stt", label: "STT"),
        ProcessStats(id: "app", label: "App"),
    ]

    @Published private(set) var system = SystemStats()
    @Published private(set) var isMonitoring = false

    /// Sum of all tracked process memory.
    var totalProcessMemMB: Double { processes.reduce(0) { $0 + $1.memMB } }
    /// Sum of all tracked process CPU.
    var totalProcessCPU: Double { processes.reduce(0) { $0 + $1.cpu } }

    private var timer: Timer?
    private var pidProviders: [String: () -> Int32?] = [:]

    /// Start monitoring. Pass PID providers for each component.
    func start(
        llmPID: @escaping () -> Int32?,
        ttsPID: @escaping () -> Int32?
    ) {
        pidProviders = [
            "llm": llmPID,
            "tts": ttsPID,
            "app": { ProcessInfo.processInfo.processIdentifier },
        ]
        isMonitoring = true
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
        // System memory
        let sysMem = Self.systemMemory()
        system = SystemStats(usedGB: sysMem.used, totalGB: sysMem.total)

        // Collect PIDs to query (batch into one top call for efficiency)
        var pidMap: [(index: Int, pid: Int32)] = []
        for (i, proc) in processes.enumerated() {
            if let provider = pidProviders[proc.id], let pid = provider() {
                pidMap.append((i, pid))
            } else {
                processes[i].cpu = 0
                processes[i].memMB = 0
                processes[i].active = false
            }
        }

        // Also look for any running qwen_asr process (transient STT)
        if let sttPid = Self.findProcessPID(named: "qwen_asr") {
            if let sttIdx = processes.firstIndex(where: { $0.id == "stt" }) {
                pidMap.append((sttIdx, sttPid))
            }
        } else {
            if let sttIdx = processes.firstIndex(where: { $0.id == "stt" }) {
                processes[sttIdx].cpu = 0
                processes[sttIdx].memMB = 0
                processes[sttIdx].active = false
            }
        }

        guard !pidMap.isEmpty else { return }

        // Query all PIDs in one ps call
        let pids = pidMap.map { "\($0.pid)" }
        let results = await Self.batchProcessStats(pids: pids)

        for (index, pid) in pidMap {
            let key = "\(pid)"
            if let stats = results[key] {
                processes[index].cpu = stats.cpu
                processes[index].memMB = stats.memMB
                processes[index].active = true
            } else {
                processes[index].cpu = 0
                processes[index].memMB = 0
                processes[index].active = false
            }
        }
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

    // MARK: - Batch process stats (single ps call)

    private static func batchProcessStats(pids: [String]) async -> [String: (cpu: Double, memMB: Double)] {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", pids.joined(separator: ","), "-o", "pid=,%cpu=,rss="]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var results: [String: (cpu: Double, memMB: Double)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3,
                  let cpu = Double(parts[1]),
                  let rssKB = Double(parts[2]) else { continue }
            let pid = String(parts[0])
            results[pid] = (cpu: cpu, memMB: rssKB / 1024.0)
        }
        return results
    }

    // MARK: - Find transient process by name

    private static func findProcessPID(named name: String) -> Int32? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", name]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(output.split(separator: "\n").first ?? "") else { return nil }
        return pid
    }
}
