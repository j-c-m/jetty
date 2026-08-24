import CVt

public final class Parser {
    private let vt: OpaquePointer
    private let glue: ParserGlue
    private var host = jt_vt_host()

    public unowned(unsafe) var screen: Screen?
    public var writes: [UInt8] = []
    public var bells: Int = 0
    public var titles: [String] = []
    public var osc52Writes: [(kind: UInt8, b64: [UInt8])] = []
    public var osc52Reads: [UInt8] = []
    public var osc7: [String] = []
    public var osc133: [(UInt8, [UInt8])] = []
    public var ptyWriter: (([UInt8]) -> Void)?
    public var onOsc7: ((String) -> Void)?
    public var onOsc133: ((UInt8, [UInt8]) -> Void)?
    public var onSizeReport: ((Int32) -> Void)?
    public var onHistoryCleared: (() -> Void)?
    public var onNotify: ((String, String) -> Void)?
    public var onProgress: ((UInt8, UInt8) -> Void)?
    public var notifies: [(String, String)] = []
    public var progress: [(UInt8, UInt8)] = []
    public var onTitle: ((String) -> Void)?
    public var onOsc52Write: ((UInt8, [UInt8]) -> Void)?
    public var onOsc52Read: ((UInt8) -> Void)?
    public var onPaletteChanged: (() -> Void)?

    public var state: Int { Int(jt_vt_state(vt)) }

    public init() {
        guard let created = jt_vt_create() else {
            fatalError("jt_vt_create")
        }
        vt = created
        let glue = ParserGlue()
        self.glue = glue
        glue.parser = self
        host.ctx = Unmanaged.passUnretained(glue).toOpaque()
        host.write_pty = jtHostWritePty
        host.bell = jtHostBell
        host.set_title = jtHostSetTitle
        host.osc52_write = jtHostOsc52Write
        host.osc52_read = jtHostOsc52Read
        host.palette_changed = jtHostPaletteChanged
        host.osc7 = jtHostOsc7
        host.osc133 = jtHostOsc133
        host.size_report = jtHostSizeReport
        host.history_cleared = jtHostHistoryCleared
        host.notify = jtHostNotify
        host.progress = jtHostProgress
    }

    deinit {
        jt_vt_destroy(vt)
    }

    public func reset() {
        jt_vt_reset(vt)
        writes.removeAll()
        bells = 0
        titles.removeAll()
        osc52Writes.removeAll()
        osc52Reads.removeAll()
        osc7.removeAll()
        osc133.removeAll()
        notifies.removeAll()
        progress.removeAll()
    }

    public func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        withUnsafePointer(to: &host) { h in
            if let screen {
                jt_vt_feed(vt, bytes, count, screen.implPtr, h)
            } else {
                jt_vt_feed(vt, bytes, count, nil, h)
            }
        }
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            feed(p, count: buf.count)
        }
    }

    public func feed(_ s: String) {
        feed(Array(s.utf8))
    }

    func onWritePty(_ buf: UnsafeBufferPointer<UInt8>) {
        let bytes = Array(buf)
        writes.append(contentsOf: bytes)
        ptyWriter?(bytes)
    }

    func onBell() {
        bells += 1
    }

    func handleTitle(_ bytes: [UInt8]) {
        let s = String(bytes: bytes, encoding: .utf8) ?? ""
        titles.append(s)
        onTitle?(s)
    }

    func handleOsc52Write(_ kind: UInt8, _ b64: [UInt8]) {
        osc52Writes.append((kind, b64))
        onOsc52Write?(kind, b64)
    }

    func handleOsc52Read(_ kind: UInt8) {
        osc52Reads.append(kind)
        onOsc52Read?(kind)
    }

    func handlePaletteChanged() {
        onPaletteChanged?()
    }

    func handleOsc7(_ bytes: [UInt8]) {
        let s = String(bytes: bytes, encoding: .utf8) ?? ""
        osc7.append(s)
        onOsc7?(s)
    }

    func handleOsc133(_ action: UInt8, _ opts: [UInt8]) {
        osc133.append((action, opts))
        onOsc133?(action, opts)
    }

    func handleSizeReport(_ kind: Int32) {
        onSizeReport?(kind)
    }

    func handleHistoryCleared() {
        onHistoryCleared?()
    }

    func handleNotify(_ title: [UInt8], _ body: [UInt8]) {
        let t = String(bytes: title, encoding: .utf8) ?? ""
        let b = String(bytes: body, encoding: .utf8) ?? ""
        notifies.append((t, b))
        onNotify?(t, b)
    }

    func handleProgress(_ state: UInt8, _ percent: UInt8) {
        progress.append((state, percent))
        onProgress?(state, percent)
    }
}
