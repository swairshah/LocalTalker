import Foundation

@MainActor
final class LlamaCPPClient {

    struct ModelOption: Identifiable, Equatable, Hashable {
        let name: String
        let path: String
        var id: String { path }
    }

    enum Event {
        case agentStart
        case agentEnd
        case textDelta(String)
        case textEnd(String)
        case toolCallsReceived([ToolCall])
        case toolResultAppended(ToolCall, ToolResult)
        case stateResponse(isStreaming: Bool, sessionId: String?)
        case response(command: String, success: Bool, error: String?)
        case error(String)
        case processExited(Int32)
    }

    enum ClientError: LocalizedError {
        case binaryNotFound
        case noModelsFound
        case modelNotFound(String)
        case serverStartFailed
        case requestFailed(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "llama-server binary not found"
            case .noModelsFound:
                return "No GGUF models found. Add models to ~/Library/Application Support/LocalTalker/Models/llama"
            case .modelNotFound(let path):
                return "Model not found: \(path)"
            case .serverStartFailed:
                return "Failed to start llama.cpp server"
            case .requestFailed(let message):
                return "LLM request failed: \(message)"
            case .badResponse:
                return "Invalid response from llama.cpp server"
            }
        }
    }

    var onEvent: ((Event) -> Void)?

    private(set) var isRunning = false
    private(set) var isStreaming = false
    private(set) var currentModel: ModelOption?
    private(set) var sessionId: String? = UUID().uuidString

    /// A message in the chat history. Supports text, assistant tool calls, and tool results.
    private struct ChatMessage {
        let role: String
        let content: String
        let toolCalls: [[String: Any]]?   // For assistant messages with tool_calls
        let toolCallId: String?           // For "tool" role messages (results)

        init(role: String, content: String, toolCalls: [[String: Any]]? = nil, toolCallId: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
        }

        /// Serialize to the OpenAI messages format.
        func toAPIDict() -> [String: Any] {
            var dict: [String: Any] = ["role": role, "content": content]
            if let tc = toolCalls, !tc.isEmpty {
                dict["tool_calls"] = tc
            }
            if let id = toolCallId {
                dict["tool_call_id"] = id
            }
            return dict
        }
    }

    var toolsEnabled = true

    private var systemPrompt: String = ""
    private var history: [ChatMessage] = []
    private var generationTask: Task<Void, Never>?
    private var streamGeneration: Int = 0

    private var serverProcess: Process?
    private let host = "127.0.0.1"
    private let port = 18089

    deinit {
        serverProcess?.terminate()
    }

    func listModels() -> [ModelOption] {
        let fm = FileManager.default
        let searchRoots: [URL] = [
            Constants.modelsDir.appendingPathComponent("llama"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Models"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads"),
        ]

        var found = Set<ModelOption>()

        for root in searchRoots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "gguf" else { continue }
                found.insert(ModelOption(name: fileURL.deletingPathExtension().lastPathComponent, path: fileURL.path))
            }
        }

        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(systemPrompt: String, preferredModelPath: String?) async throws {
        self.systemPrompt = systemPrompt

        let models = listModels()
        guard !models.isEmpty else { throw ClientError.noModelsFound }

        let selected = models.first(where: { $0.path == preferredModelPath }) ?? models[0]
        try await switchModel(path: selected.path)
    }

    func stop() {
        abort()
        stopServer()
        history.removeAll()
        isRunning = false
        isStreaming = false
    }

    func switchModel(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ClientError.modelNotFound(path)
        }

        try await ensureServerRunning(modelPath: path)
        currentModel = ModelOption(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
        history.removeAll()
        sessionId = UUID().uuidString
        onEvent?(.response(command: "switch_model", success: true, error: nil))
    }

    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        abort()
        let generation = streamGeneration

        isStreaming = true
        history.append(ChatMessage(role: "user", content: trimmed))

        print("📤 [LLM gen=\(generation)] sendPrompt — history has \(history.count) msgs:")
        for (i, msg) in history.enumerated() {
            print("   [\(i)] \(msg.role): \(msg.content.prefix(100))")
        }

        onEvent?(.agentStart)

        generationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.streamGeneration == generation else { return }
                    self.isStreaming = false
                    self.generationTask = nil
                    self.onEvent?(.agentEnd)
                }
            }

            do {
                // Tool-calling loop: model may request tools multiple times
                // before producing a final text response.
                var maxRounds = 8
                while maxRounds > 0 {
                    maxRounds -= 1
                    guard !Task.isCancelled else { return }

                    let response = try await self.callCompletion(generation: generation)
                    guard !Task.isCancelled, self.streamGeneration == generation else { return }

                    if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                        // ── Model wants to call tools ──────────────────────
                        // Store the assistant message (with tool_calls) in history
                        await MainActor.run {
                            guard self.streamGeneration == generation else { return }
                            self.history.append(ChatMessage(
                                role: "assistant",
                                content: response.text ?? "",
                                toolCalls: response.rawToolCalls
                            ))
                            self.onEvent?(.toolCallsReceived(toolCalls))
                        }

                        // Execute each tool (with permission checks)
                        for call in toolCalls {
                            guard !Task.isCancelled, self.streamGeneration == generation else { return }

                            let allowed = await ToolPermissionStore.shared.requestPermission(for: call)
                            let result: ToolResult
                            if allowed {
                                result = await ToolManager.shared.execute(call)
                            } else {
                                result = ToolResult(callId: call.id, content: "Tool call denied by user.", isError: true)
                            }

                            await MainActor.run {
                                guard self.streamGeneration == generation else { return }
                                self.history.append(ChatMessage(
                                    role: "tool",
                                    content: result.content,
                                    toolCallId: call.id
                                ))
                                self.onEvent?(.toolResultAppended(call, result))
                            }
                        }
                        // Loop back — the model will see the tool results and continue.
                        continue
                    }

                    // ── Final text response (no tool calls) ────────────
                    let rawReply = response.text ?? ""
                    print("📥 [LLM gen=\(generation)] RAW REPLY: \(rawReply.prefix(300))")

                    // Parse out model-specific tokens (gpt-oss channels, special tokens)
                    let reply = Self.extractFinalResponse(rawReply)
                    print("📥 [LLM gen=\(generation)] CLEANED REPLY: \(reply.prefix(300))")

                    await MainActor.run {
                        guard self.streamGeneration == generation else { return }
                        for chunk in self.chunkReply(reply) {
                            self.onEvent?(.textDelta(chunk))
                        }
                        self.onEvent?(.textEnd(reply))
                        let cleaned = Self.stripTagsForHistory(reply)
                        self.history.append(ChatMessage(role: "assistant", content: cleaned))
                    }
                    break  // Done
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.streamGeneration == generation else { return }
                    self.onEvent?(.error(error.localizedDescription))
                }
            }
        }
    }

    func steer(_ text: String) {
        sendPrompt(text)
    }

    func abort() {
        streamGeneration += 1
        generationTask?.cancel()
        generationTask = nil
        isStreaming = false
    }

    func getState() {
        onEvent?(.stateResponse(isStreaming: isStreaming, sessionId: sessionId))
    }

    func newSession() {
        abort()
        history.removeAll()
        sessionId = UUID().uuidString
        onEvent?(.response(command: "new_session", success: true, error: nil))
    }

    /// Remove any trailing unanswered user message (from an aborted generation).
    func cleanupAfterInterrupt() {
        var removed = 0
        while let last = history.last, last.role == "user" {
            history.removeLast()
            removed += 1
        }
        if removed > 0 {
            print("🧹 [HISTORY] cleanupAfterInterrupt removed \(removed) trailing user msg(s). History now has \(history.count) entries")
        }
    }

    // MARK: - Internals

    private func ensureServerRunning(modelPath: String) async throws {
        if currentModel?.path == modelPath,
           isRunning,
           await checkHealth() {
            return
        }

        stopServer()

        guard let binary = findServerBinary() else {
            throw ClientError.binaryNotFound
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", modelPath,
            "--host", host,
            "--port", "\(port)",
            "--ctx-size", "4096",
            "--threads", "6",
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.onEvent?(.processExited(proc.terminationStatus))
            }
        }

        do {
            try process.run()
            serverProcess = process
        } catch {
            throw ClientError.serverStartFailed
        }

        for _ in 0..<80 {
            if await checkHealth() {
                isRunning = true
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        stopServer()
        throw ClientError.serverStartFailed
    }

    private func stopServer() {
        if let proc = serverProcess, proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                if proc.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        serverProcess = nil
        isRunning = false
    }

    /// Extract the user-facing response from raw model output.
    ///
    /// Handles multiple model output formats:
    /// - **gpt-oss**: Uses `<|channel|>analysis<|message|>...<|channel|>final<|constrain|>...`
    ///   We extract only the "final" channel content.
    /// - **Voice tags**: `<voice>...</voice>` are kept for TTS extraction but stripped from history.
    /// - **Generic special tokens**: `<|...|>` tokens are stripped.
    static func extractFinalResponse(_ raw: String) -> String {
        var text = raw

        // ── gpt-oss channel format ──────────────────────────────────

        // The model outputs multiple channels; we only want "final".
        // Pattern: <|channel|>final<|constrain|>CONTENT or <|channel|>final<|message|>CONTENT
        if text.contains("<|channel|>") {
            // Try to extract the "final" channel content
            if let finalRange = text.range(of: "<|channel|>final") {
                text = String(text[finalRange.upperBound...])
                // Strip the delimiter after "final" (e.g. <|constrain|>, <|message|>)
                if let delimEnd = text.range(of: "|>") {
                    text = String(text[delimEnd.upperBound...])
                }
            }
            // Remove any trailing <|end|>, <|start|>, etc.
            text = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        }

        // ── Generic special token cleanup ───────────────────────────
        // Strip any remaining <|...|> tokens from other models
        text = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip voice/status tags so they never appear in the LLM chat history.
    /// The model sees clean text only; it produces <voice> tags from the
    /// system prompt instruction, not from echoing its own prior output.
    private static func stripTagsForHistory(_ text: String) -> String {
        var cleaned = extractFinalResponse(text)
        cleaned = cleaned
            .replacingOccurrences(of: #"<voice>([\s\S]*?)</voice>"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .replacingOccurrences(of: #"<status>[^<]*</status>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Completion Response

    struct CompletionResponse {
        let text: String?
        let toolCalls: [ToolCall]?
        /// Raw tool_calls dicts to store in history (for the API round-trip).
        let rawToolCalls: [[String: Any]]?
    }

    /// Call the OpenAI-compatible completions endpoint.
    /// Returns text and/or tool calls from the model.
    private func callCompletion(generation: Int) async throws -> CompletionResponse {
        let url = URL(string: "http://\(host):\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let modelName = currentModel?.name ?? "local-model"

        // Build messages array
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in history {
            if msg.role == "assistant" && msg.toolCalls == nil {
                // Clean tags from plain-text assistant messages
                var dict: [String: Any] = [
                    "role": "assistant",
                    "content": Self.stripTagsForHistory(msg.content)
                ]
                if let tc = msg.toolCalls { dict["tool_calls"] = tc }
                messages.append(dict)
            } else {
                messages.append(msg.toAPIDict())
            }
        }

        print("🌐 [API] Sending \(messages.count) messages to llama-server:")
        for (i, msg) in messages.enumerated() {
            let role = msg["role"] as? String ?? "?"
            let content = (msg["content"] as? String ?? "").prefix(120)
            let hasTc = msg["tool_calls"] != nil ? " +tool_calls" : ""
            let tcId = msg["tool_call_id"] as? String
            let tcIdStr = tcId != nil ? " (call_id=\(tcId!))" : ""
            print("   [\(i)] \(role)\(hasTc)\(tcIdStr): \(content)")
        }

        var payload: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": false,
            "temperature": 0.7,
        ]

        // Include tool definitions if enabled
        if toolsEnabled {
            let tools = ToolManager.shared.toolsPayload
            if !tools.isEmpty {
                payload["tools"] = tools
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ClientError.requestFailed(raw)
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw ClientError.badResponse
        }

        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse tool_calls if present
        var toolCalls: [ToolCall]? = nil
        var rawToolCalls: [[String: Any]]? = nil

        if let apiToolCalls = message["tool_calls"] as? [[String: Any]], !apiToolCalls.isEmpty {
            rawToolCalls = apiToolCalls
            toolCalls = apiToolCalls.compactMap { tc -> ToolCall? in
                guard let id = tc["id"] as? String,
                      let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }

                let argsStr = function["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]

                return ToolCall(id: id, name: name, arguments: args)
            }
            if toolCalls?.isEmpty == true { toolCalls = nil }

            print("🔧 [LLM] Tool calls: \(toolCalls?.map { "\($0.name)(\($0.argumentsJSON.prefix(80)))" } ?? [])")
        }

        return CompletionResponse(text: content, toolCalls: toolCalls, rawToolCalls: rawToolCalls)
    }

    private func checkHealth() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func chunkReply(_ text: String) -> [String] {
        guard text.count > 220 else { return [text] }

        var chunks: [String] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let next = text.index(cursor, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
            let slice = text[cursor..<next]
            chunks.append(String(slice))
            cursor = next
        }

        return chunks
    }

    private func findServerBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["LLAMA_SERVER_PATH"],
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            NSHomeDirectory() + "/work/ml/llama.cpp/build/bin/llama-server",
        ].compactMap { $0 }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }
}
