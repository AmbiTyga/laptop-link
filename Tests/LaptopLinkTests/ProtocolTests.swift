import XCTest
import Foundation
@testable import LinkProtocol

final class ProtocolTests: XCTestCase {
    func testFramesAcrossEverySplitAndMultipleMessages() throws {
        let message = Data("a message with 🛠 and binary framing".utf8)
        let frame = try FrameDecoder.encode(message)
        for split in 0...frame.count {
            var decoder = FrameDecoder()
            let a = try decoder.append(Data(frame.prefix(split)))
            let b = try decoder.append(Data(frame.dropFirst(split)))
            XCTAssertEqual(a + b, [message])
        }
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(frame + frame), [message, message])
        var invalid = FrameDecoder()
        XCTAssertThrowsError(try invalid.append(Data([255, 255, 255, 255])))
    }

    func testMutualAuthenticationAndReplayProtection() throws {
        let key = try ChannelCrypto.random()
        let client = try ClientHandshake(key: key), server = ServerHandshake(key: key)
        let challenge = try server.receive(client.hello)
        let auth = try client.authenticate(challenge)
        let ready = try server.receive(auth)
        let c = try XCTUnwrap(client.channel), s = try XCTUnwrap(server.channel)
        XCTAssertEqual(try c.open(ready), Data("ready".utf8))
        let request = try c.seal(Data("request".utf8))
        XCTAssertEqual(try s.open(request), Data("request".utf8))
        XCTAssertThrowsError(try s.open(request))
        XCTAssertEqual(try c.open(s.seal(Data("result".utf8))), Data("result".utf8))
        XCTAssertThrowsError(try server.receive(auth))
    }

    func testWrongKeyTamperingAndDirection() throws {
        let key = try ChannelCrypto.random()
        let wrong = try ClientHandshake(key: ChannelCrypto.random()), server = ServerHandshake(key: key)
        XCTAssertThrowsError(try wrong.authenticate(server.receive(wrong.hello)))
        let t = try ChannelCrypto.transcript(client: ChannelCrypto.random(), server: ChannelCrypto.random())
        let c = try SecureChannel(key: key, transcript: t, server: false)
        let s = try SecureChannel(key: key, transcript: t, server: true)
        var encrypted = try c.seal(Data("secret".utf8))
        XCTAssertThrowsError(try c.open(encrypted))
        let index = try XCTUnwrap(encrypted.payload?.startIndex)
        encrypted.payload![index] ^= 1
        XCTAssertThrowsError(try s.open(encrypted))
    }
}
