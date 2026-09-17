import AppKit
@preconcurrency import SwiftTerm
import LinkProtocol
import LinkServerKit

/// Mark terminal-generated replies separately from keyboard/paste/mouse input.
@MainActor
final class SessionTerminalView: TerminalView {
    var replying = false
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        replying = true
        defer { replying = false }
        super.send(source: source, data: data)
    }
}

@MainActor
final class TerminalWindow: NSWindowController, NSWindowDelegate, @preconcurrency TerminalViewDelegate {
    let session: TerminalSession
    let terminal = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    private let control = NSButton(title: "Take Control", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Agent controls input")
    private var timer: Timer?
    private var cursor: Int64 = 0
    private var local = false
    private var syncingSize = false

    init(session: TerminalSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 610),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "BLE Terminal · \(session.id.prefix(8))"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 500, height: 300)
        let root = NSView(); window.contentView = root
        control.target = self; control.action = #selector(toggleControl)
        let close = NSButton(title: "End Session", target: self, action: #selector(endSession))
        let bar = NSStackView(views: [status, control, close]); bar.spacing = 16
        bar.orientation = .horizontal; bar.alignment = .centerY
        terminal.terminalDelegate = self
        for view in [bar, terminal] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            bar.heightAnchor.constraint(equalToConstant: 34),
            terminal.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.center(); window.makeKeyAndOrderFront(nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func refresh() {
        do {
            guard let result = try session.poll(offset: cursor, count: 32_768).object,
                  let output = result["output"]?.object else { return }
            local = result["owner"]?.string == "local"
            let running = result["state"]?.string == "running"
            status.stringValue = running ? (local ? "You control input" : "Agent controls input") : "Session ended"
            control.title = local ? "Return Control" : "Take Control"; control.isEnabled = running
            terminal.allowMouseReporting = local
            if let cols = result["cols"]?.int, let rows = result["rows"]?.int,
               terminal.getTerminal().cols != Int(cols) || terminal.getTerminal().rows != Int(rows) {
                syncingSize = true; terminal.resize(cols: Int(cols), rows: Int(rows)); syncingSize = false
            }
            if output["truncated"]?.bool == true { terminal.feed(text: "\r\n[Older terminal output expired]\r\n") }
            if let text = output["data"]?.string, let data = Data(base64Encoded: text) {
                terminal.feed(byteArray: Array(data)[...])
            }
            cursor = output["next_offset"]?.int ?? cursor
            if !running && cursor == output["total_bytes"]?.int { timer?.invalidate(); timer = nil }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func toggleControl() {
        session.setLocalControl(!local); refresh()
        if local { window?.makeFirstResponder(terminal) }
    }
    @objc private func endSession() { session.localClose(); refresh() }

    // Closing a window hides it; Show Terminals restores it without discarding shell state.
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if !syncingSize { try? session.localResize(cols: newCols, rows: newRows) }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        do {
            if terminal.replying { try session.terminalReply(Data(data)) }
            else { try session.localInput(Data(data)) }
        } catch { status.stringValue = error.localizedDescription; NSSound.beep() }
    }
    func setTerminalTitle(source: TerminalView, title: String) {} // Keep stable session identity visible.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {} // Shell output cannot change the clipboard.
}
