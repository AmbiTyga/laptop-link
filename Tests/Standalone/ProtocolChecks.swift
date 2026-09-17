import Foundation
import LinkProtocol

enum ProtocolChecks {
    static func frames() throws {
        let plain = Data("Unicode 🛠 framing".utf8), frame = try FrameDecoder.encode(plain)
        for split in 0...frame.count {
            var decoder = FrameDecoder()
            let first = try decoder.append(Data(frame.prefix(split)))
            let last = try decoder.append(Data(frame.dropFirst(split)))
            try require(first + last == [plain], "Fragment reconstruction failed at \(split)")
        }
        var decoder = FrameDecoder()
        try require(try decoder.append(frame + frame) == [plain, plain], "Coalesced frames were lost")
        try rejects { var d = FrameDecoder(); _ = try d.append(Data([255, 255, 255, 255])) }
    }

    static func authentication() throws {
        let key = try ChannelCrypto.random(), server = ServerHandshake(key: key)
        let client = try ClientHandshake(key: key)
        let ready = try server.receive(client.authenticate(server.receive(client.hello)))
        guard let c = client.channel, let s = server.channel else { throw CheckFailure("Handshake failed") }
        try require(try c.open(ready) == Data("ready".utf8), "Missing authenticated ready")
        let sent = try c.seal(Data("request".utf8))
        try require(try s.open(sent) == Data("request".utf8), "Request decryption failed")
        try rejects { _ = try s.open(sent) }
        try require(try c.open(s.seal(Data("response".utf8))) == Data("response".utf8), "Response decryption failed")
        var tampered = try c.seal(Data("secret".utf8))
        guard let index = tampered.payload?.startIndex else { throw CheckFailure("No ciphertext") }
        tampered.payload![index] ^= 1
        try rejects { _ = try s.open(tampered) }
        let wrong = try ClientHandshake(key: ChannelCrypto.random()), second = ServerHandshake(key: key)
        try rejects { _ = try wrong.authenticate(second.receive(wrong.hello)) }
    }
}
