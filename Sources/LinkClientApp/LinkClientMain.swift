import Foundation
import LinkProtocol
import LinkBluetooth

@main
struct LinkClientMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        do {
            if args.contains("--help") {
                print("link-client --key /path/client.key [--name 'Laptop Link'] [--request /path/request.json] [--timeout 120]")
                print("Default request: server.info. JSON responses go to stdout; diagnostics go to stderr.")
                return
            }
            guard let keyPath = option("--key") else { throw RPCError("arguments", "--key is required") }
            let key = try Data(contentsOf: URL(fileURLWithPath: keyPath))
            guard key.count == 32 else { throw RPCError("arguments", "Key file must contain 32 bytes") }
            let request: RPCRequest
            if let path = option("--request") {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 131_072 else { throw RPCError("limit", "Request exceeds 128 KiB") }
                request = try WireJSON.decode(RPCRequest.self, from: data)
            } else { request = RPCRequest(method: "server.info") }
            let timeout = option("--timeout").flatMap(Int.init) ?? 120
            guard (1...3600).contains(timeout) else { throw RPCError("arguments", "timeout must be 1–3600 seconds") }
            let client = try LinkCentralClient(key: key, name: option("--name"), request: request, timeout: timeout) { result in
                do {
                    let response = try result.get()
                    try FileHandle.standardOutput.write(contentsOf: WireJSON.encode(response) + Data([10]))
                    exit(response.error == nil ? 0 : 2)
                } catch { fail(error) }
            }
            withExtendedLifetime(client) { dispatchMain() }
        } catch { fail(error) }
    }

    private static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
}
