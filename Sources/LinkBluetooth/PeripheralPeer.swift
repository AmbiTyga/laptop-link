import Foundation
import CoreBluetooth
import LinkProtocol

/// All access is on the peripheral delegate queue.
final class PeripheralPeer {
    let central: CBCentral
    let token = UUID()
    var handshake: ServerHandshake?
    var format: WireFormat?
    var decoder = FrameDecoder()
    var outbound = Data()
    var lastActivity = ProcessInfo.processInfo.systemUptime
    var busy = false
    init(central: CBCentral) { self.central = central }
}
