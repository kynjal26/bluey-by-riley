import Foundation
import CryptoKit

public struct PairingRecord: Codable, Equatable {
    public var version = 1
    public var service: String
    public var secret: String
    public init(service: String, secret: Data) { self.service = service; self.secret = secret.base64EncodedString() }
    public var key: Data? { Data(base64Encoded: secret).flatMap { $0.count == 32 ? $0 : nil } }
    /// Public fingerprint for discovery; the secret still authenticates the transport.
    public var identifier: String { key.map { SHA256.hash(data: $0).prefix(12).map { String(format: "%02x", $0) }.joined() } ?? "invalid" }
    public var qrText: String { "bluey-pair:" + ((try? JSONEncoder().encode(self)).map { $0.base64EncodedString() } ?? "") }
    public static func parse(_ text: String) -> PairingRecord? {
        guard text.hasPrefix("bluey-pair:"), text.count < 2048,
              let data = Data(base64Encoded: String(text.dropFirst(11))),
              let record = try? JSONDecoder().decode(Self.self, from: data), record.version == 1,
              record.key != nil, !record.service.isEmpty else { return nil }
        return record
    }
}

/// Challenge-derived direction keys and ordered AEAD records prevent eavesdropping,
/// tampering and replay. A QR secret is a pairing credential; never log or sync it.
public struct SecureChannel {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent = 0
    private var received = 0
    private struct Record: Codable { var sequence: Int; var packet: Packet }
    public init(secret: Data, challenge: Data, server: Bool) {
        func key(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: challenge,
                info: Data(("bluey-v1-" + direction).utf8), outputByteCount: 32)
        }
        sendKey = key(server ? "mac-to-phone" : "phone-to-mac")
        receiveKey = key(server ? "phone-to-mac" : "mac-to-phone")
    }
    public static func proof(secret: Data, challenge: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("bluey-pair-v1".utf8) + challenge, using: SymmetricKey(data: secret)))
    }
    public static func verifies(_ proof: Data, secret: Data, challenge: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("bluey-pair-v1".utf8) + challenge,
                                              using: SymmetricKey(data: secret))
    }
    public mutating func seal(_ packet: Packet) throws -> Data {
        let data = try JSONEncoder().encode(Record(sequence: sent, packet: packet))
        let encrypted = try AES.GCM.seal(data, using: sendKey).combined!
        sent += 1
        return Data(encrypted.base64EncodedString().utf8)
    }
    public mutating func open(_ line: Data) throws -> Packet {
        guard let encrypted = Data(base64Encoded: line) else { throw ChannelError.invalid }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: receiveKey)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.sequence == received else { throw ChannelError.invalid }
        received += 1
        return record.packet
    }
    private enum ChannelError: Error { case invalid }
}
