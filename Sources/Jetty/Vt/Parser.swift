import CVt

public final class Parser {
    private let vt: OpaquePointer
    private let glue: ParserGlue
    private var host = jt_vt_host()

    public unowned(unsafe) var screen: Screen?
    public var writes: [UInt8] = []
    public var bells: Int = 0
    public var ptyWriter: (([UInt8]) -> Void)?

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
    }

    deinit {
        jt_vt_destroy(vt)
    }

    public func reset() {
        jt_vt_reset(vt)
        writes.removeAll()
        bells = 0
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
}
