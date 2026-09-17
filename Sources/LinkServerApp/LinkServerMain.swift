import Foundation
import AppKit
import LinkProtocol
import LinkServerKit
import LinkBluetooth

@main
struct LinkServerMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--help") {
            print("""
            link-server --init --root /absolute/workspace [--config /path/server.json]
            link-server --stdio [--config /path/server.json]
            link-server [--config /path/server.json]

            Default: launch the menu bar BLE server. First launch asks for a workspace.
            --stdio: local JSON-lines RPC diagnostic mode; no BLE or authentication.
            Configuration: \(ServerConfiguration.defaultURL.path)
            """)
            return
        }
        let configURL = option("--config").map { URL(fileURLWithPath: $0) } ?? ServerConfiguration.defaultURL
        do {
            if args.contains("--init") {
                guard let root = option("--root"), root.hasPrefix("/") else {
                    throw RPCError("arguments", "--init requires --root /absolute/workspace")
                }
                _ = try PathPolicy(root: root)
                try ServerConfiguration.initialize(at: configURL, root: root)
                print("Created \(configURL.path). Enrollment key: \(configURL.deletingLastPathComponent().appendingPathComponent("client.key").path)")
                return
            }
            if args.contains("--stdio") {
                try runStdio(configuration: ServerConfiguration.load(configURL)); return
            }
            let delegate = LinkMenuApp(configURL: configURL)
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.delegate = delegate
            withExtendedLifetime(delegate) { NSApplication.shared.run() }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }

    private static func runStdio(configuration: ServerConfiguration) throws {
        let router = try RequestRouter(configuration: configuration)
        defer { router.shutdown() }
        // Explicit local diagnostic endpoint. The OS controls access to this process's stdin.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            // FileHandle.read(upToCount:) can wait to fill the buffer on a pipe.
            // POSIX read returns the bytes currently available, allowing interactive RPC.
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw RPCError("io", "Cannot read stdin") }
            if count == 0 { break }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= 131_072 else { throw RPCError("limit", "RPC line exceeds 128 KiB") }
                guard !line.isEmpty else { continue }
                let request = try WireJSON.decode(RPCRequest.self, from: line)
                let response = router.handle(request)
                try FileHandle.standardOutput.write(contentsOf: WireJSON.encode(response) + Data([10]))
            }
            guard buffer.count <= 131_072 else { throw RPCError("limit", "RPC line exceeds 128 KiB") }
        }
    }
}
