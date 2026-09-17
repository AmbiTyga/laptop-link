import Foundation
@preconcurrency import CoreBluetooth
import LinkProtocol

/// A single authenticated RPC exchange, preceded by server.info if bootID is absent.
/// Delegate state is confined to queue. Failures are never automatically retried.
public final class LinkCentralClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ble.central")
    private let handshake: ClientHandshake
    private let format: WireFormat
    private let name: String?
    private var request: RPCRequest
    private let completion: @Sendable (Result<RPCResponse, Error>) -> Void
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?, tx: CBCharacteristic?
    private var decoder = FrameDecoder()
    private var outgoing = Data()
    private var writing = false, done = false
    private var stage = "challenge"
    private var infoID: String?

    public init(key: Data, name: String?, request: RPCRequest, timeout: Int, format: WireFormat = .protobuf,
                completion: @escaping @Sendable (Result<RPCResponse, Error>) -> Void) throws {
        self.format = format; handshake = try ClientHandshake(key: key, format: format); self.name = name; self.request = request; self.completion = completion
        let readers: Set<String> = ["server.info", "fs.list", "fs.stat", "fs.read", "fs.search", "fs.hash",
                                    "exec.poll", "exec.list", "upload.status"]
        guard request.bootID != nil || readers.contains(request.method) else {
            throw RPCError("boot_id_required", "Fetch server.info and save its bootID in mutation request JSON before submitting; retain the same UUID and bootID for retries")
        }
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in
            self?.finish(.failure(RPCError("connection_timeout", "BLE exchange timed out; a submitted mutation may have executed. Reuse its UUID and bootID to query/retry.")))
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
                finish(.failure(RPCError("bluetooth", "Bluetooth unavailable: \(central.state.rawValue)")))
            }
            return
        }
        central.scanForPeripherals(withServices: [LinkServiceIDs.service])
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard name == nil || advertised == name else { return }
        self.peripheral = peripheral; peripheral.delegate = self
        central.stopScan(); central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([LinkServiceIDs.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(.failure(error ?? RPCError("connection", "Connection failed")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finish(.failure(error ?? RPCError("disconnected", "Connection lost; submitted mutation outcome may be unknown")))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == LinkServiceIDs.service }) else {
            finish(.failure(RPCError("protocol", "Missing service"))); return
        }
        peripheral.discoverCharacteristics([LinkServiceIDs.request, LinkServiceIDs.response], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { finish(.failure(error)); return }
        tx = service.characteristics?.first { $0.uuid == LinkServiceIDs.request }
        rx = service.characteristics?.first { $0.uuid == LinkServiceIDs.response }
        guard tx != nil, let rx else { finish(.failure(RPCError("protocol", "Missing characteristics"))); return }
        peripheral.setNotifyValue(true, for: rx)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(error)); return }
        guard characteristic.isNotifying else { finish(.failure(RPCError("protocol", "Notifications not enabled"))); return }
        do { try send(handshake.hello) } catch { finish(.failure(error)) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(error)); return }
        guard characteristic.uuid == LinkServiceIDs.response, let value = characteristic.value else { return }
        do {
            for data in try decoder.append(value) { try receive(format.decodeEnvelope(data)) }
        } catch { finish(.failure(error)) }
    }

    private func receive(_ envelope: Envelope) throws {
        if stage == "challenge" {
            let auth = try handshake.authenticate(envelope)
            stage = "ready"; try send(auth); return
        }
        guard let channel = handshake.channel else { throw RPCError("auth", "No authenticated session") }
        let data = try channel.open(envelope)
        if stage == "ready" {
            guard data == Data("ready".utf8) else { throw RPCError("auth", "Invalid authentication acknowledgement") }
            if request.method != "server.info", request.bootID == nil {
                let info = RPCRequest(method: "server.info")
                infoID = info.id; stage = "info"
                try send(channel.seal(format.encodeRequest(info)))
            } else { stage = "result"; try send(channel.seal(format.encodeRequest(request))) }
            return
        }
        let response = try format.decodeResponse(data)
        if stage == "info" {
            guard response.id == infoID, response.error == nil else { throw response.error ?? RPCError("protocol", "Wrong response ID") }
            request.bootID = response.bootID; stage = "result"
            // Print the exact retry identity before submitting any operation.
            let retry = "Request \(request.id), bootID \(response.bootID)\n"
            FileHandle.standardError.write(Data(retry.utf8))
            try send(channel.seal(format.encodeRequest(request))); return
        }
        guard response.id == request.id else { throw RPCError("protocol", "Wrong response ID") }
        finish(.success(response))
    }

    private func send(_ envelope: Envelope) throws {
        guard outgoing.isEmpty else { throw RPCError("protocol", "Previous write is unfinished") }
        outgoing = try FrameDecoder.encode(format.encodeEnvelope(envelope)); pump()
    }

    private func pump() {
        guard !done, !writing, !outgoing.isEmpty, let peripheral, let tx else { return }
        let count = min(outgoing.count, peripheral.maximumWriteValueLength(for: .withResponse))
        guard count > 0 else { finish(.failure(RPCError("protocol", "Invalid write size"))); return }
        let chunk = Data(outgoing.prefix(count)); outgoing.removeFirst(count); writing = true
        peripheral.writeValue(chunk, for: tx, type: .withResponse)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(error)); return }
        writing = false; pump()
    }

    private func finish(_ result: Result<RPCResponse, Error>) {
        guard !done else { return }; done = true
        manager.stopScan()
        if let peripheral { manager.cancelPeripheralConnection(peripheral) }
        completion(result)
    }
}
