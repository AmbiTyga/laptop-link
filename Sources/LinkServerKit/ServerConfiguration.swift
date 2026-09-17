import Foundation
import LinkProtocol
import Darwin

public struct ServerConfiguration: Codable, Sendable {
    public var name: String = "Laptop Link"
    public var root: String
    public var stateDirectory: String
    public var keyFile: String
    public var allowCommands: Bool = true
    public var maximumConcurrentJobs: Int = 4
    public var maximumJobsPerRun: Int = 128
    public var maximumTimeoutSeconds: Int = 3600
    public var outputBytesPerStream: Int = 4_194_304
    public var maximumUploadBytes: Int = 67_108_864

    public init(root: String, stateDirectory: String, keyFile: String) {
        self.root = root; self.stateDirectory = stateDirectory; self.keyFile = keyFile
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LaptopLink/server.json")
    }

    public static func load(_ url: URL) throws -> Self {
        let config = try WireJSON.decode(Self.self, from: Data(contentsOf: url))
        guard config.root.hasPrefix("/"), config.stateDirectory.hasPrefix("/"), config.keyFile.hasPrefix("/"),
              (1...16).contains(config.maximumConcurrentJobs), (1...1024).contains(config.maximumJobsPerRun),
              (1...86400).contains(config.maximumTimeoutSeconds),
              (1024...67_108_864).contains(config.outputBytesPerStream),
              (65_536...1_073_741_824).contains(config.maximumUploadBytes),
              !config.name.isEmpty, config.name.utf8.count <= 64 else {
            throw RPCError("configuration", "Invalid configuration paths or limits")
        }
        return config
    }

    public func readKey() throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: keyFile)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else { throw RPCError("configuration", "Key must only be accessible to its owner (chmod 600)") }
        let key = try Data(contentsOf: URL(fileURLWithPath: keyFile))
        guard key.count == 32 else { throw RPCError("configuration", "Key file must contain exactly 32 random bytes") }
        return key
    }

    public static func initialize(at url: URL, root: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw RPCError("configuration", "Configuration already exists") }
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyURL = directory.appendingPathComponent("client.key")
        let key = try ChannelCrypto.random()
        let fd = Darwin.open(keyURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw RPCError("configuration", "Cannot create enrollment key; existing keys are never overwritten") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: key)
        try handle.close()
        let config = Self(root: URL(fileURLWithPath: root).standardized.path,
                          stateDirectory: directory.appendingPathComponent("state").path, keyFile: keyURL.path)
        try WireJSON.encode(config).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
