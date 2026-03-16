import Foundation

// MARK: - Tool Definitions

struct ToolDefinition: Identifiable {
    let name: String
    let description: String
    let parameters: [String: Any]   // JSON Schema object

    var id: String { name }

    /// Convert to the OpenAI-compatible `tools` array element.
    func toAPIDict() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ] as [String: Any],
        ]
    }
}

// MARK: - Tool Call / Result

struct ToolCall: Identifiable {
    let id: String
    let name: String
    let arguments: [String: Any]

    var argumentsJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

struct ToolResult {
    let callId: String
    let content: String
    let isError: Bool
}

// MARK: - Tool Permission

enum ToolPermissionType: String, Codable {
    case ask
    case alwaysAllow = "always_allow"
    case alwaysDeny  = "always_deny"
}

// MARK: - ToolPermissionStore

@MainActor
final class ToolPermissionStore: ObservableObject {
    static let shared = ToolPermissionStore()

    /// Permission map keyed by scope.
    /// Examples:
    /// - "read_file"
    /// - "write_file"
    /// - "run_command::ls"
    /// - "run_command::rm"
    @Published var permissions: [String: ToolPermissionType] = [:]

    /// The tool call currently awaiting user approval, if any.
    @Published var pendingApproval: ToolCall?
    /// Whether the user checked "Remember my choice".
    @Published var rememberChoice = false

    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    private let storageKey = "localtalker.toolPermissions"

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: ToolPermissionType].self, from: data) else {
            return
        }
        permissions = decoded

        // Safety migration: remove old broad run_command permissions.
        // We now scope command execution by command name (run_command::ls, run_command::rm, ...).
        if permissions["run_command"] != nil {
            permissions.removeValue(forKey: "run_command")
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(permissions) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - Permission Scope

    /// Permission scope key for a tool call.
    /// - run_command is scoped per command executable (e.g. run_command::ls)
    /// - other tools remain scoped by tool name.
    func permissionKey(for toolCall: ToolCall) -> String {
        guard toolCall.name == "run_command" else { return toolCall.name }

        let raw = (toolCall.arguments["command"] as? String) ?? ""
        let cmd = Self.extractCommandName(from: raw)
        return "run_command::\(cmd)"
    }

    /// Best-effort command extraction for shell input.
    private nonisolated static func extractCommandName(from command: String) -> String {
        let tokens = command
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !tokens.isEmpty else { return "unknown" }

        let wrappers: Set<String> = ["sudo", "env", "/usr/bin/env", "command", "builtin", "nohup", "time"]

        for tok in tokens {
            // Skip env assignments: FOO=bar
            if tok.contains("=") && !tok.hasPrefix("/") && !tok.hasPrefix("./") {
                continue
            }
            if wrappers.contains(tok) { continue }

            // Normalize basename + lowercase
            let name = URL(fileURLWithPath: tok).lastPathComponent.lowercased()
            return name.isEmpty ? "unknown" : name
        }

        return "unknown"
    }

    // MARK: - Check & Request

    /// Returns `true` if the tool call is allowed.
    /// May suspend while showing an approval dialog.
    func requestPermission(for toolCall: ToolCall) async -> Bool {
        let key = permissionKey(for: toolCall)
        let perm = permissions[key] ?? .ask

        switch perm {
        case .alwaysAllow:
            print("🔧 [TOOL PERM] \(key) → auto-allowed")
            return true
        case .alwaysDeny:
            print("🔧 [TOOL PERM] \(key) → auto-denied")
            return false
        case .ask:
            break
        }

        // Show approval UI and wait for decision.
        return await withCheckedContinuation { continuation in
            self.approvalContinuation = continuation
            self.rememberChoice = false
            self.pendingApproval = toolCall
            print("🔧 [TOOL PERM] \(key) → asking user")
        }
    }

    /// Called from the UI when the user taps Allow or Deny.
    func resolve(allowed: Bool) {
        guard let call = pendingApproval else { return }
        let key = permissionKey(for: call)

        if rememberChoice {
            permissions[key] = allowed ? .alwaysAllow : .alwaysDeny
            save()
            print("🔧 [TOOL PERM] Saved preference for \(key): \(allowed ? "always_allow" : "always_deny")")
        }

        pendingApproval = nil
        approvalContinuation?.resume(returning: allowed)
        approvalContinuation = nil
    }

    /// Reset a single permission scope back to "ask".
    func resetPermission(for key: String) {
        permissions[key] = .ask
        save()
    }

    /// Reset all permissions.
    func resetAll() {
        permissions.removeAll()
        save()
    }
}

// MARK: - ToolManager (execution engine)

@MainActor
final class ToolManager {
    static let shared = ToolManager()

    let availableTools: [ToolDefinition] = [
        ToolDefinition(
            name: "run_command",
            description: "Execute a shell command on the user's macOS machine and return stdout/stderr. Use for system tasks, file operations, building projects, etc.",
            parameters: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The shell command to execute (runs in /bin/bash -c)",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["command"],
            ] as [String: Any]
        ),
        ToolDefinition(
            name: "read_file",
            description: "Read the contents of a file at the given path.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Absolute or relative file path to read",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["path"],
            ] as [String: Any]
        ),
        ToolDefinition(
            name: "list_directory",
            description: "List files and directories at the given path.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Directory path to list (defaults to home directory)",
                    ] as [String: Any],
                ] as [String: Any],
                "required": [],
            ] as [String: Any]
        ),
        ToolDefinition(
            name: "write_file",
            description: "Write content to a file, creating it if it doesn't exist.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "File path to write to",
                    ] as [String: Any],
                    "content": [
                        "type": "string",
                        "description": "Content to write",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["path", "content"],
            ] as [String: Any]
        ),
    ]

    /// Convert tools to the OpenAI `tools` array for the API request.
    var toolsPayload: [[String: Any]] {
        availableTools.map { $0.toAPIDict() }
    }

    /// Execute a tool call and return the result.
    func execute(_ call: ToolCall) async -> ToolResult {
        let args = call.arguments

        switch call.name {
        case "run_command":
            return await executeRunCommand(args)
        case "read_file":
            return executeReadFile(args)
        case "list_directory":
            return executeListDirectory(args)
        case "write_file":
            return executeWriteFile(args)
        default:
            return ToolResult(callId: call.id, content: "Unknown tool: \(call.name)", isError: true)
        }
    }

    // MARK: - Tool Implementations

    private func executeRunCommand(_ args: [String: Any]) async -> ToolResult {
        guard let command = args["command"] as? String else {
            return ToolResult(callId: "", content: "Missing 'command' argument", isError: true)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = Constants.appSupportDir // ~/.LocalTalker

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            let status = process.terminationStatus
            var result = ""
            if !outStr.isEmpty { result += outStr }
            if !errStr.isEmpty { result += (result.isEmpty ? "" : "\n") + "stderr: " + errStr }
            if result.isEmpty { result = "(no output)" }
            result = "exit code: \(status)\n" + result

            // Truncate very long output
            if result.count > 8000 {
                result = String(result.prefix(8000)) + "\n... (truncated)"
            }

            return ToolResult(callId: "", content: result, isError: status != 0)
        } catch {
            return ToolResult(callId: "", content: "Failed to run command: \(error.localizedDescription)", isError: true)
        }
    }

    private func executeReadFile(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String else {
            return ToolResult(callId: "", content: "Missing 'path' argument", isError: true)
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        do {
            var content = try String(contentsOfFile: expandedPath, encoding: .utf8)
            if content.count > 16000 {
                content = String(content.prefix(16000)) + "\n... (truncated)"
            }
            return ToolResult(callId: "", content: content, isError: false)
        } catch {
            return ToolResult(callId: "", content: "Error reading file: \(error.localizedDescription)", isError: true)
        }
    }

    private func executeListDirectory(_ args: [String: Any]) -> ToolResult {
        let path = (args["path"] as? String) ?? NSHomeDirectory()
        let expandedPath = NSString(string: path).expandingTildeInPath

        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: expandedPath)
            let listing = items.sorted().joined(separator: "\n")
            return ToolResult(callId: "", content: listing.isEmpty ? "(empty directory)" : listing, isError: false)
        } catch {
            return ToolResult(callId: "", content: "Error listing directory: \(error.localizedDescription)", isError: true)
        }
    }

    private func executeWriteFile(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String,
              let content = args["content"] as? String else {
            return ToolResult(callId: "", content: "Missing 'path' or 'content' argument", isError: true)
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        do {
            // Create parent directories if needed
            let dir = (expandedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
            return ToolResult(callId: "", content: "Successfully wrote \(content.count) characters to \(path)", isError: false)
        } catch {
            return ToolResult(callId: "", content: "Error writing file: \(error.localizedDescription)", isError: true)
        }
    }
}
