import Foundation

@MainActor
final class TranscriptStore: ObservableObject {

    struct Message: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let role: Role
        var text: String
        let isComplete: Bool
        /// For `.toolCall` role messages — the pending tool call.
        var pendingToolCall: ToolCall?

        enum Role {
            case user
            case assistant
            case system
            case toolCall
            case toolResult
        }
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var logs: [String] = []

    private var currentAssistantText = ""
    private var isAccumulating = false

    func addUserMessage(_ text: String) {
        if isAccumulating { endAssistantMessage() }
        messages.append(Message(role: .user, text: text, isComplete: true))
        trimIfNeeded()
    }

    func beginAssistantMessage() {
        if isAccumulating { endAssistantMessage() }
        currentAssistantText = ""
        isAccumulating = true
        messages.append(Message(role: .assistant, text: "", isComplete: false))
    }

    func appendAssistantDelta(_ delta: String) {
        if !isAccumulating { beginAssistantMessage() }
        currentAssistantText += delta
        if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
            messages[lastIndex] = Message(role: .assistant, text: currentAssistantText, isComplete: false)
        }
    }

    func endAssistantMessage() {
        guard isAccumulating else { return }
        isAccumulating = false
        if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
            messages[lastIndex] = Message(role: .assistant, text: currentAssistantText, isComplete: true)
        }
        currentAssistantText = ""
        trimIfNeeded()
    }

    func addSystemMessage(_ text: String) {
        messages.append(Message(role: .system, text: text, isComplete: true))
        trimIfNeeded()
    }

    func addToolCallMessage(_ call: ToolCall) {
        messages.append(Message(role: .toolCall, text: call.name, isComplete: false, pendingToolCall: call))
    }

    func resolveToolCallMessage(callId: String, allowed: Bool) {
        if let idx = messages.lastIndex(where: { $0.pendingToolCall?.id == callId }) {
            let status = allowed ? "allowed" : "denied"
            messages[idx] = Message(
                role: .toolCall,
                text: "\(messages[idx].text) — \(status)",
                isComplete: true,
                pendingToolCall: nil
            )
        }
    }

    func addToolResultMessage(_ call: ToolCall, result: ToolResult) {
        // Store the full content — the UI will handle truncation + expand
        messages.append(Message(role: .toolResult, text: result.content, isComplete: true))
        trimIfNeeded()
    }

    func addLog(_ text: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(text)")
        trimLogs()
    }

    func logTurn(role: String, text: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let cleaned = text
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logs.append("[\(timestamp)] ── \(role) ──")
        for line in cleaned.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                logs.append("  \(trimmed)")
            }
        }
        logs.append("")
        trimLogs()
    }

    func loadHistory(fromSessionDir dir: String) {
        guard FileManager.default.fileExists(atPath: dir) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)
        guard let latest = jsonlFiles.first else { return }

        let url = URL(fileURLWithPath: dir).appendingPathComponent(latest)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessionMessages = SessionReader.readMessages(from: url, maxMessages: 100)
            guard !sessionMessages.isEmpty else { return }

            let loaded: [Message] = sessionMessages.compactMap { msg in
                let role: Message.Role
                switch msg.role {
                case .user: role = .user
                case .assistant: role = .assistant
                case .system: role = .system
                }

                let text = msg.text
                    .replacingOccurrences(of: "<voice>", with: "")
                    .replacingOccurrences(of: "</voice>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else { return nil }
                return Message(role: role, text: text, isComplete: true)
            }

            Task { @MainActor [weak self] in
                guard let self, !loaded.isEmpty else { return }
                self.messages = loaded
                self.addLog("📖 Loaded \(loaded.count) messages from the previous session")
            }
        }
    }

    func clearMessages() {
        messages.removeAll()
        currentAssistantText = ""
        isAccumulating = false
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func trimLogs() {
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }

    private func trimIfNeeded() {
        if messages.count > 120 {
            messages.removeFirst(messages.count - 120)
        }
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
