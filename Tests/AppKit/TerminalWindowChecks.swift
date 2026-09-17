import AppKit
import Foundation
import LinkProtocol
import LinkServerKit

@main
struct TerminalWindowSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ble-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ServerConfiguration(root: root.path, stateDirectory: root.appendingPathComponent("state").path, keyFile: root.appendingPathComponent("key").path)
        final class Box: @unchecked Sendable { var session: TerminalSession? }
        let box = Box()
        let router = try RequestRouter(configuration: config, terminalOpened: { box.session = $0 })
        defer { router.shutdown() }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = router.handle(RPCRequest(method: "terminal.open", bootID: router.bootID,
            params: ["env": .object(["HOME": .string(root.path), "ZDOTDIR": .string(root.path)])]))
        precondition(response.error == nil)
        let session = box.session!
        session.setLocalControl(true)
        let controller = TerminalWindow(session: session)
        try session.localInput(Data("printf '\\033[32mInteractive %s ready\\033[0m\\n' terminal; printf 'Persistent shell + local takeover\\n'\n".utf8))
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let text = String(decoding: controller.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            if text.contains("Interactive terminal ready") { break }
        }
        let rendered = String(decoding: controller.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        precondition(rendered.contains("Interactive terminal ready"), "Terminal did not display output")
        print("Terminal frame: \(controller.terminal.frame), rendered output verified")
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let control = buttons(controller.window!.contentView!).first { $0.title == "Return Control" }!
        control.performClick(nil)
        let agent = try session.poll(); precondition(agent.object!["owner"] == .string("agent"))
        controller.terminal.send(txt: "touch forbidden\n")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        control.performClick(nil)
        let local = try session.poll(); precondition(local.object!["owner"] == .string("local"))
        if CommandLine.arguments.count > 1 {
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(controller.window!.windowNumber), CommandLine.arguments[1]]
        try capture.run(); capture.waitUntilExit()
        precondition(capture.terminationStatus == 0)
        }
        controller.window!.performClose(nil)
        precondition(session.running)
        print("PASS: terminal window rendering, local/agent buttons, blocked typing, hide preserves shell")
    }
}
