import AppKit
import Foundation
import LinkProtocol
import LinkServerKit
import LinkBluetooth

@MainActor
final class LinkMenuApp: NSObject, NSApplicationDelegate {
    private let configURL: URL
    private var router: RequestRouter?
    private var peripheral: LinkPeripheralServer?
    private var item: NSStatusItem?
    private var statusItem: NSMenuItem?
    private var signalSources: [DispatchSourceSignal] = []
    init(configURL: URL) { self.configURL = configURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if !FileManager.default.fileExists(atPath: configURL.path) { try firstLaunch() }
            let configuration = try ServerConfiguration.load(configURL)
            let key = try configuration.readKey()
            let router = try RequestRouter(configuration: configuration)
            self.router = router
            setupMenu(configuration: configuration)
            peripheral = LinkPeripheralServer(name: configuration.name, key: key, status: { [weak self] text in
                FileHandle.standardError.write(Data("\(text)\n".utf8))
                Task { @MainActor in self?.statusItem?.title = text }
            }, handler: { data, completion in router.handle(data, completion: completion) })
            for number in [SIGTERM, SIGINT] {
                Darwin.signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { NSApplication.shared.terminate(nil) }
                signalSources.append(source); source.resume()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "BLE server could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal(); NSApplication.shared.terminate(nil)
        }
    }

    private func firstLaunch() throws {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose the folder for remote filesystem operations"
        panel.message = "Commands run with your macOS account's permissions. This folder is their default working directory."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { throw RPCError("cancelled", "No workspace selected") }
        try ServerConfiguration.initialize(at: configURL, root: url.path)
    }

    private func setupMenu(configuration: ServerConfiguration) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "BLE"
        let menu = NSMenu()
        statusItem = NSMenuItem(title: "Starting Bluetooth…", action: nil, keyEquivalent: "")
        menu.addItem(statusItem!)
        menu.addItem(NSMenuItem(title: "Root: \(configuration.root)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Show configuration folder", action: #selector(showConfiguration), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit BLE server", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu; self.item = item
    }

    @objc private func showConfiguration() {
        NSWorkspace.shared.open(configURL.deletingLastPathComponent())
    }

    func applicationWillTerminate(_ notification: Notification) { router?.shutdown() }
}
