import Foundation
import Network
import CryptoKit

/// Everything the Mac and the iPhone agree on: the Bonjour service name,
/// what a "face update" looks like, and how lines of JSON travel over TCP.
public enum GooglyService {
    public static let type = "_googly._tcp"
}

public enum Mood: String, Codable, CaseIterable, Sendable {
    case listening, resting, thinking, talking, pointing, happy, sleepy

    public var title: String { rawValue.capitalized }
}

/// What the phone should show right now.
public struct FaceState: Codable, Equatable, Sendable {
    /// Where the eyes look. x: -1 left … 1 right. y: -1 up … 1 down.
    public var gazeX: Double
    public var gazeY: Double
    public var mood: Mood
    /// Voice level, 0…1. Drives the talking bounce.
    public var talk: Double

    public init(gazeX: Double = 0, gazeY: Double = 0, mood: Mood = .listening, talk: Double = 0) {
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.mood = mood
        self.talk = talk
    }
}

public struct Packet: Codable, Sendable {
    public var face: FaceState?
    /// Sent once by each side after connecting, with a device name.
    public var hello: String?
    /// Voice volume 0…1. The Mac shares it, the phone sets it.
    public var volume: Double?
    /// A request or event: "testVoice" (phone→Mac), "playing"/"done" (phone→Mac), "stopSpeech" (Mac→phone).
    public var command: String?
    /// Speech audio (mp3, base64) for the phone to play.
    public var audio: String?
    /// Which speech an audio packet or a playing/done event belongs to.
    public var speech: Int?
    /// Pairs a request with its reply (tool calls, realtime tokens).
    public var callID: String?
    /// Tool name for a "tool" request.
    public var tool: String?
    /// Free text: tool arguments or output, a token, a caption.
    public var text: String?
    /// A JPEG (base64) that goes with a tool result.
    public var image: String?

    public init(face: FaceState? = nil, hello: String? = nil, volume: Double? = nil, command: String? = nil,
                audio: String? = nil, speech: Int? = nil, callID: String? = nil, tool: String? = nil,
                text: String? = nil, image: String? = nil) {
        self.face = face
        self.hello = hello
        self.volume = volume
        self.command = command
        self.audio = audio
        self.speech = speech
        self.callID = callID
        self.tool = tool
        self.text = text
        self.image = image
    }
}

public extension NWParameters {
    static var googly: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// Newline-delimited JSON over one NWConnection. All callbacks run on the main queue.
public final class LineConnection {
    public let connection: NWConnection
    public var onPacket: ((Packet) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?
    public var onAuthenticated: (() -> Void)?
    private var buffer = Data()
    private let secret: Data
    private let server: Bool
    private var challenge: Data?
    private var channel: SecureChannel?
    private var authenticated = false

    public init(_ connection: NWConnection, secret: Data, server: Bool) {
        self.connection = connection; self.secret = secret; self.server = server
    }
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, self.server {
                let challenge = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                self.challenge = challenge
                self.handshake(["challenge": challenge.base64EncodedString()])
            }
            self.onState?(state)
        }
        connection.start(queue: .main)
        receive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.authenticated == false { self?.cancel() }
        }
    }
    public func send(_ packet: Packet) {
        guard authenticated, var channel else { return }
        do {
            let data = try channel.seal(packet)
            self.channel = channel
            write(data)
        } catch { cancel() }
    }
    public func cancel() { connection.cancel() }
    private func write(_ data: Data) {
        var line = data; line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel() }
        })
    }
    private func handshake(_ fields: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: fields) { write(data) }
    }
    private func accept(_ line: Data) {
        if var channel {
            do {
                let packet = try channel.open(line)
                self.channel = channel
                if !authenticated {
                    guard !server, packet.command == "paired" else { cancel(); return }
                    authenticated = true
                    onAuthenticated?()
                } else { onPacket?(packet) }
            } catch { cancel() }
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: String] else { cancel(); return }
        if server {
            guard let challenge, let text = json["proof"], let proof = Data(base64Encoded: text),
                  SecureChannel.verifies(proof, secret: secret, challenge: challenge) else { cancel(); return }
            channel = SecureChannel(secret: secret, challenge: challenge, server: true)
            authenticated = true
            send(Packet(command: "paired"))
            onAuthenticated?()
        } else {
            guard let text = json["challenge"], let challenge = Data(base64Encoded: text), challenge.count == 32 else { cancel(); return }
            channel = SecureChannel(secret: secret, challenge: challenge, server: false)
            handshake(["proof": SecureChannel.proof(secret: secret, challenge: challenge).base64EncodedString()])
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                guard self.buffer.count <= 16 * 1024 * 1024 else { self.cancel(); return }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = Data(self.buffer[..<newline])
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    self.accept(line)
                }
            }
            if complete || error != nil { self.cancel() } else { self.receive() }
        }
    }
}
