import Foundation
import LinkProtocol

/// BLE and stdio enter here. Work is serialized independently of the Bluetooth delegate queue.
public final class RequestRouter: @unchecked Sendable {
    public let bootID = UUID().uuidString
    private let queue = DispatchQueue(label: "ble.requests")
    private let configuration: ServerConfiguration
    private let files: FileOperations
    private let commands: CommandOperations
    private let uploads: UploadOperations
    private let terminals: TerminalOperations
    private let lockHandle: FileHandle
    private var mutations: [String: (String, RPCResponse)] = [:]
    private let readers: Set<String> = ["server.info", "fs.list", "fs.stat", "fs.read", "fs.search", "fs.hash",
                                        "exec.poll", "exec.list", "upload.status", "terminal.read", "terminal.list"]

    public init(configuration: ServerConfiguration, terminalOpened: @escaping @Sendable (TerminalSession) -> Void = { _ in }) throws {
        self.configuration = configuration
        let paths = try PathPolicy(root: configuration.root)
        files = FileOperations(paths: paths)
        terminals = TerminalOperations(configuration: configuration, paths: paths, opened: terminalOpened)
        let state = URL(fileURLWithPath: configuration.stateDirectory)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(state.appendingPathComponent("server.lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw RPCError("io", "Cannot open server lock") }
        lockHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RPCError("already_running", "A server is already using this state directory") }
        let run = state.appendingPathComponent(bootID)
        commands = try CommandOperations(configuration: configuration, paths: paths, directory: run.appendingPathComponent("jobs"))
        uploads = try UploadOperations(files: files, directory: run.appendingPathComponent("uploads"),
                                       maximum: configuration.maximumUploadBytes)
    }

    public func handle(_ request: RPCRequest) -> RPCResponse { queue.sync { execute(request) } }

    public func handle(_ data: Data, format: WireFormat = .json, completion: @escaping @Sendable (Data) -> Void) {
        queue.async {
            let response: RPCResponse
            do { response = self.execute(try format.decodeRequest(data)) }
            catch { response = RPCResponse(id: "", bootID: self.bootID, error: RPCError("invalid_request", "Malformed RPC message")) }
            do { completion(try format.encodeResponse(response)) }
            catch {
                let fallback = RPCResponse(id: response.id, bootID: self.bootID,
                                           error: RPCError("response_too_large", "Reduce the result limit"))
                if let encoded = try? format.encodeResponse(fallback) { completion(encoded) }
            }
        }
    }

    private func execute(_ request: RPCRequest) -> RPCResponse {
        let mutating = !readers.contains(request.method)
        var fingerprint: String?
        do {
            guard request.version == 1, UUID(uuidString: request.id) != nil else {
                throw RPCError("invalid_request", "version must be 1 and id must be a UUID")
            }
            guard request.method == "server.info" || request.bootID == bootID else {
                throw RPCError("server_changed", "Fetch server.info; never automatically retry an old mutation after a server restart")
            }
            if mutating {
                let digest = sha256(try WireJSON.encode(request))
                if let (previous, response) = mutations[request.id] {
                    guard previous == digest else { throw RPCError("id_conflict", "Request UUID was used for different parameters") }
                    return response
                }
                guard mutations.count < 8192 else { throw RPCError("limit", "Mutation ledger is full; restart the server after finishing jobs/uploads") }
                fingerprint = digest
            }
            let result = try route(request)
            guard try WireJSON.encode(result).count <= 131_072 else {
                throw RPCError("response_too_large", "Reduce the result limit; response exceeds 128 KiB")
            }
            let response = RPCResponse(id: request.id, bootID: bootID, result: result)
            if let fingerprint { mutations[request.id] = (fingerprint, response) }
            return response
        } catch {
            let failure = (error as? RPCError) ?? RPCError("io", error.localizedDescription)
            let response = RPCResponse(id: request.id, bootID: bootID, error: failure)
            if let fingerprint { mutations[request.id] = (fingerprint, response) }
            return response
        }
    }

    private func route(_ r: RPCRequest) throws -> JSONValue {
        if r.method == "server.info" {
            return .object([
                "name": .string(configuration.name), "boot_id": .string(bootID),
                "root": .string(files.paths.root.path), "protocol_version": .int(1),
                "wire_formats": .array([.string("protobuf"), .string("json")]),
                "commands_enabled": .bool(configuration.allowCommands),
                "max_chunk_bytes": .int(65_536), "max_timeout_seconds": .int(Int64(configuration.maximumTimeoutSeconds)),
                "methods": .array(Self.methods.map(JSONValue.string))
            ])
        }
        if r.method.hasPrefix("fs.") { return try files.handle(r.method, r.params) }
        if r.method.hasPrefix("terminal.") { return try terminals.handle(r.method, r.params) }
        if r.method.hasPrefix("exec.") { return try commands.handle(r.method, r.params) }
        if r.method.hasPrefix("upload.") { return try uploads.handle(r.method, r.params) }
        throw RPCError("unknown_method", r.method)
    }

    public func openLocalTerminal(completion: @escaping @Sendable (Result<TerminalSession, Error>) -> Void) {
        queue.async { completion(Result { try self.terminals.open([:], local: true) }) }
    }

    public func shutdown() { queue.sync { commands.shutdown(); terminals.shutdown() } }

    public static let methods = ["server.info", "fs.list", "fs.stat", "fs.read", "fs.hash", "fs.search",
                                 "fs.write", "fs.append", "fs.patch", "fs.mkdir", "fs.copy", "fs.move", "fs.delete",
                                 "upload.begin", "upload.chunk", "upload.status", "upload.commit", "upload.abort",
                                 "exec.start", "exec.poll", "exec.cancel", "exec.list",
                                 "terminal.open", "terminal.list", "terminal.read", "terminal.write", "terminal.resize", "terminal.close"]
}
