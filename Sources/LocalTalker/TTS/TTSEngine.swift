import Foundation

final class TTSEngine {

    enum TTSError: Error, LocalizedError {
        case binaryNotFound
        case serverNotRunning
        case synthesizeFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "pocket-tts-cli binary not found"
            case .serverNotRunning: return "TTS server is not running"
            case .synthesizeFailed(let message): return "TTS synthesis failed: \(message)"
            }
        }
    }

    private var serverProcess: Process?
    var isServerRunning = false
    /// PID of the running pocket-tts-cli server, or nil.
    var serverPID: Int32? { serverProcess?.isRunning == true ? serverProcess?.processIdentifier : nil }

    let host = Constants.ttsHost
    let port = Constants.ttsPort

    var defaultVoice: String {
        UserDefaults.standard.string(forKey: "localtalker.voice") ?? "fantine"
    }

    deinit {
        stopServer()
    }

    func startServer() async throws {
        guard let binary = findBinary() else {
            throw TTSError.binaryNotFound
        }

        stopServer()

        let process = Process()

        if let resourcePath = findResourcePath() {
            let voicePath = "\(resourcePath)/models/embeddings/\(defaultVoice).safetensors"
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                "cd '\(resourcePath)' && '\(binary.path)' serve --port \(port) --host \(host) --voice '\(voicePath)'"
            ]

            var env = ProcessInfo.processInfo.environment
            env["POCKET_TTS_VOICES_DIR"] = "\(resourcePath)/models/embeddings"
            if let hfHome = setupModelCache() {
                env["HF_HOME"] = hfHome
            }
            process.environment = env
        } else {
            process.executableURL = binary
            process.arguments = [
                "serve",
                "--host", host,
                "--port", "\(port)",
                "--voice", defaultVoice,
            ]
        }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.serverProcess = nil
                self?.isServerRunning = false
            }
        }

        try process.run()
        serverProcess = process

        for _ in 0..<50 {
            if await checkHealth() {
                isServerRunning = true
                return
            }
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        stopServer()
        throw TTSError.serverNotRunning
    }

    func stopServer() {
        let process = serverProcess
        serverProcess = nil
        isServerRunning = false

        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        // Kill any orphaned TTS servers on our port
        killOrphanedTTS()
    }

    private func killOrphanedTTS() {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti", "tcp:\(port)"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }
        let ownPid = serverProcess?.processIdentifier ?? -1
        for line in output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != ownPid, pid > 0 {
                kill(pid, SIGKILL)
                print("🧹 [TTS] Killed orphaned pocket-tts PID \(pid)")
            }
        }
    }

    func synthesize(text: String, voice: String? = nil) async throws -> Data {
        guard isServerRunning else {
            throw TTSError.serverNotRunning
        }

        let url = URL(string: "http://\(host):\(port)/stream")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "voice": voice ?? defaultVoice
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw TTSError.synthesizeFailed(message)
        }
        return data
    }

    func checkHealth() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func findBinary() -> URL? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resourcePath).appendingPathComponent("pocket-tts-cli")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        let candidates = [
            "/opt/homebrew/bin/pocket-tts-cli",
            "/usr/local/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.cargo/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.local/bin/pocket-tts-cli",
            NSHomeDirectory() + "/work/ml/pocket-tts/target/release/pocket-tts-cli",
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func findResourcePath() -> String? {
        let loquiApps = [
            "/Applications/Loqui.app/Contents/Resources",
            NSHomeDirectory() + "/Applications/Loqui.app/Contents/Resources",
        ]

        for path in loquiApps {
            let binary = path + "/pocket-tts-cli"
            let models = path + "/models/tts_b6369a24.safetensors"
            if FileManager.default.fileExists(atPath: binary), FileManager.default.fileExists(atPath: models) {
                return path
            }
        }

        return nil
    }

    private func setupModelCache() -> String? {
        let cacheDir = Constants.appSupportDir.appendingPathComponent("tts-cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.path
    }
}
