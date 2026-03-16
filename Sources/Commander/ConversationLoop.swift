import Foundation

@MainActor
final class ConversationLoop: ObservableObject {

    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case waiting
        case speaking
        case error(String)

        var displayName: String {
            switch self {
            case .idle: return "Ready"
            case .listening: return "Listening"
            case .transcribing: return "Transcribing"
            case .waiting: return "Thinking"
            case .speaking: return "Speaking"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isAgentRunning = false
    @Published private(set) var sessionID: String?
    @Published private(set) var turnCount = 0

    @Published private(set) var availableModels: [LlamaCPPClient.ModelOption] = []
    @Published var selectedModelPath: String = ""

    @Published var isMuted = true {
        didSet {
            guard oldValue != isMuted else { return }
            if isMuted { muteAudio() } else { unmuteAudio() }
        }
    }

    let transcript = TranscriptStore()
    let llmClient = LlamaCPPClient()

    private let audioCapture = AudioCaptureSession()
    private let audioBuffer = AudioBuffer()
    private let audioPlayer = AudioPlayer()
    private let ttsEngine = TTSEngine()
    private let voiceParser = VoiceTagStreamParser()
    private var sileroVAD: SileroVAD?
    private var transcriber: Transcriber?

    private var speechQueue: [String] = []
    private let speechQueueLock = NSLock()
    private var isSpeechLoopRunning = false
    private var speechGeneration = 0
    private var bargeInChunkCount = 0
    private var activeTranscriptionTask: Task<Void, Never>?

    private let selectedModelKey = "localtalker.llama.modelPath"

    init() {
        setupCallbacks()
    }

    var selectedModelName: String {
        availableModels.first(where: { $0.path == selectedModelPath })?.name ?? "Not selected"
    }

    func start() async {
        do {
            sileroVAD = try SileroVAD()

            if let modelPath = Transcriber.findModelPath() {
                transcriber = Transcriber(modelPath: modelPath)
            }

            if !(await ttsEngine.checkHealth()) {
                try await ttsEngine.startServer()
            } else {
                ttsEngine.isServerRunning = true
            }

            try await startConversationAgent()

            guard await AudioCaptureSession.checkPermission() else {
                state = .error("Microphone permission denied")
                return
            }

            state = .idle
            isMuted = false
            transcript.addLog("LocalTalker is ready")
        } catch {
            state = .error(error.localizedDescription)
            transcript.addLog("ERROR: \(error.localizedDescription)")
        }
    }

    func stop() {
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil

        audioPlayer.stop()
        audioPlayer.detach()
        audioCapture.stop()
        ttsEngine.stopServer()
        llmClient.stop()
        sileroVAD?.reset()
        audioBuffer.reset()
        voiceParser.reset()
        clearSpeechQueue()
        isAgentRunning = false
        state = .idle
    }

    func refreshModels() {
        availableModels = llmClient.listModels()

        if availableModels.isEmpty {
            selectedModelPath = ""
            return
        }

        let persisted = UserDefaults.standard.string(forKey: selectedModelKey)
        if let persisted, availableModels.contains(where: { $0.path == persisted }) {
            selectedModelPath = persisted
        } else if !availableModels.contains(where: { $0.path == selectedModelPath }) {
            selectedModelPath = availableModels[0].path
        }
    }

    func switchModel(to path: String) {
        guard !path.isEmpty, path != selectedModelPath else { return }

        Task {
            stopSpeech()
            state = .waiting

            do {
                try await llmClient.switchModel(path: path)
                selectedModelPath = path
                UserDefaults.standard.set(path, forKey: selectedModelKey)
                sessionID = llmClient.sessionId
                transcript.addSystemMessage("Switched model to \(URL(fileURLWithPath: path).lastPathComponent)")
                transcript.addLog("🧠 Model switched")
                state = isMuted ? .idle : .listening
            } catch {
                transcript.addLog("ERROR: Failed to switch model: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
            }
        }
    }

    func startNewSession() {
        transcript.clearMessages()
        transcript.addSystemMessage("Started a new session")
        transcript.addLog("🔄 New session")
        clearSpeechQueue()
        audioPlayer.stop()
        voiceParser.reset()
        llmClient.newSession()
        sessionID = llmClient.sessionId
        state = isMuted ? .idle : .listening
    }

    func stopSpeech() {
        let hadActiveOutput = state == .speaking || state == .waiting || hasSpeechQueuedOrActive || llmClient.isStreaming

        audioPlayer.stop()
        clearSpeechQueue()
        if llmClient.isStreaming {
            llmClient.abort()
        }
        if hadActiveOutput {
            llmClient.cleanupAfterInterrupt()
        }

        if state == .speaking || state == .waiting {
            state = isMuted ? .idle : .listening
        }
        transcript.addLog("⏹ Stopped speech")
    }

    func sendTypedText(_ text: String) {
        sendText(text, sourceRole: "USER (typed)")
    }


    private func sendText(_ text: String, sourceRole: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        interruptOutputForUserTurn()

        transcript.addUserMessage(trimmed)
        transcript.logTurn(role: sourceRole, text: trimmed)

        if llmClient.isRunning {
            if llmClient.isStreaming {
                llmClient.steer(trimmed)
            } else {
                llmClient.sendPrompt(trimmed)
            }
            llmClient.getState()
        } else {
            Task {
                do {
                    try await startConversationAgent()
                    llmClient.sendPrompt(trimmed)
                    llmClient.getState()
                } catch {
                    transcript.addLog("ERROR: LLM start failed: \(error.localizedDescription)")
                    state = .error(error.localizedDescription)
                }
            }
        }

        state = .waiting
    }

    private func interruptOutputForUserTurn() {
        let hadActiveOutput = state == .speaking || state == .waiting || hasSpeechQueuedOrActive || llmClient.isStreaming

        print("⚡ [INTERRUPT] state=\(state) streaming=\(llmClient.isStreaming) speechQueued=\(hasSpeechQueuedOrActive) hadActive=\(hadActiveOutput)")

        audioPlayer.stop()
        clearSpeechQueue()
        if llmClient.isStreaming {
            print("⚡ [INTERRUPT] Aborting in-flight LLM generation")
            llmClient.abort()
        }
        if hadActiveOutput {
            llmClient.cleanupAfterInterrupt()
        }
        voiceParser.reset()
    }

    private func startConversationAgent() async throws {
        let systemPrompt = """
        You are LocalTalker, a voice-first local assistant running through llama.cpp.
        The user is speaking with you in real time, so default to short, clear, conversational responses.
        Put every spoken sentence inside <voice> tags.
        Never use any XML/HTML/SSML tags other than <voice>.
        Keep replies concise and practical.
        """

        refreshModels()
        guard !availableModels.isEmpty else {
            throw LlamaCPPClient.ClientError.noModelsFound
        }

        if selectedModelPath.isEmpty || !availableModels.contains(where: { $0.path == selectedModelPath }) {
            selectedModelPath = availableModels[0].path
        }

        try await llmClient.start(systemPrompt: systemPrompt, preferredModelPath: selectedModelPath)

        if let current = llmClient.currentModel {
            selectedModelPath = current.path
            UserDefaults.standard.set(current.path, forKey: selectedModelKey)
        }

        sessionID = llmClient.sessionId
        isAgentRunning = true
    }

    private func setupCallbacks() {
        audioCapture.onAudioFrame = { [weak self] samples in
            Task { @MainActor [weak self] in
                self?.processAudioFrame(samples)
            }
        }

        audioCapture.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }

        // IMPORTANT: synchronous dispatch — no Task wrapping.
        // Both LlamaCPPClient and ConversationLoop are @MainActor,
        // so events are already on MainActor. Wrapping in Task { @MainActor }
        // created unstructured tasks that could reorder events across turns.
        llmClient.onEvent = { [weak self] event in
            self?.handleLLMEvent(event)
        }
    }



    private var turnCounter = 0

    private func handleLLMEvent(_ event: LlamaCPPClient.Event) {
        switch event {
        case .agentStart:
            turnCounter += 1
            voiceParser.reset()
            transcript.beginAssistantMessage()
            transcript.addLog("⚡ Model processing (turn \(turnCounter))")
            print("🟢 [TURN \(turnCounter)] agentStart — state=\(state)")

        case .agentEnd:
            let currentTurn = turnCounter
            transcript.endAssistantMessage()

            if let last = transcript.messages.last,
               last.role == .assistant {
                let raw = last.text
                let speakText = speechTextForAssistantMessage(raw)
                print("🔴 [TURN \(currentTurn)] agentEnd — raw=\(raw.prefix(200))")
                print("🔴 [TURN \(currentTurn)] speakText=\(speakText.prefix(200))")
                if !speakText.isEmpty {
                    enqueueSpeech(speakText)
                }
            } else {
                print("🔴 [TURN \(currentTurn)] agentEnd — no assistant message found")
            }

            if state == .waiting {
                if !hasSpeechQueuedOrActive {
                    state = isMuted ? .idle : .listening
                }
            }

        case .textDelta(let text):
            transcript.appendAssistantDelta(text)

        case .textEnd:
            break

        case .stateResponse(let streaming, let sessionId):
            sessionID = sessionId
            if !streaming && state == .waiting && !hasSpeechQueuedOrActive {
                state = isMuted ? .idle : .listening
            }

        case .response(let command, let success, let error):
            if !success {
                transcript.addLog("ERROR: \(command) failed: \(error ?? "unknown")")
            }
            if command == "new_session" {
                sessionID = llmClient.sessionId
            }

        case .error(let message):
            transcript.addLog("ERROR: \(message)")
            state = .error(message)

        case .processExited(let code):
            isAgentRunning = false
            transcript.addLog("llama.cpp exited (\(code))")

            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    try await startConversationAgent()
                    transcript.addLog("llama.cpp restarted")
                } catch {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    private func muteAudio() {
        audioPlayer.stop()
        clearSpeechQueue()
        audioCapture.stop()
        sileroVAD?.reset()
        audioBuffer.reset()
        bargeInChunkCount = 0
        audioLevel = 0
        state = .idle
        transcript.addLog("🔇 Mic muted")
    }

    private func unmuteAudio() {
        do {
            try audioCapture.start()
            if let engine = audioCapture.engine {
                audioPlayer.attach(to: engine)
            }
            sileroVAD?.reset()
            audioBuffer.reset()
            bargeInChunkCount = 0
            if state != .speaking && state != .waiting {
                state = .listening
            }
            transcript.addLog("🎙️ Mic live")
        } catch {
            transcript.addLog("ERROR: Failed to enable mic: \(error.localizedDescription)")
            isMuted = true
        }
    }

    private func processAudioFrame(_ samples: [Float]) {
        guard !isMuted, let vad = sileroVAD else { return }

        if state == .listening {
            audioBuffer.append(samples)
        }

        let probability: Float
        do {
            probability = try vad.processBuffer(samples)
        } catch {
            transcript.addLog("ERROR: VAD failed: \(error.localizedDescription)")
            return
        }

        let event = vad.currentEvent

        switch state {
        case .idle:
            if event == .speechContinue {
                audioBuffer.reset()
                audioBuffer.append(samples)
                state = .listening
            }

        case .listening:
            if event == .turnSilence,
               audioBuffer.duration > 0.25,
               activeTranscriptionTask == nil {
                let capturedSamples = audioBuffer.getAll()
                audioBuffer.reset()
                sileroVAD?.reset()

                guard !capturedSamples.isEmpty else {
                    state = isMuted ? .idle : .listening
                    return
                }

                state = .transcribing
                activeTranscriptionTask = Task { [weak self] in
                    await self?.transcribe(capturedSamples: capturedSamples)
                }
            }

        case .speaking, .waiting:
            if probability >= Constants.bargeInThreshold {
                bargeInChunkCount += 1
                if bargeInChunkCount >= Constants.bargeInMinChunks {
                    audioPlayer.stop()
                    clearSpeechQueue()
                    if llmClient.isStreaming { llmClient.abort() }
                    llmClient.cleanupAfterInterrupt()
                    sileroVAD?.resetIterator()
                    audioBuffer.reset()
                    audioBuffer.append(samples)
                    state = .listening
                    transcript.addLog("🗣️ Barge-in")
                    bargeInChunkCount = 0
                }
            } else {
                bargeInChunkCount = 0
            }

        default:
            break
        }
    }

    private func transcribe(capturedSamples: [Float]) async {
        defer { activeTranscriptionTask = nil }

        guard let transcriber else {
            state = .error("No STT model available")
            return
        }

        guard !capturedSamples.isEmpty else {
            state = isMuted ? .idle : .listening
            return
        }

        let audioURL = Constants.tempAudioURL
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            try saveSamplesToWAV(capturedSamples, url: audioURL)
            let text = try await transcriber.transcribe(audioURL: audioURL)
            guard !Task.isCancelled else { return }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = isMuted ? .idle : .listening
                return
            }

            turnCount += 1
            sendText(trimmed, sourceRole: "USER")
        } catch {
            transcript.addLog("ERROR: Transcription failed: \(error.localizedDescription)")
            state = isMuted ? .idle : .listening
        }
    }

    private func saveSamplesToWAV(_ samples: [Float], url: URL) throws {
        let tmp = AudioBuffer()
        tmp.append(samples)
        try tmp.saveToWAV(url: url)
    }

    private func enqueueSpeech(_ text: String) {
        speechQueueLock.lock()
        if speechQueue.last == text {
            print("⚠️ [SPEECH] Dedup — identical text already last in queue")
            speechQueueLock.unlock()
            return
        }
        speechQueue.append(text)
        let queueSize = speechQueue.count
        speechQueueLock.unlock()

        print("🎵 [SPEECH] Enqueued (queueSize=\(queueSize), gen=\(speechGeneration), loopRunning=\(isSpeechLoopRunning)): \(text.prefix(120))")

        if !isSpeechLoopRunning {
            isSpeechLoopRunning = true
            Task { await speechLoop() }
        }
    }

    private func speechLoop() async {
        let gen = speechGeneration
        print("🎵 [SPEECH LOOP] Started gen=\(gen)")

        while gen == speechGeneration {
            let next: String? = {
                speechQueueLock.lock()
                defer { speechQueueLock.unlock() }
                guard !speechQueue.isEmpty else { return nil }
                return speechQueue.removeFirst()
            }()

            guard let next else {
                if gen == speechGeneration {
                    isSpeechLoopRunning = false
                    if state == .speaking {
                        state = llmClient.isStreaming ? .waiting : (isMuted ? .idle : .listening)
                    }
                }
                print("🎵 [SPEECH LOOP] Finished gen=\(gen) (queue empty)")
                return
            }

            guard gen == speechGeneration else {
                print("🎵 [SPEECH LOOP] Bailing — gen \(gen) != current \(speechGeneration)")
                return
            }

            state = .speaking
            print("🎵 [SPEECH LOOP] Playing gen=\(gen): \(next.prefix(120))")
            transcript.addLog("🔊 \(next)")

            do {
                let audioData = try await ttsEngine.synthesize(text: next)
                guard gen == speechGeneration, state == .speaking else {
                    print("🎵 [SPEECH LOOP] Stale after TTS — gen \(gen) vs \(speechGeneration), state=\(state)")
                    return
                }
                try await audioPlayer.play(audioData: audioData)
            } catch {
                transcript.addLog("ERROR: TTS failed: \(error.localizedDescription)")
            }

            guard gen == speechGeneration else { return }
        }
    }

    private func clearSpeechQueue() {
        speechQueueLock.lock()
        speechQueue.removeAll()
        speechQueueLock.unlock()
        speechGeneration += 1
        isSpeechLoopRunning = false
    }

    private var hasSpeechQueuedOrActive: Bool {
        speechQueueLock.lock()
        defer { speechQueueLock.unlock() }
        return !speechQueue.isEmpty || audioPlayer.isPlaying
    }

    private func speechTextForAssistantMessage(_ raw: String) -> String {
        let voiceOnly = extractVoiceTagText(raw)
        let outsideVoice = extractOutsideVoiceText(raw)

        if !voiceOnly.isEmpty {
            // If model mixed tagged + untagged text, preserve both in-order-ish
            // by speaking tags first, then anything outside tags.
            return normalizeSpeechText([voiceOnly, outsideVoice]
                .filter { !$0.isEmpty }
                .joined(separator: " "))
        }

        let cleaned = cleanAssistantText(raw)
        return normalizeSpeechText(cleaned)
    }

    private func extractVoiceTagText(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<voice>([\s\S]*?)</voice>"#, options: []) else {
            return ""
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return "" }

        var parts: [String] = []
        for match in matches where match.numberOfRanges > 1 {
            let part = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
        }

        return parts.joined(separator: " ")
    }

    private func extractOutsideVoiceText(_ text: String) -> String {
        let outside = text
            .replacingOccurrences(of: #"<voice>[\s\S]*?</voice>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .replacingOccurrences(of: #"<status>[^<]*</status>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizeSpeechText(outside)
    }

    private func cleanAssistantText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .replacingOccurrences(of: #"<status>[^<]*</status>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSpeechText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
