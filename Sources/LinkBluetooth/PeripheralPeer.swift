import Foundation
import CoreBluetooth
import LinkProtocol

/// All access is on the peripheral delegate queue.
final class PeripheralPeer {
    let central: CBCentral
    let token = UUID()
    let handshake: ServerHandshake
    var decoder = FrameDecoder()
    var outbound = Data()
    var lastActivity = ProcessInfo.processInfo.systemUptime
    var busy = false
    init(central: CBCentral, key: Data) {
        self.central = central; handshake = ServerHandshake(key: key)
    }
}
