import SwiftUI

private enum Palette {
    static let bg          = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let sidebarBg   = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let cardFill    = Color.white.opacity(0.035)
    static let cardStroke  = Color.white.opacity(0.06)
    static let divider     = Color.white.opacity(0.06)
    static let accent      = Color(red: 0.90, green: 0.72, blue: 0.30)
    static let listening   = Color(red: 0.55, green: 0.78, blue: 0.65)
    static let thinking    = Color(red: 0.82, green: 0.68, blue: 0.50)
    static let speaking    = Color(red: 0.62, green: 0.76, blue: 0.85)
    static let idle        = Color(red: 0.45, green: 0.45, blue: 0.48)
    static let error       = Color(red: 0.85, green: 0.45, blue: 0.42)
    static let micLive     = Color(red: 0.55, green: 0.78, blue: 0.65)
    static let micPaused   = Color(red: 0.82, green: 0.62, blue: 0.40)
    static let sendButton  = Color(red: 0.90, green: 0.72, blue: 0.30)
}

struct MainWindowView: View {
    @ObservedObject var conversationLoop: ConversationLoop
    @State private var selectedTab: Tab = .talk

    enum Tab: String, CaseIterable, Identifiable {
        case talk = "Talk"
        case prompt = "Prompt"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .talk: return "waveform.circle.fill"
            case .prompt: return "text.quote"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject private var permissionStore = ToolPermissionStore.shared

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Palette.divider)
                detail
            }
        }
        .onAppear {
            conversationLoop.refreshModels()
        }
    }

    @State private var showModelPicker = false

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("LocalTalker")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .padding(.top, 14)

            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .frame(width: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedTab == tab ? Color.white.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // ── Model selector ──────────────────────────────
            modelSelector

            // ── Resource monitor ────────────────────────────
            ResourceWidget(monitor: conversationLoop.resourceMonitor)

            // ── Status & shortcuts ──────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                statusPill

                HStack(spacing: 8) {
                    kbd("⌘/", "Mic")
                    kbd("⌘.", "Stop")
                }
                HStack(spacing: 8) {
                    kbd("⌘,", conversationLoop.ttsEnabled ? "TTS on" : "TTS off")
                    kbd("⌘⇧N", "New")
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
        }
        .frame(width: 180)
        .padding(14)
        .foregroundStyle(.white)
    }

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Dropdown header — click to toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showModelPicker.toggle() }
                if showModelPicker { conversationLoop.refreshModels() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text(conversationLoop.selectedModelName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: showModelPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            // Expanded model list
            if showModelPicker {
                VStack(alignment: .leading, spacing: 2) {
                    if conversationLoop.availableModels.isEmpty {
                        Text("No .gguf models")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(conversationLoop.availableModels) { model in
                                    let selected = model.path == conversationLoop.selectedModelPath
                                    Button {
                                        conversationLoop.switchModel(to: model.path)
                                        withAnimation(.easeInOut(duration: 0.15)) { showModelPicker = false }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(selected ? Palette.accent : Color.white.opacity(0.15))
                                                .frame(width: 6, height: 6)
                                            Text(model.name)
                                                .font(.system(size: 11))
                                                .foregroundStyle(selected ? .white : Color.white.opacity(0.65))
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(selected ? Color.white.opacity(0.06) : Color.clear)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.06))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(stateTint).frame(width: 8, height: 8)
            Text(conversationLoop.state.displayName)
                .font(.caption.weight(.semibold))
            Spacer()
            Image(systemName: conversationLoop.isMuted ? "mic.slash" : "mic.fill")
                .font(.caption)
                .foregroundStyle(conversationLoop.isMuted ? Palette.micPaused : Palette.micLive)
        }
    }

    private func kbd(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case .talk:
            TalkView(conversationLoop: conversationLoop)
        case .prompt:
            PromptEditorView(conversationLoop: conversationLoop)
        case .settings:
            SettingsView(conversationLoop: conversationLoop)
        }
    }

    private var stateTint: Color {
        switch conversationLoop.state {
        case .idle: return Palette.idle
        case .listening: return Palette.listening
        case .transcribing: return Palette.thinking
        case .waiting: return Palette.thinking
        case .speaking: return Palette.speaking
        case .error: return Palette.error
        }
    }
}

private struct TalkView: View {
    @ObservedObject var conversationLoop: ConversationLoop
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            ChatTimeline(messages: conversationLoop.transcript.messages)

            Divider().overlay(Palette.divider)

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    LevelMeter(level: conversationLoop.audioLevel, tint: stateTint)
                        .frame(height: 18)

                    Text(conversationLoop.state.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(stateTint.opacity(0.8))
                }

                inputBar
            }
            .padding(12)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Type a message…", text: $inputText)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Palette.idle : Palette.sendButton)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        conversationLoop.sendTypedText(text)
        inputText = ""
    }

    private var stateTint: Color {
        switch conversationLoop.state {
        case .idle: return Palette.idle
        case .listening: return Palette.listening
        case .transcribing: return Palette.thinking
        case .waiting: return Palette.thinking
        case .speaking: return Palette.speaking
        case .error: return Palette.error
        }
    }
}



// MARK: - Prompt Editor

private struct PromptEditorView: View {
    @ObservedObject var conversationLoop: ConversationLoop
    @State private var draft: String = ""
    @State private var showSavedBanner = false

    private var isModified: Bool {
        draft != conversationLoop.systemPrompt
    }

    private var isDefault: Bool {
        conversationLoop.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == ConversationLoop.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Prompt")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(conversationLoop.selectedModelName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                }

                Spacer()

                if showSavedBanner {
                    Text("Saved")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.listening)
                        .transition(.opacity)
                }

                // Restore default
                Button {
                    conversationLoop.restoreDefaultPrompt()
                    draft = conversationLoop.systemPrompt
                } label: {
                    Text("Restore Default")
                        .font(.system(size: 12))
                        .foregroundStyle(isDefault ? Color.white.opacity(0.2) : Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(isDefault)

                // Save
                Button {
                    conversationLoop.systemPrompt = draft
                    conversationLoop.saveSystemPrompt()
                    withAnimation { showSavedBanner = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showSavedBanner = false }
                    }
                } label: {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isModified ? .black : Color.white.opacity(0.3))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isModified ? Palette.accent : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isModified)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Palette.divider)

            // Editor
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .padding(16)
                .background(Color.white.opacity(0.02))
        }
        .onAppear {
            draft = conversationLoop.systemPrompt
        }
        .onChange(of: conversationLoop.selectedModelPath) {
            // Reload when model changes
            draft = conversationLoop.systemPrompt
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var conversationLoop: ConversationLoop
    @ObservedObject var permissionStore = ToolPermissionStore.shared
    @AppStorage("localtalker.voice") private var selectedVoice = "fantine"

    private let voices = ["fantine", "alba", "marius", "javert", "cosette", "eponine", "azelma"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Voice").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(voices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Session").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        infoRow("LLM running", conversationLoop.isAgentRunning ? "Yes" : "No")
                        infoRow("Model", conversationLoop.selectedModelName)
                        infoRow("Session ID", conversationLoop.sessionID ?? "—")
                    }
                }

                // ── Tool Permissions ────────────────────────────
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Tool Permissions").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Spacer()
                            Button {
                                permissionStore.resetAll()
                            } label: {
                                Text("Revoke All")
                                    .font(.caption)
                                    .foregroundStyle(Palette.error)
                            }
                            .buttonStyle(.plain)
                        }

                        let perms = permissionStore.permissions
                        if perms.values.allSatisfy({ $0 == .ask }) {
                            Text("No saved permissions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(perms.sorted(by: { $0.key < $1.key }), id: \.key) { key, perm in
                                if perm != .ask {
                                    let displayKey = key.hasPrefix("run_command::")
                                        ? "run_command (\(String(key.dropFirst("run_command::".count))))"
                                        : key

                                    HStack(spacing: 8) {
                                        Text(displayKey)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text(perm == .alwaysAllow ? "allowed" : "denied")
                                            .font(.caption)
                                            .foregroundStyle(perm == .alwaysAllow ? Color.white.opacity(0.5) : Palette.error.opacity(0.7))
                                        Button {
                                            permissionStore.resetPermission(for: key)
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                                .font(.caption)
                                                .foregroundStyle(Color.white.opacity(0.3))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.white).textSelection(.enabled)
        }
    }
}

private struct ChatTimeline: View {
    let messages: [TranscriptStore.Message]

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { message in
                        ChatRow(message: message, timeFmt: Self.timeFmt)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct ChatRow: View {
    let message: TranscriptStore.Message
    let timeFmt: DateFormatter
    @ObservedObject var permissionStore = ToolPermissionStore.shared
    @State private var isExpanded = false

    /// Max characters shown before truncation (click to expand).
    private static let truncateAt = 500

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                // Header row
                HStack(spacing: 6) {
                    if message.role == .toolCall || message.role == .toolResult {
                        Image(systemName: message.role == .toolCall ? "wrench" : "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(accentColor)
                    }
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(timeFmt.string(from: message.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.25))
                }

                // Tool call with inline approval buttons
                if let pending = message.pendingToolCall {
                    toolCallView(pending)
                } else if message.role == .toolResult {
                    expandableCodeBlock
                } else if message.role == .toolCall {
                    // Resolved tool call — just a short label
                    Text(cleaned)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.4))
                } else {
                    // Normal message — expandable if long
                    expandableText
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Expandable text (normal messages) with markdown

    @ViewBuilder
    private var expandableText: some View {
        let text = cleaned
        let isTruncated = !isExpanded && text.count > Self.truncateAt
        let displayText = isTruncated ? String(text.prefix(Self.truncateAt)) + "…" : text
        let textOpacity = message.role == .system ? 0.5 : 0.85

        VStack(alignment: .leading, spacing: 2) {
            MarkdownView(displayText, opacity: textOpacity)
                .textSelection(.enabled)

            if text.count > Self.truncateAt {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "show less" : "show more")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Expandable code block (tool results)

    @ViewBuilder
    private var expandableCodeBlock: some View {
        let text = cleaned
        let isTruncated = !isExpanded && text.count > Self.truncateAt

        VStack(alignment: .leading, spacing: 2) {
            Text(isTruncated ? String(text.prefix(Self.truncateAt)) + "…" : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.45))
                .textSelection(.enabled)
                .lineSpacing(1)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
                .onTapGesture {
                    if text.count > Self.truncateAt {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    }
                }

            if text.count > Self.truncateAt {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "collapse" : "expand")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Tool call (pending approval)

    @ViewBuilder
    private func toolCallView(_ call: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(for: call.name))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
                Text(permissionScopeLabel(for: call))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            Text(call.argumentsJSON)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
                .lineLimit(6)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )

            // Allow / Deny buttons
            HStack(spacing: 10) {
                Button {
                    permissionStore.resolve(allowed: false)
                } label: {
                    Text("Deny")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    permissionStore.resolve(allowed: true)
                } label: {
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.accent)
                        )
                }
                .buttonStyle(.plain)

                Toggle(isOn: $permissionStore.rememberChoice) {
                    Text("Remember")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func permissionScopeLabel(for call: ToolCall) -> String {
        let key = permissionStore.permissionKey(for: call)
        if key.hasPrefix("run_command::") {
            let cmd = String(key.dropFirst("run_command::".count))
            return "run_command (\(cmd))"
        }
        return call.name
    }

    private func toolIcon(for name: String) -> String {
        switch name {
        case "run_command": return "terminal"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "list_directory": return "folder"
        default: return "wrench"
        }
    }

    private var label: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        case .toolCall: return "Tool"
        case .toolResult: return "Result"
        }
    }

    private var accentColor: Color {
        switch message.role {
        case .user: return Palette.accent
        case .assistant: return Palette.speaking
        case .system: return Palette.idle
        case .toolCall: return Color(white: 0.45)
        case .toolResult: return Color(white: 0.40)
        }
    }

    private var cleaned: String {
        LlamaCPPClient.extractFinalResponse(
            message.text
                .replacingOccurrences(of: "<voice>", with: "")
                .replacingOccurrences(of: "</voice>", with: "")
                .replacingOccurrences(of: #"<status>[^<]*</status>"#, with: "", options: .regularExpression)
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Resource Monitor Widget

private struct ResourceWidget: View {
    @ObservedObject var monitor: ResourceMonitor
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — click to toggle detail
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.35))
                    Text(compactSummary)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer(minLength: 0)
                    Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if showDetail {
                Divider().overlay(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 6) {
                    // Per-component rows
                    ForEach(monitor.processes) { proc in
                        if proc.active {
                            componentRow(proc)
                        }
                    }

                    // Inactive components
                    let inactive = monitor.processes.filter { !$0.active }
                    if !inactive.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(inactive) { proc in
                                Text(proc.label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.white.opacity(0.2))
                            }
                            Text("idle")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.15))
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.04))

                    // System totals
                    HStack(spacing: 4) {
                        Text(String(format: "sys %.1f / %.0f GB",
                                    monitor.system.usedGB,
                                    monitor.system.totalGB))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.25))
                        Spacer()
                        Text(String(format: "total %@", formatMem(monitor.totalProcessMemMB)))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.25))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.05))
        )
    }

    // MARK: - Compact summary (shown in collapsed state)

    private var compactSummary: String {
        let mem = formatMem(monitor.totalProcessMemMB)
        let cpu = String(format: "%.0f%%", monitor.totalProcessCPU)
        return "\(cpu)  \(mem)"
    }

    // MARK: - Per-component row

    private func componentRow(_ proc: ResourceMonitor.ProcessStats) -> some View {
        HStack(spacing: 6) {
            Text(proc.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 24, alignment: .leading)

            // Memory bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barTint(cpu: proc.cpu))
                        .frame(width: max(0, geo.size.width * memFraction(proc.memMB)))
                }
            }
            .frame(height: 4)

            Text(formatMem(proc.memMB))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.35))
                .fixedSize()

            Text(String(format: "%.0f%%", proc.cpu))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(width: 26, alignment: .trailing)
        }
        .frame(height: 12)
    }

    // MARK: - Helpers

    private func formatMem(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1fG", mb / 1024) }
        if mb >= 1 { return String(format: "%.0fM", mb) }
        return "0M"
    }

    private func memFraction(_ mb: Double) -> Double {
        guard monitor.system.totalGB > 0 else { return 0 }
        return min(mb / (monitor.system.totalGB * 1024), 1.0)
    }

    private func barTint(cpu: Double) -> Color {
        if cpu > 80 { return Color(red: 0.85, green: 0.45, blue: 0.40) }
        if cpu > 40 { return Color(red: 0.82, green: 0.68, blue: 0.42) }
        return Color.white.opacity(0.35)
    }
}

private struct LevelMeter: View {
    let level: Float
    let tint: Color

    private static let shape: [CGFloat] = {
        let count = 24
        return (0..<count).map { i in
            let x = Double(i) / Double(count - 1) * 2.0 - 1.0
            let base = 1.0 - x * x
            let jitter = sin(Double(i) * 2.7) * 0.15
            return CGFloat(max(0.15, base + jitter))
        }
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<Self.shape.count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(barFill(for: i))
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let maxH: CGFloat = 22
        let minH: CGFloat = 4
        let target = minH + Self.shape[index] * (maxH - minH)
        let active = minH + CGFloat(level) * (target - minH)
        return max(minH, active)
    }

    private func barFill(for index: Int) -> Color {
        Self.shape[index] * CGFloat(level) > 0.05 && CGFloat(level) > 0.02
            ? tint.opacity(Double(0.4 + CGFloat(level) * 0.6))
            : Color.white.opacity(0.10)
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.cardStroke, lineWidth: 1)
            )
    }
}


