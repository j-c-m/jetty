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
    let id = UUID()
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
    var config: AppConfig?
    var terms: [TermWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("jetty: no Metal device\n", stderr)
            NSApp.terminate(nil)
            return
        }
        self.device = device
        self.config = AppConfig.load()
        EmbeddedFonts.registerIfNeeded()
        DesktopNotify.install()

        let menu = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu()
        appMenu.submenu?.addItem(
            withTitle: "Hide Jetty",
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
        let openCfg = NSMenuItem(
            title: "Open Config",
            action: #selector(openConfig(_:)),
            keyEquivalent: ","
        )
        openCfg.target = self
        appMenu.submenu?.addItem(openCfg)
        let reload = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig(_:)),
            keyEquivalent: ","
        )
        reload.keyEquivalentModifierMask = [.command, .shift]
        reload.target = self
        appMenu.submenu?.addItem(reload)
        appMenu.submenu?.addItem(.separator())
        let secure = NSMenuItem(
            title: "Secure Keyboard Entry",
            action: #selector(toggleSecureInput(_:)),
            keyEquivalent: ""
        )
        secure.target = self
        appMenu.submenu?.addItem(secure)
        appMenu.submenu?.addItem(.separator())
        appMenu.submenu?.addItem(
            withTitle: "Quit Jetty",
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
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(
            withTitle: "Find",
            action: #selector(MetalTerminalView.startFind(_:)),
            keyEquivalent: "f"
        )
        edit.submenu?.addItem(
            withTitle: "Find Next",
            action: #selector(MetalTerminalView.findNext(_:)),
            keyEquivalent: "g"
        )
        let findPrev = NSMenuItem(
            title: "Find Previous",
            action: #selector(MetalTerminalView.findPrevious(_:)),
            keyEquivalent: "g"
        )
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(findPrev)
        edit.submenu?.addItem(.separator())
        let prevPrompt = NSMenuItem(
            title: "Previous Prompt",
            action: #selector(MetalTerminalView.previousPrompt(_:)),
            keyEquivalent: "\u{F700}"
        )
        prevPrompt.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(prevPrompt)
        let nextPrompt = NSMenuItem(
            title: "Next Prompt",
            action: #selector(MetalTerminalView.nextPrompt(_:)),
            keyEquivalent: "\u{F701}"
        )
        nextPrompt.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(nextPrompt)
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
        SecureInput.setAutoEnabled(config?.macosAutoSecureInput ?? true)
        securePoll = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(pollSecureInput),
            userInfo: nil,
            repeats: true
        )
        securePoll?.tolerance = 0.1
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SecureInput.setAppActive(true)
        pollSecureInput()
    }

    func applicationDidResignActive(_ notification: Notification) {
        SecureInput.setAppActive(false)
        redrawIfSecureChanged()
    }

    private var securePoll: Timer?
    private var lastSecureOn = false

    private func redrawIfSecureChanged() {
        let on = SecureInput.isOn
        guard on != lastSecureOn else { return }
        lastSecureOn = on
        for term in terms { term.view.needsDisplay = true }
    }

    @objc func pollSecureInput() {
        SecureInput.setAutoEnabled(config?.macosAutoSecureInput ?? true)
        if config?.macosAutoSecureInput == true,
           NSApp.isActive,
           let term = terms.first(where: { $0.window.isKeyWindow })
        {
            term.session.lock.lock()
            let fd = term.session.masterFD
            term.session.lock.unlock()
            SecureInput.setPasswordPrompt(SecureInput.passwordPrompt(fd: fd))
        } else {
            SecureInput.setPasswordPrompt(false)
        }
        redrawIfSecureChanged()
    }

    @objc func toggleSecureInput(_ sender: Any?) {
        SecureInput.toggle()
        lastSecureOn = SecureInput.isOn
        for term in terms { term.view.needsDisplay = true }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureInput(_:)) {
            item.state = SecureInput.isOn ? .on : .off
        }
        return true
    }

    @objc func newWindow(_ sender: Any?) {
        let session = terms.first { $0.window === NSApp.keyWindow }?.session
        newWindow(from: session)
    }

    func newWindow(from session: TerminalSession?) {
        let cwd = session?.inheritWorkingDirectory() ?? ""
        if openWindow(workingDirectory: cwd) == nil {
            fputs("jetty: spawn failed\n", stderr)
        }
    }

    @objc func openConfig(_ sender: Any?) {
        let url = AppConfig.ensureConfigFile()
        let editor = AppConfig.editorCommand() ?? ShellEnv.loginShellEditor()
        if let cmd = AppConfig.openConfigShellCommand(path: url.path, editor: editor) {
            if openWindow(command: cmd) == nil {
                fputs("jetty: spawn failed\n", stderr)
            }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]
        do {
            try p.run()
        } catch {
            fputs("jetty: open config: \(error)\n", stderr)
        }
    }

    @objc func reloadConfig(_ sender: Any?) {
        let next = AppConfig.load()
        config = next
        SecureInput.setAutoEnabled(next.macosAutoSecureInput)
        redrawIfSecureChanged()
        for term in terms {
            term.view.applyLiveConfig(next)
        }
    }

    @discardableResult
    func openWindow(
        workingDirectory: String = "",
        fontSize: Double = 0,
        initialInput: String = "",
        command: String = ""
    ) -> TermWindow? {
        guard let device, var config else { return nil }
        if fontSize > 0 {
            config.fontSize = CGFloat(min(72, max(8, fontSize)))
        }
        let cwd: String?
        if workingDirectory.isEmpty {
            cwd = nil
        } else {
            let path = (workingDirectory as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            cwd = path
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let backing = screen.backingScaleFactor
        let metrics = CellMetrics.measure(
            family: config.fontFamily,
            fontSize: config.fontSize,
            backingScale: backing,
            adjustWidth: config.adjustCellWidth,
            adjustHeight: config.adjustCellHeight
        )
        let session = TerminalSession(
            cols: config.launchCols,
            rows: config.launchRows,
            cellWidthPx: UInt32(metrics.cellWidthPx),
            cellHeightPx: UInt32(metrics.cellHeightPx),
            scrollbackCapRows: config.scrollbackLines
        )
        session.screen.setPaletteOverlay(config.paletteOverlay, mask: config.paletteOverlayMask)
        let view = MetalTerminalView(
            session: session,
            config: config,
            device: device,
            backingScale: backing
        )
        view.onNewWindow = { [weak self, weak session] in
            self?.newWindow(from: session)
        }
        view.onReloadConfig = { [weak self] in self?.reloadConfig(nil) }
        view.onOpenConfig = { [weak self] in self?.openConfig(nil) }
        view.onToggleSecureInput = { [weak self] in self?.toggleSecureInput(nil) }

        let grid = view.contentSizePoints(
            backingScale: backing,
            cols: config.launchCols,
            rows: config.launchRows
        )
        let bg = session.screen.defaultBgRGB

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: grid),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jetty"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        let winAlpha = CGFloat(min(1, max(0, config.backgroundOpacity)))
        window.isOpaque = winAlpha >= 1
        window.backgroundColor = NSColor(
            srgbRed: CGFloat(bg.r) / 255,
            green: CGFloat(bg.g) / 255,
            blue: CGFloat(bg.b) / 255,
            alpha: winAlpha
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
        session.screen.setKittyGraphics(config.kittyGraphics)
        session.desktopNotifications = config.desktopNotifications
        session.notifyOnCommandFinish = config.notifyOnCommandFinish
        session.notifyOnCommandFinishAfter = config.notifyOnCommandFinishAfter
        session.notifyOnCommandFinishBell = config.notifyOnCommandFinishBell
        session.notifyOnCommandFinishDesktop = config.notifyOnCommandFinishDesktop
        session.isNotifyFocused = { [weak window] in
            MainActor.assumeIsolated {
                window?.isKeyWindow == true
            }
        }
        session.onTitle = { [weak window] title in
            MainActor.assumeIsolated {
                window?.title = title.isEmpty ? "Jetty" : title
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
        let extra: [String]
        if command.isEmpty {
            extra = ShellInject.extraEnv(kind: ShellInject.kind(config: config.shellIntegration))
        } else {
            extra = []
        }
        guard session.spawn(
            workingDirectory: cwd, extraEnv: extra, command: command.isEmpty ? nil : command
        ) else {
            session.stop()
            return nil
        }
        if !initialInput.isEmpty {
            session.writeToPty(Array(initialInput.utf8))
        }
        terms.append(term)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return term
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        securePoll?.invalidate()
        SecureInput.shutdown()
        for term in terms {
            term.session.stop()
        }
        terms.removeAll()
    }
}
