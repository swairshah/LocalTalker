import Foundation

final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var sileroVADReady = false
    @Published var smartTurnReady = false
    @Published var sttModelReady = false
    @Published var ttsReady = false
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus: String = ""

    private init() {
        checkModels()
    }

    func checkModels() {
        sileroVADReady = FileManager.default.fileExists(atPath: Constants.sileroVADModelPath.path)
        smartTurnReady = FileManager.default.fileExists(atPath: Constants.smartTurnModelPath.path)
        sttModelReady = Transcriber.findModelPath() != nil
        ttsReady = checkTTSAvailable()
    }

    func downloadVADModels() async throws {
        let modelsDir = Constants.modelsDir

        if !sileroVADReady {
            downloadStatus = "Downloading Silero VAD…"
            let url = URL(string: "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx")!
            let dest = modelsDir.appendingPathComponent("silero_vad.onnx")
            try await downloadFile(from: url, to: dest)
            await MainActor.run { self.sileroVADReady = true }
        }

        if !smartTurnReady {
            downloadStatus = "Downloading Smart Turn…"
            let url = URL(string: "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/smart-turn-v3.2-cpu.onnx")!
            let dest = modelsDir.appendingPathComponent("smart-turn-v3.2-cpu.onnx")
            try await downloadFile(from: url, to: dest)
            await MainActor.run { self.smartTurnReady = true }
        }

        await MainActor.run {
            self.downloadStatus = "Ready"
            self.downloadProgress = 1
        }
    }

    private func checkTTSAvailable() -> Bool {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = resourcePath + "/pocket-tts-cli"
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return true
            }
        }

        let candidates = [
            "/opt/homebrew/bin/pocket-tts-cli",
            "/usr/local/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.cargo/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.local/bin/pocket-tts-cli",
            "/Applications/Loqui.app/Contents/Resources/pocket-tts-cli",
            NSHomeDirectory() + "/Applications/Loqui.app/Contents/Resources/pocket-tts-cli",
        ]

        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(
                domain: "LocalTalker.ModelManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))"]
            )
        }

        let dir = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
