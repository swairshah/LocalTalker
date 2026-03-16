import Foundation

final class PiRPCClient {

    enum Event {
        case agentStart
        case agentEnd
        case textDelta(String)
        case textEnd(String)
        case toolStart(name: String, id: String)
        case toolEnd(name: String, id: String)
        case stateResponse(isStreaming: Bool, sessionId: String?)
        case response(command: String, success: Bool, error: String?)
        case error(String)
        case processExited(Int32)
    }

    var onEvent: ((Event) -> Void)?

    private(set) var isRunning = false
    private(set) var isStreaming = false

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let queue = DispatchQueue(label: "commander.rpc", qos: .userInitiated)
    private var nextRequestId = 1
    private var stdoutRawBuffer = Data()

    deinit {
        stop()
    }

    func start(
        provider: String? = nil,
        model: String? = nil,
        systemPrompt: String? = nil,
        workingDirectory: String? = nil,
        sessionDir: String? = nil,
        continueSession: Bool = false
    ) throws {
        guard !isRunning else { return }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        guard let piPath = findPiBinary() else {
            throw RPCError.piNotFound
        }

        proc.executableURL = URL(fileURLWithPath: piPath)

        var args = ["--mode", "rpc"]
        if let provider { args += ["--provider", provider] }
        if let model { args += ["--model", model] }
        if let systemPrompt { args += ["--append-system-prompt", systemPrompt] }
        if let sessionDir { args += ["--session-dir", sessionDir] }
        if continueSession { args += ["--continue"] }
        proc.arguments = args

        if let workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        proc.environment = ProcessInfo.processInfo.environment
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.handleStdoutRawData(data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("Commander [pi-rpc stderr]: \(trimmed)")
            }
        }

        proc.terminationHandler = { [weak self] proc in
            self?.queue.async {
                self?.isRunning = false
                self?.isStreaming = false
                self?.onEvent?(.processExited(proc.terminationStatus))
            }
        }

        try proc.run()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                if let proc = self?.process, proc.isRunning {
                    proc.interrupt()
                }
            }
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
        isStreaming = false
        stdoutRawBuffer = Data()
    }

    func sendPrompt(_ text: String) {
        let id = nextId()
        sendCommand(["id": id, "type": "prompt", "message": text])
        isStreaming = true
    }

    func steer(_ text: String) {
        sendCommand(["type": "steer", "message": text])
    }

    func followUp(_ text: String) {
        sendCommand(["type": "follow_up", "message": text])
    }

    func abort() {
        sendCommand(["type": "abort"])
    }

    func getState() {
        let id = nextId()
        sendCommand(["id": id, "type": "get_state"])
    }

    func newSession() {
        sendCommand(["type": "new_session"])
    }

    private func nextId() -> String {
        defer { nextRequestId += 1 }
        return "commander-\(nextRequestId)"
    }

    private func sendCommand(_ command: [String: Any]) {
        guard isRunning, let pipe = stdinPipe else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            var line = data
            line.append(0x0A)
            pipe.fileHandleForWriting.write(line)
        } catch {
            print("Commander: failed to serialize RPC command: \(error)")
        }
    }

    private func handleStdoutRawData(_ data: Data) {
        stdoutRawBuffer.append(data)

        while let newlineIndex = stdoutRawBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutRawBuffer[stdoutRawBuffer.startIndex..<newlineIndex]
            stdoutRawBuffer.removeSubrange(stdoutRawBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            parseEvent(line)
        }
    }

    private func parseEvent(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "response":
            let command = json["command"] as? String ?? "unknown"
            let success = json["success"] as? Bool ?? false
            let error = json["error"] as? String

            if command == "get_state", success, let stateData = json["data"] as? [String: Any] {
                let streaming = stateData["isStreaming"] as? Bool ?? false
                let sessionId = stateData["sessionId"] as? String
                isStreaming = streaming
                onEvent?(.stateResponse(isStreaming: streaming, sessionId: sessionId))
            } else {
                onEvent?(.response(command: command, success: success, error: error))
            }

        case "agent_start":
            isStreaming = true
            onEvent?(.agentStart)

        case "agent_end":
            isStreaming = false
            onEvent?(.agentEnd)

        case "message_update":
            if let delta = json["assistantMessageEvent"] as? [String: Any] {
                switch delta["type"] as? String ?? "" {
                case "text_delta":
                    if let text = delta["delta"] as? String {
                        onEvent?(.textDelta(text))
                    }
                case "text_end":
                    if let content = delta["content"] as? String {
                        onEvent?(.textEnd(content))
                    }
                default:
                    break
                }
            }

        case "tool_execution_start":
            onEvent?(.toolStart(name: json["toolName"] as? String ?? "unknown", id: json["toolCallId"] as? String ?? ""))

        case "tool_execution_end":
            onEvent?(.toolEnd(name: json["toolName"] as? String ?? "unknown", id: json["toolCallId"] as? String ?? ""))

        case "extension_ui_request":
            handleExtensionUIRequest(json)

        case "extension_error":
            onEvent?(.error(json["error"] as? String ?? "unknown extension error"))

        default:
            break
        }
    }

    private func handleExtensionUIRequest(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let method = json["method"] as? String else { return }

        switch method {
        case "select", "input", "editor":
            sendCommand(["type": "extension_ui_response", "id": id, "cancelled": true])
        case "confirm":
            sendCommand(["type": "extension_ui_response", "id": id, "confirmed": true])
        default:
            break
        }
    }

    private func findPiBinary() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.nvm/versions/node/v22.16.0/bin/pi" },
            "/usr/local/bin/pi",
            "/opt/homebrew/bin/pi",
        ].compactMap { $0 }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let which = Process()
        let pipe = Pipe()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["pi"]
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let output, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }

        return nil
    }

    enum RPCError: LocalizedError {
        case piNotFound

        var errorDescription: String? {
            switch self {
            case .piNotFound: return "Could not find the pi binary"
            }
        }
    }
}
