import Foundation
@preconcurrency import CoreBluetooth
import LinkProtocol

/// Core Bluetooth delegates and all peer state are confined to queue.
public final class LinkPeripheralServer: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    public typealias Handler = @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void
    private let queue = DispatchQueue(label: "ble.peripheral")
    private let name: String, key: Data
    private let handler: Handler
    private let status: @Sendable (String) -> Void
    private var manager: CBPeripheralManager!
    private var requestCharacteristic: CBMutableCharacteristic!
    private var responseCharacteristic: CBMutableCharacteristic!
    private var peers: [UUID: PeripheralPeer] = [:]
    private var maintenance: DispatchSourceTimer?

    public init(name: String, key: Data, status: @escaping @Sendable (String) -> Void, handler: @escaping Handler) {
        self.name = name; self.key = key; self.status = status; self.handler = handler
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in self?.expirePeers() }
        maintenance = timer; timer.resume()
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        peers.removeAll()
        guard peripheral.state == .poweredOn else {
            status("Bluetooth unavailable: \(peripheral.state.rawValue) (2 unsupported, 3 denied, 4 off)")
            return
        }
        peripheral.removeAllServices()
        requestCharacteristic = CBMutableCharacteristic(type: LinkServiceIDs.request, properties: [.write],
                                                         value: nil, permissions: [.writeable])
        responseCharacteristic = CBMutableCharacteristic(type: LinkServiceIDs.response, properties: [.notify],
                                                          value: nil, permissions: [])
        let service = CBMutableService(type: LinkServiceIDs.service, primary: true)
        service.characteristics = [requestCharacteristic, responseCharacteristic]
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { status("Service registration failed: \(error!.localizedDescription)"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [LinkServiceIDs.service],
                                     CBAdvertisementDataLocalNameKey: String(name.prefix(20))])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        status(error.map { "Advertising failed: \($0.localizedDescription)" } ?? "Advertising as \(name)")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == LinkServiceIDs.response, peers.count < 4 else { return }
        peers[central.identifier] = PeripheralPeer(central: central, key: key)
        status("Client subscribed; awaiting authentication")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        peers.removeValue(forKey: central.identifier)
        status("Client disconnected; command jobs remain active")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == LinkServiceIDs.request && $0.offset == 0 &&
                                    $0.central.identifier == first.central.identifier && $0.value != nil }),
              let peer = peers[first.central.identifier] else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        do {
            var messages: [Data] = []
            for request in requests { messages += try peer.decoder.append(request.value!) }
            // One complete application message per ATT write batch; never accept an unbounded request queue.
            guard messages.count <= 1, !peer.busy, peer.outbound.isEmpty else {
                throw RPCError("busy", "Wait for the previous response")
            }
            if let message = messages.first { try receive(message, peer: peer) }
            peer.lastActivity = ProcessInfo.processInfo.systemUptime
            peripheral.respond(to: first, withResult: .success)
        } catch {
            peers.removeValue(forKey: first.central.identifier)
            peripheral.respond(to: first, withResult: .unlikelyError)
            status("Client session closed: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data, peer: PeripheralPeer) throws {
        let envelope = try WireJSON.decode(Envelope.self, from: data)
        guard let channel = peer.handshake.channel else {
            try enqueue(peer.handshake.receive(envelope), peer: peer)
            if peer.handshake.channel != nil { status("Client authenticated") }
            return
        }
        let plain = try channel.open(envelope)
        peer.busy = true
        let id = peer.central.identifier, token = peer.token
        handler(plain) { [weak self] response in
            guard let self else { return }
            self.queue.async {
                guard let current = self.peers[id], current.token == token, let channel = current.handshake.channel else { return }
                do {
                    current.busy = false
                    try self.enqueue(channel.seal(response), peer: current)
                } catch { self.peers.removeValue(forKey: id); self.status("Response failed: \(error.localizedDescription)") }
            }
        }
    }

    private func enqueue(_ envelope: Envelope, peer: PeripheralPeer) throws {
        guard peer.outbound.isEmpty else { throw RPCError("busy", "Transmit queue full") }
        peer.outbound = try FrameDecoder.encode(WireJSON.encode(envelope))
        flush(peer)
    }

    private func flush(_ peer: PeripheralPeer) {
        while !peer.outbound.isEmpty {
            let count = min(peer.outbound.count, peer.central.maximumUpdateValueLength)
            guard count > 0, manager.updateValue(Data(peer.outbound.prefix(count)), for: responseCharacteristic,
                                                 onSubscribedCentrals: [peer.central]) else { return }
            peer.outbound.removeFirst(count)
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for peer in peers.values { flush(peer) }
    }

    private func expirePeers() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, peer) in peers {
            let limit: Double = peer.handshake.channel == nil ? 15 : 300
            if !peer.busy, now - peer.lastActivity > limit { peers.removeValue(forKey: id) }
        }
    }
}
