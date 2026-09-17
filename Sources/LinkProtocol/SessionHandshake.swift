import Foundation

public final class ServerHandshake {
    private let key: Data
    private var transcript: Data?
    public private(set) var channel: SecureChannel?
    public init(key: Data) { self.key = key }

    public func receive(_ envelope: Envelope) throws -> Envelope {
        guard channel == nil else { throw RPCError("auth", "Handshake already complete") }
        if envelope.type == "hello", transcript == nil, let client = envelope.nonce {
            let server = try ChannelCrypto.random()
            let t = try ChannelCrypto.transcript(client: client, server: server)
            transcript = t
            return Envelope(type: "challenge", nonce: server,
                            proof: ChannelCrypto.proof(key: key, transcript: t, role: "server"))
        }
        guard envelope.type == "authenticate", let t = transcript, let proof = envelope.proof else {
            throw RPCError("auth", "Invalid handshake state")
        }
        try ChannelCrypto.verify(proof, key: key, transcript: t, role: "client")
        let session = try SecureChannel(key: key, transcript: t, server: true)
        channel = session
        return try session.seal(Data("ready".utf8))
    }
}

public final class ClientHandshake {
    private let key: Data
    private let client: Data
    public private(set) var channel: SecureChannel?
    public init(key: Data) throws { self.key = key; self.client = try ChannelCrypto.random() }
    public var hello: Envelope { Envelope(type: "hello", nonce: client) }

    public func authenticate(_ envelope: Envelope) throws -> Envelope {
        guard channel == nil, envelope.type == "challenge", let server = envelope.nonce,
              let proof = envelope.proof else { throw RPCError("auth", "Invalid server challenge") }
        let t = try ChannelCrypto.transcript(client: client, server: server)
        try ChannelCrypto.verify(proof, key: key, transcript: t, role: "server")
        channel = try SecureChannel(key: key, transcript: t, server: false)
        return Envelope(type: "authenticate", proof: ChannelCrypto.proof(key: key, transcript: t, role: "client"))
    }
}
