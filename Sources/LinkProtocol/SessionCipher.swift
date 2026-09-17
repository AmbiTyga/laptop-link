import Foundation
import CryptoKit
import Security

public struct Envelope: Codable, Sendable {
    public var type: String
    public var nonce: Data?
    public var proof: Data?
    public var sequence: UInt64?
    public var payload: Data?
    public init(type: String, nonce: Data? = nil, proof: Data? = nil,
                sequence: UInt64? = nil, payload: Data? = nil) {
        self.type = type; self.nonce = nonce; self.proof = proof
        self.sequence = sequence; self.payload = payload
    }
}

public enum ChannelCrypto {
    public static func random(_ count: Int = 32) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RPCError("crypto", "Random generator failed") }
        return data
    }

    public static func transcript(client: Data, server: Data) throws -> Data {
        guard client.count == 32, server.count == 32 else { throw RPCError("auth", "Invalid nonce") }
        return Data("ble-connection/v1/".utf8) + client + server
    }

    public static func proof(key: Data, transcript: Data, role: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript + Data(role.utf8), using: SymmetricKey(data: key)))
    }

    public static func verify(_ proof: Data, key: Data, transcript: Data, role: String) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript + Data(role.utf8),
                                                    using: SymmetricKey(data: key)) else {
            throw RPCError("auth", "Authentication failed")
        }
    }
}

/// Single-owner session. Distinct directional keys and monotonically increasing nonce counters.
public final class SecureChannel {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    public init(key: Data, transcript: Data, server: Bool) throws {
        guard key.count == 32 else { throw RPCError("auth", "Enrollment key must contain 32 random bytes") }
        func derive(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: transcript,
                                  info: Data(direction.utf8), outputByteCount: 32)
        }
        sendKey = derive(server ? "server-to-client" : "client-to-server")
        receiveKey = derive(server ? "client-to-server" : "server-to-client")
    }

    public func seal(_ data: Data) throws -> Envelope {
        guard sendSequence < UInt64.max else { throw RPCError("session_expired", "Reconnect required") }
        let number = sendSequence
        let sealed = try AES.GCM.seal(data, using: sendKey, nonce: nonce(number),
                                      authenticating: Data("ble-connection/v1/data".utf8))
        sendSequence += 1
        return Envelope(type: "data", sequence: number, payload: sealed.ciphertext + sealed.tag)
    }

    public func open(_ envelope: Envelope) throws -> Data {
        guard envelope.type == "data", envelope.sequence == receiveSequence,
              receiveSequence < UInt64.max, let payload = envelope.payload, payload.count >= 16 else {
            throw RPCError("auth", "Invalid or replayed encrypted message")
        }
        let box = try AES.GCM.SealedBox(nonce: nonce(receiveSequence),
                                       ciphertext: payload.dropLast(16), tag: payload.suffix(16))
        let plain = try AES.GCM.open(box, using: receiveKey, authenticating: Data("ble-connection/v1/data".utf8))
        receiveSequence += 1
        return plain
    }

    private func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
        var value = sequence.bigEndian
        let suffix = withUnsafeBytes(of: &value) { Data($0) }
        return try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + suffix)
    }
}
