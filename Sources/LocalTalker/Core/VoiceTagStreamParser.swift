import Foundation

final class VoiceTagStreamParser {
    var onVoiceText: ((String) -> Void)?

    private var carry = ""
    private var currentVoiceBuffer = ""
    private var isInsideVoice = false

    /// True if at least one voice segment has been emitted since last reset.
    private(set) var hasEmitted = false

    func reset() {
        carry = ""
        currentVoiceBuffer = ""
        isInsideVoice = false
        hasEmitted = false
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        carry += delta
        process()
    }

    func flush() {
        // Only emit if we have an unclosed <voice> tag with actual content.
        if isInsideVoice && !currentVoiceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emit(currentVoiceBuffer)
        }
        // Clear buffers but preserve hasEmitted so callers can check it after flush.
        carry = ""
        currentVoiceBuffer = ""
        isInsideVoice = false
    }

    private func process() {
        while !carry.isEmpty {
            if isInsideVoice {
                if let closeRange = carry.range(of: "</voice>") {
                    currentVoiceBuffer += String(carry[..<closeRange.lowerBound])
                    emit(currentVoiceBuffer)
                    currentVoiceBuffer = ""
                    carry.removeSubrange(carry.startIndex..<closeRange.upperBound)
                    isInsideVoice = false
                } else {
                    currentVoiceBuffer += carry
                    carry = ""
                }
            } else {
                if let openRange = carry.range(of: "<voice>") {
                    carry.removeSubrange(carry.startIndex..<openRange.upperBound)
                    isInsideVoice = true
                } else {
                    // Keep only enough trailing characters to catch a split tag.
                    let maxCarry = 7
                    carry = String(carry.suffix(maxCarry))
                    return
                }
            }
        }
    }

    private func emit(_ raw: String) {
        let cleaned = raw
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        hasEmitted = true
        onVoiceText?(cleaned)
    }

    static func extractVoiceSegments(from text: String) -> [String] {
        let parser = VoiceTagStreamParser()
        var segments: [String] = []
        parser.onVoiceText = { segments.append($0) }
        parser.append(text)
        parser.flush()
        return segments
    }
}
