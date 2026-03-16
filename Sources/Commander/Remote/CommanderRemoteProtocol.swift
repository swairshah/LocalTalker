import Foundation

// MARK: - Wire Protocol (simplified from PiTalk)

/// A single Commander session snapshot sent to iOS clients.
struct CommanderSnapshot: Codable, Equatable {
    let generatedAtMs: Int64
    let state: String          // idle, listening, transcribing, waiting, speaking, error
    let isMuted: Bool
    let sessionId: String?
    let messages: [CommanderMessage]
}

struct CommanderMessage: Codable, Equatable, Identifiable {
    let id: String
    let role: String           // user, assistant, system
    let text: String
    let timestampMs: Int64
}

// MARK: - Frame envelope (same shape as PiTalk for compatibility)

enum CommanderFrameType: String, Codable {
    case cmd, ack, event, error, ping, pong
}

struct CommanderFrame: Codable {
    let type: CommanderFrameType
    let name: String?
    let requestId: String?
    let idempotencyKey: String?
    let seq: Int64?
    let ts: Int64?
    let payload: CommanderJSONValue?

    static func event(name: String, seq: Int64?, payload: CommanderJSONValue?) -> CommanderFrame {
        CommanderFrame(type: .event, name: name, requestId: nil, idempotencyKey: nil,
                       seq: seq, ts: currentMs(), payload: payload)
    }

    static func ack(name: String, requestId: String, payload: CommanderJSONValue?) -> CommanderFrame {
        CommanderFrame(type: .ack, name: name, requestId: requestId, idempotencyKey: nil,
                       seq: nil, ts: currentMs(), payload: payload)
    }

    static func error(name: String, requestId: String, code: String, message: String) -> CommanderFrame {
        CommanderFrame(type: .error, name: name, requestId: requestId, idempotencyKey: nil,
                       seq: nil, ts: currentMs(),
                       payload: .object(["code": .string(code), "message": .string(message)]))
    }

    func encodeData() -> Data? { try? JSONEncoder().encode(self) }
    static func decodeData(_ data: Data) -> CommanderFrame? { try? JSONDecoder().decode(CommanderFrame.self, from: data) }
    private static func currentMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Minimal JSON value (same as PiTalk)

enum CommanderJSONValue: Codable, Equatable {
    case object([String: CommanderJSONValue])
    case array([CommanderJSONValue])
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode([String: CommanderJSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([CommanderJSONValue].self) { self = .array(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .integer(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var objectValue: [String: CommanderJSONValue]? { if case .object(let v) = self { return v }; return nil }

    static func fromEncodable<T: Encodable>(_ value: T) -> CommanderJSONValue? {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(CommanderJSONValue.self, from: data) else { return nil }
        return decoded
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
