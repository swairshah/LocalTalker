import Foundation

enum Constants {
    static let sampleRate: Double = 16_000
    static let ttsSampleRate: Double = 24_000
    static let audioChannels: Int = 1

    static let vadChunkSize: Int = 512
    static let vadSpeechThreshold: Float = 0.5
    static let vadSpeechMinChunks: Int = 4
    static let vadSilenceDurationMs: Int = 600
    static var vadSilenceChunks: Int {
        let chunkDurationMs = Double(vadChunkSize) / sampleRate * 1000
        return Int(Double(vadSilenceDurationMs) / chunkDurationMs)
    }

    static let smartTurnMaxSamples: Int = 128_000

    static let tempAudioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("localtalker-recording.wav")

    static let ttsHost = "127.0.0.1"
    static let ttsPort = 18080

    /// Primary data directory: ~/.LocalTalker
    static let appSupportDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".LocalTalker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let modelsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func bundledModelPath(_ name: String) -> URL {
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()

        if let resourcePath = Bundle.main.resourcePath {
            let path = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("models/\(name)")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        if let execDir {
            var dir = execDir
            for _ in 0..<5 {
                let candidate = dir.appendingPathComponent("Resources/models/\(name)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        return modelsDir.appendingPathComponent(name)
    }

    static var sileroVADModelPath: URL { bundledModelPath("silero_vad.onnx") }
    static var smartTurnModelPath: URL { bundledModelPath("smart-turn-v3.2-cpu.onnx") }

    static let bargeInThreshold: Float = 0.6
    static let bargeInMinChunks: Int = 6
}
