import AppKit
import Jetty
import Metal

@main
enum JettyMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        }
    }
}

@MainActor
final class TermWindow: NSObject, NSWindowDelegate {
    let session: TerminalSession
    let view: MetalTerminalView
    let window: NSWindow
    var onClose: (() -> Void)?

    init(session: TerminalSession, view: MetalTerminalView, window: NSWindow) {
        self.session = session
        self.view = view
        self.window = window
        super.init()
        window.delegate = self
    }

    func windowDidBecomeKey(_ notification: Notification) {
        view.reportFocus(gained: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        view.reportFocus(gained: false)
    }

    func windowWillClose(_ notification: Notification) {
        session.stop()
        window.delegate = nil
        let done = onClose
        onClose = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                done?()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var device: MTLDevice?
    private var config: AppConfig?
    private var terms: [TermWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("jetty: no Metal device\n", stderr)
            NSApp.terminate(nil)
            return
        }
        self.device = device
        self.config = AppConfig.load()
        EmbeddedFonts.registerIfNeeded()

        let menu = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu()
        appMenu.submenu?.addItem(
            withTitle: "Hide jetty",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.submenu?.addItem(hideOthers)
        appMenu.submenu?.addItem(.separator())
        appMenu.submenu?.addItem(
            withTitle: "Quit jetty",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(appMenu)
        let file = NSMenuItem()
        file.submenu = NSMenu(title: "File")
        let neu = NSMenuItem(
            title: "New Window",
            action: #selector(newWindow(_:)),
            keyEquivalent: "n"
        )
        neu.target = self
        file.submenu?.addItem(neu)
        file.submenu?.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(file)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(MetalTerminalView.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(MetalTerminalView.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(
            withTitle: "Select All",
            action: #selector(MetalTerminalView.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(edit)
        let viewMenu = NSMenuItem()
        viewMenu.submenu = NSMenu(title: "View")
        viewMenu.submenu?.addItem(withTitle: "Actual Size", action: #selector(MetalTerminalView.actualSize(_:)), keyEquivalent: "0")
        viewMenu.submenu?.addItem(withTitle: "Zoom In", action: #selector(MetalTerminalView.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.submenu?.addItem(withTitle: "Zoom Out", action: #selector(MetalTerminalView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.submenu?.addItem(.separator())
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.submenu?.addItem(fullScreen)
        menu.addItem(viewMenu)
        let windowMenu = NSMenuItem()
        windowMenu.submenu = NSMenu(title: "Window")
        windowMenu.submenu?.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        NSApp.windowsMenu = windowMenu.submenu
        menu.addItem(windowMenu)
        NSApp.mainMenu = menu

        if openWindow() == nil {
            fputs("jetty: spawn failed\n", stderr)
            NSApp.terminate(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newWindow(_ sender: Any?) {
        if openWindow() == nil {
            fputs("jetty: spawn failed\n", stderr)
        }
    }

    @discardableResult
    private func openWindow() -> TermWindow? {
        guard let device, let config else { return nil }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let backing = screen.backingScaleFactor
        let metrics = CellMetrics.measure(fontSize: config.fontSize, backingScale: backing)
        let session = TerminalSession(
            cols: config.launchCols,
            rows: config.launchRows,
            cellWidthPx: UInt32(metrics.cellWidthPx),
            cellHeightPx: UInt32(metrics.cellHeightPx),
            scrollbackCapRows: config.scrollbackLines
        )
        let view = MetalTerminalView(
            session: session,
            config: config,
            device: device,
            backingScale: backing
        )

        let grid = view.contentSizePoints(
            backingScale: backing,
            cols: config.launchCols,
            rows: config.launchRows
        )
        let titleH = NSWindow.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled]
        ).height - 100
        let size = NSSize(width: grid.width, height: grid.height + titleH)
        let bg = session.screen.defaultBgRGB

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "jetty"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(
            srgbRed: CGFloat(bg.r) / 255,
            green: CGFloat(bg.g) / 255,
            blue: CGFloat(bg.b) / 255,
            alpha: 1
        )
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        if let key = NSApp.keyWindow {
            var origin = key.frame.origin
            origin.x += 24
            origin.y -= 24
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        session.osc52WriteAllow = config.osc52Write == .allow
        session.osc52ReadAsk = config.osc52Read == .ask
        session.onTitle = { [weak window] title in
            MainActor.assumeIsolated {
                window?.title = title.isEmpty ? "jetty" : title
            }
        }
        let term = TermWindow(session: session, view: view, window: window)
        term.onClose = { [weak self, weak term] in
            self?.terms.removeAll { $0 === term }
        }
        session.onDeath = { [weak window] in
            DispatchQueue.main.async {
                window?.close()
            }
        }
        guard session.spawn() else {
            session.stop()
            return nil
        }
        terms.append(term)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return term
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for term in terms {
            term.session.stop()
        }
        terms.removeAll()
    }
}
