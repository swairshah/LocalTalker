import CryptoKit
import Foundation
import Network

// MARK: - WebSocket helpers (reused from PiTalk)

private enum WSHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func upgradeResponse(from raw: String) -> String? {
        let lines = raw.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let first = lines.first, first.lowercased().hasPrefix("get ") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = val
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              let key = headers["sec-websocket-key"], !key.isEmpty else { return nil }
        let accept = wsAccept(for: key)
        return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
    }

    private static func wsAccept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }
}

private enum WSCodec {
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(len) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    static func readFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        guard fin else { buffer.removeAll(); return nil }

        var offset = 2
        var payloadLen = Int(b1 & 0x7F)
        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLen = (Int(buffer[offset]) << 8) | Int(buffer[offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 { len = (len << 8) | UInt64(buffer[offset + i]) }
            guard len <= 2_000_000 else { buffer.removeAll(); return nil }
            payloadLen = Int(len)
            offset += 8
        }

        var maskKey: [UInt8] = [0,0,0,0]
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<(offset+4)])
            offset += 4
        }
        guard buffer.count >= offset + payloadLen else { return nil }
        var payload = Data(buffer[offset..<(offset + payloadLen)])
        if masked {
            payload.withUnsafeMutableBytes { raw in
                guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<payloadLen { bytes[i] ^= maskKey[i % 4] }
            }
        }
        buffer.removeSubrange(0..<(offset + payloadLen))
        return (opcode, payload)
    }
}

// MARK: - Peer

private final class Peer {
    let id = UUID()
    let connection: NWConnection
    var handshakeBuffer = Data()
    var frameBuffer = Data()
    var authenticated = false
    var isStreamingAudio = false

    init(connection: NWConnection) { self.connection = connection }
}

// MARK: - Server

final class CommanderRemoteServer {
    private let queue = DispatchQueue(label: "commander.remote")
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var eventSeq: Int64 = 0

    var snapshotProvider: (() -> CommanderSnapshot)?
    var onSendText: ((String) -> Void)?       // iOS sends text to Pi
    var onStopSpeech: (() -> Void)?
    var onNewSession: (() -> Void)?
    var onRemoteAudioStart: (() -> Void)?     // iOS started streaming mic audio
    var onRemoteAudioStop: (() -> Void)?      // iOS stopped streaming mic audio
    var onRemoteAudioFrame: (([Float]) -> Void)?  // iOS PCM audio (16kHz mono float32)

    let port: UInt16

    init(port: UInt16 = 18084) {
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to 0.0.0.0 so Tailscale / LAN clients can reach us
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: nwPort)
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { state in
            if case .ready = state {
                if let tsIP = TailscaleDetector.detectTailscaleIP() {
                    print("Commander Remote: listening on 0.0.0.0:\(self.port) (Tailscale: \(tsIP):\(self.port))")
                } else {
                    print("Commander Remote: listening on 0.0.0.0:\(self.port)")
                }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        queue.async { [self] in
            peers.values.forEach { $0.connection.cancel() }
            peers.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Publish events

    func publishSnapshot(_ snapshot: CommanderSnapshot) {
        guard let payload = CommanderJSONValue.fromEncodable(snapshot) else { return }
        queue.async { self.broadcast(name: "snapshot", payload: payload) }
    }

    func publishTranscriptDelta(message: CommanderMessage) {
        guard let payload = CommanderJSONValue.fromEncodable(message) else { return }
        queue.async { self.broadcast(name: "message", payload: payload) }
    }

    func publishStateChange(state: String, isMuted: Bool) {
        let payload: CommanderJSONValue = .object([
            "state": .string(state),
            "isMuted": .bool(isMuted),
        ])
        queue.async { self.broadcast(name: "state", payload: payload) }
    }

    // MARK: - Connection lifecycle

    private func accept(_ conn: NWConnection) {
        let peer = Peer(connection: conn)
        peers[peer.id] = peer
        conn.stateUpdateHandler = { [weak self, id = peer.id] state in
            if case .failed = state { self?.queue.async { self?.drop(id: id) } }
            if case .cancelled = state { self?.queue.async { self?.drop(id: id) } }
        }
        conn.start(queue: queue)
        receiveHandshake(peer)
    }

    private func drop(id: UUID) {
        peers[id]?.connection.cancel()
        peers.removeValue(forKey: id)
    }

    private func receiveHandshake(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, id = peer.id] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard let peer = self.peers[id] else { return }
                if error != nil || isComplete { self.drop(id: id); return }
                if let data { peer.handshakeBuffer.append(data) }
                guard peer.handshakeBuffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    self.receiveHandshake(peer); return
                }
                guard let raw = String(data: peer.handshakeBuffer, encoding: .utf8),
                      let response = WSHandshake.upgradeResponse(from: raw) else {
                    self.drop(id: id); return
                }
                peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    self?.queue.async {
                        peer.authenticated = true
                        // Send initial snapshot
                        if let snapshot = self?.snapshotProvider?(),
                           let payload = CommanderJSONValue.fromEncodable(snapshot) {
                            self?.sendEvent(name: "snapshot", payload: payload, to: peer)
                        }
                        self?.receiveFrames(peer)
                    }
                })
            }
        }
    }

    private func receiveFrames(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, id = peer.id] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard let peer = self.peers[id] else { return }
                if error != nil || isComplete { self.drop(id: id); return }
                if let data { peer.frameBuffer.append(data) }
                self.parseFrames(peer)
                self.receiveFrames(peer)
            }
        }
    }

    private func parseFrames(_ peer: Peer) {
        while let (opcode, payload) = WSCodec.readFrame(from: &peer.frameBuffer) {
            switch opcode {
            case 0x1: handleData(payload, from: peer)           // text frame (JSON commands)
            case 0x2: handleBinaryData(payload, from: peer)     // binary frame (audio)
            case 0x8: drop(id: peer.id)
            case 0x9: send(WSCodec.encode(opcode: 0xA, payload: payload), to: peer) // pong
            default: break
            }
        }
    }

    /// Handle binary WebSocket frames — these are PCM audio data from the iOS client.
    private func handleBinaryData(_ data: Data, from peer: Peer) {
        guard peer.isStreamingAudio, data.count >= 2 else { return }

        // Convert Int16 PCM → Float32 for the audio pipeline
        let sampleCount = data.count / 2
        var floats = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            guard let int16Ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                floats[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        Task { @MainActor [weak self] in
            self?.onRemoteAudioFrame?(floats)
        }
    }

    private func handleData(_ data: Data, from peer: Peer) {
        guard let frame = CommanderFrame.decodeData(data) else { return }
        switch frame.type {
        case .cmd: handleCommand(frame, from: peer)
        case .ping:
            let pong = CommanderFrame(type: .pong, name: "ping", requestId: frame.requestId,
                                      idempotencyKey: nil, seq: nil,
                                      ts: Int64(Date().timeIntervalSince1970 * 1000),
                                      payload: frame.payload ?? .object([:]))
            sendFrame(pong, to: peer)
        default: break
        }
    }

    private func handleCommand(_ frame: CommanderFrame, from peer: Peer) {
        let name = frame.name ?? ""
        let rid = frame.requestId ?? UUID().uuidString

        switch name {
        case "auth.hello":
            // Accept all — Commander is local / Tailscale only
            let ack = CommanderFrame.ack(name: name, requestId: rid, payload: .object([
                "serverVersion": .string("1.0"),
                "sessionId": .string(peer.id.uuidString),
            ]))
            sendFrame(ack, to: peer)
            // Send current snapshot
            if let snapshot = snapshotProvider?(),
               let payload = CommanderJSONValue.fromEncodable(snapshot) {
                sendEvent(name: "snapshot", payload: payload, to: peer)
            }

        case "snapshot.get":
            if let snapshot = snapshotProvider?(),
               let payload = CommanderJSONValue.fromEncodable(snapshot) {
                sendFrame(CommanderFrame.ack(name: name, requestId: rid, payload: payload), to: peer)
            }

        case "sendText":
            if let text = frame.payload?.objectValue?["text"]?.stringValue, !text.isEmpty {
                Task { @MainActor in self.onSendText?(text) }
                sendFrame(CommanderFrame.ack(name: name, requestId: rid, payload: .object(["ok": .bool(true)])), to: peer)
            } else {
                sendFrame(CommanderFrame.error(name: name, requestId: rid, code: "BAD_REQUEST", message: "text required"), to: peer)
            }

        case "stopSpeech":
            Task { @MainActor in self.onStopSpeech?() }
            sendFrame(CommanderFrame.ack(name: name, requestId: rid, payload: .object(["ok": .bool(true)])), to: peer)

        case "newSession":
            Task { @MainActor in self.onNewSession?() }
            sendFrame(CommanderFrame.ack(name: name, requestId: rid, payload: .object(["ok": .bool(true)])), to: peer)

        case "audio.start":
            peer.isStreamingAudio = true
            Task { @MainActor in self.onRemoteAudioStart?() }
            sendFrame(CommanderFrame.ack(name: name, requestId: rid, payload: .object(["ok": .bool(true)])), to: peer)
            print("Commander Remote: Audio streaming started from peer \(peer.id)")

        case "audio.stop":
            peer.isStreamingAudio = false
            Task { @MainActor in self.onRemoteAudioStop?() }
            sendFrame(CommanderFrame.ack(name: name, requestId: rid, payload: .object(["ok": .bool(true)])), to: peer)
            print("Commander Remote: Audio streaming stopped from peer \(peer.id)")

        default:
            sendFrame(CommanderFrame.error(name: name, requestId: rid, code: "UNKNOWN", message: "unknown command: \(name)"), to: peer)
        }
    }

    // MARK: - Sending

    private func broadcast(name: String, payload: CommanderJSONValue) {
        eventSeq += 1
        let frame = CommanderFrame.event(name: name, seq: eventSeq, payload: payload)
        for peer in peers.values where peer.authenticated {
            sendFrame(frame, to: peer)
        }
    }

    private func sendEvent(name: String, payload: CommanderJSONValue, to peer: Peer) {
        eventSeq += 1
        sendFrame(CommanderFrame.event(name: name, seq: eventSeq, payload: payload), to: peer)
    }

    private func sendFrame(_ frame: CommanderFrame, to peer: Peer) {
        guard let data = frame.encodeData() else { return }
        send(WSCodec.encode(opcode: 0x1, payload: data), to: peer)
    }

    private func send(_ data: Data, to peer: Peer) {
        peer.connection.send(content: data, completion: .contentProcessed { [weak self, id = peer.id] error in
            if error != nil { self?.queue.async { self?.drop(id: id) } }
        })
    }
}
