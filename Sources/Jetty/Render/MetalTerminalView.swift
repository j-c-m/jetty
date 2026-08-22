import AppKit
import Carbon.HIToolbox
import CVt
import MetalKit
import QuartzCore
import simd

public final class MetalTerminalView: MTKView, MTKViewDelegate {
    public let session: TerminalSession
    public var config: AppConfig
    public var padPt: CGFloat = 4

    private var renderer: TerminalRenderer?
    private var metrics: CellMetrics
    private let scrollPhysics = ScrollPhysics()
    private var lastFrameTime: CFTimeInterval = 0
    private var selecting = false
    private var selAnchor: (x: Int, y: Int)?
    private var selEnd: (x: Int, y: Int)?
    private var pendingSelect: (x: Int, y: Int)?
    private var paint = ContiguousArray<CVt.Cell>()
    private var palPacked = [UInt32](repeating: 0, count: 256)
    private var rgb = [SIMD3<Float>](repeating: .zero, count: 256)
    private var insetLeftPx: Float = 0
    private var insetTopPx: Float = 0
    private var chromePacked: UInt32 = 0xFFFF_FFFF
    private var lastLinesScrolled: UInt64 = 0
    private var lastSbCount: Int = 0
    private var lastSafeTop: CGFloat = 0
    private var lastInAlt = false
    private var altScrollPending: Double = 0

    public init(session: TerminalSession, config: AppConfig, device: MTLDevice, backingScale: CGFloat) {
        self.session = session
        self.config = config
        self.metrics = CellMetrics.measure(fontSize: config.fontSize, backingScale: backingScale)
        super.init(frame: .zero, device: device)
        self.colorPixelFormat = .bgra8Unorm
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.delegate = self
        self.framebufferOnly = true
        if let atlas = GlyphAtlas(device: device, metrics: metrics) {
            self.renderer = TerminalRenderer(device: device, atlas: atlas)
        }
        session.cellWidthPx = UInt32(metrics.cellWidthPx)
        session.cellHeightPx = UInt32(metrics.cellHeightPx)
        session.onRedraw = { @Sendable [weak self] in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
    }

    required init(coder: NSCoder) { fatalError() }

    public var cellWPx: Int { metrics.cellWidthPx }
    public var cellHPx: Int { metrics.cellHeightPx }

    public func contentSizePoints(backingScale: CGFloat, cols: Int, rows: Int) -> NSSize {
        let bs = max(backingScale, 1)
        let cw = CGFloat(cellWPx) / bs
        let ch = CGFloat(cellHPx) / bs
        return NSSize(width: CGFloat(cols) * cw + 2 * padPt, height: CGFloat(rows) * ch + 2 * padPt)
    }

    public override var acceptsFirstResponder: Bool { true }
    /// Grid clicks select. Titlebar strip still moves the window via `performDrag`.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome(session.screen.defaultBgRGB, reverse: false)
        refreshInsets()
        relayout()
    }

    public override func layout() {
        super.layout()
        let top = safeAreaInsets.top
        if abs(top - lastSafeTop) > 0.5 {
            lastSafeTop = top
            relayout()
            needsDisplay = true
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        relayout(drawable: size)
    }

    public func draw(in view: MTKView) {
        guard let renderer, let device else { return }
        session.lockDemand()
        let cols = session.screen.cols
        let rows = session.screen.rows
        session.screen.copyPalette256(&palPacked)
        let defFG = session.screen.defaultFgRGB
        let defBG = session.screen.defaultBgRGB
        let cx = session.screen.cursorX
        let cy = session.screen.cursorY
        let vis = session.screen.cursorVisible
        let rev = session.screen.reverseVideo
        let inAlt = session.screen.inAlt
        if inAlt != lastInAlt {
            lastInAlt = inAlt
            altScrollPending = 0
            selAnchor = nil
            selEnd = nil
            selecting = false
            pendingSelect = nil
        }
        let produced = session.screen.linesScrolled
        let sbCount = session.screen.scrollbackCount
        let dtNow = CACurrentMediaTime()
        let dt = lastFrameTime > 0 ? dtNow - lastFrameTime : 1.0 / 60.0
        lastFrameTime = dtNow
        var extra = 0
        var start = 0
        var visRows = 0.0
        if !inAlt {
            let maxO = Double(sbCount)
            var newRows = 0.0
            if produced >= lastLinesScrolled {
                newRows = Double(produced - lastLinesScrolled)
            }
            lastLinesScrolled = produced
            let grown = max(0, maxO - Double(lastSbCount))
            let trim = max(0, newRows - grown)
            lastSbCount = sbCount
            if trim > 0.5, !scrollPhysics.pinnedToBottom {
                scrollPhysics.trimTop(trim)
            }
            scrollPhysics.followBottomIfPinned(maxOffset: maxO)
            let moving = scrollPhysics.step(dt: dt, maxOffset: maxO, viewportRows: Double(max(1, rows)))
            if moving { kickScroll() }
            start = Int(scrollPhysics.integerRow(maxOffset: maxO))
            visRows = scrollPhysics.visualOffsetRows(maxOffset: maxO)
            if abs(visRows) >= 1e-6 {
                extra = max(1, Int(ceil(abs(visRows))) + 1)
            }
        }
        let paintRows = rows + extra
        var blank = CVt.Cell.empty
        blank.content = content_scalar(0x20, WIDE_NARROW)
        let cellCount = cols * paintRows
        if paint.count != cellCount {
            paint = ContiguousArray(repeating: blank, count: max(cellCount, 0))
        }
        paint.withUnsafeMutableBufferPointer { dest in
            guard let dp = dest.baseAddress, cols > 0, paintRows > 0 else { return }
            if extra == 0 && (inAlt || start == sbCount) {
                session.screen.blitLiveGrid(to: dp)
            } else {
                var row = 0
                while row < paintRows {
                    session.screen.blitDocumentRow(
                        start + row,
                        to: dp + row * cols,
                        destCols: cols,
                        liveRows: rows,
                        blank: blank
                    )
                    row += 1
                }
            }
        }
        session.unlockDemand()
        applyChrome(defBG, reverse: rev)

        let dw = drawableSize.width
        let dh = drawableSize.height
        let cw = Float(cellWPx)
        let ch = Float(cellHPx)
        let liveOrigin = inAlt ? 0 : sbCount - start
        var sel = selectionCells()
        if let s = sel {
            sel = (s.x0, s.y0 + liveOrigin, s.x1, s.y1 + liveOrigin)
        }
        let curY = cy + liveOrigin
        let cursorOn = vis && window?.isKeyWindow == true && curY >= 0 && curY < paintRows
        let n = cellCount
        if n > 0, let inst = renderer.prepareInstances(count: n) {
            rgb.withUnsafeMutableBufferPointer { pal in
                palPacked.withUnsafeBufferPointer { packed in
                    guard let pp = packed.baseAddress, let dp = pal.baseAddress else { return }
                    GridExpand.fillPalette(pp, reverseVideo: rev, dest: dp)
                }
                let dfg = SIMD3(Float(defFG.r) / 255, Float(defFG.g) / 255, Float(defFG.b) / 255)
                let dbg = SIMD3(Float(defBG.r) / 255, Float(defBG.g) / 255, Float(defBG.b) / 255)
                paint.withUnsafeBufferPointer { cellBuf in
                    guard let cp = cellBuf.baseAddress else { return }
                    for _ in 0..<3 {
                        let gen = renderer.atlas.packGeneration
                        GridExpand.expand(
                            cells: cp,
                            cols: cols,
                            rows: paintRows,
                            cellW: cw,
                            cellH: ch,
                            originX: insetLeftPx,
                            originY: insetTopPx,
                            palette: pal.baseAddress!,
                            defFG: dfg,
                            defBG: dbg,
                            atlas: renderer.atlas,
                            cursorX: cx,
                            cursorY: curY,
                            cursorVisible: cursorOn,
                            selection: sel,
                            dest: inst
                        )
                        if renderer.atlas.packGeneration == gen { break }
                    }
                }
            }
        }
        renderer.draw(
            view: self,
            instanceCount: n,
            viewport: SIMD2(Float(dw), Float(dh)),
            contentOffsetY: Float(visRows) * ch
        )
        _ = device
    }

    private func applyChrome(_ rgb: RGB, reverse: Bool) {
        var r = rgb.r
        var g = rgb.g
        var b = rgb.b
        if reverse {
            r = 255 &- r
            g = 255 &- g
            b = 255 &- b
        }
        let packed = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if packed == chromePacked { return }
        chromePacked = packed
        let rf = CGFloat(r) / 255
        let gf = CGFloat(g) / 255
        let bf = CGFloat(b) / 255
        clearColor = MTLClearColorMake(Double(rf), Double(gf), Double(bf), 1)
        let color = NSColor(srgbRed: rf, green: gf, blue: bf, alpha: 1)
        if let window {
            window.backgroundColor = color
            let lum = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            window.appearance = NSAppearance(named: lum < 128 ? .darkAqua : .aqua)
            NSApp.appearance = window.appearance
        }
    }

    /// Pad plus `safeAreaInsets` so the titlebar / traffic lights do not cover row 0.
    private func gridInsetsPx(backingScale: CGFloat) -> NSEdgeInsets {
        let sa = safeAreaInsets
        let p = padPt
        let bs = max(backingScale, 1)
        return NSEdgeInsets(
            top: (p + sa.top) * bs,
            left: (p + sa.left) * bs,
            bottom: (p + sa.bottom) * bs,
            right: (p + sa.right) * bs
        )
    }

    private func refreshInsets() {
        let bs = max(window?.backingScaleFactor ?? 1, 1)
        let inset = gridInsetsPx(backingScale: bs)
        insetLeftPx = Float(inset.left)
        insetTopPx = Float(inset.top)
    }

    public func relayout(drawable: CGSize? = nil) {
        let size = drawable ?? drawableSize
        let bs = window?.backingScaleFactor ?? 1
        let inset = gridInsetsPx(backingScale: bs)
        let innerW = max(0, size.width - inset.left - inset.right)
        let innerH = max(0, size.height - inset.top - inset.bottom)
        guard size.width > 8, size.height > 8 else { return }
        refreshInsets()
        let cols = max(2, Int(innerW / CGFloat(cellWPx)))
        let rows = max(1, Int(innerH / CGFloat(cellHPx)))
        session.lock.lock()
        let curC = session.screen.cols
        let curR = session.screen.rows
        session.lock.unlock()
        if cols != curC || rows != curR {
            session.setWinsize(cols: cols, rows: rows)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if handleZoomKeys(event) { return }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        session.lock.lock()
        let appCursor = session.screen.decckm
        let inAlt = session.screen.inAlt
        let sb = session.screen.scrollbackCount
        session.lock.unlock()
        guard let bytes = XtermKeyEncoder.bytes(for: event, applicationCursor: appCursor) else {
            super.keyDown(with: event)
            return
        }
        if !inAlt {
            scrollPhysics.pinBottom(maxOffset: Double(sb))
        }
        session.writeToPty(bytes)
    }

    @objc public func zoomIn(_ sender: Any?) { applyFontSize(metrics.fontSize + 1) }
    @objc public func zoomOut(_ sender: Any?) { applyFontSize(metrics.fontSize - 1) }
    @objc public func actualSize(_ sender: Any?) { applyFontSize(config.fontSize) }

    @discardableResult
    private func handleZoomKeys(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_ANSI_Equal || keyCode == kVK_ANSI_KeypadPlus {
            applyFontSize(metrics.fontSize + 1)
            return true
        }
        if keyCode == kVK_ANSI_Minus || keyCode == kVK_ANSI_KeypadMinus {
            applyFontSize(metrics.fontSize - 1)
            return true
        }
        if (keyCode == kVK_ANSI_0 || keyCode == kVK_ANSI_Keypad0) && !flags.contains(.shift) {
            applyFontSize(config.fontSize)
            return true
        }
        return false
    }

    private func applyFontSize(_ next: CGFloat) {
        let next = min(72, max(8, next.rounded()))
        guard abs(next - metrics.fontSize) > 0.1, let device else { return }
        let bs = window?.backingScaleFactor ?? 2
        metrics = CellMetrics.measure(fontSize: next, backingScale: bs)
        if let atlas = GlyphAtlas(device: device, metrics: metrics) {
            renderer?.atlas = atlas
        }
        session.cellWidthPx = UInt32(cellWPx)
        session.cellHeightPx = UInt32(cellHPx)
        relayout()
        session.lock.lock()
        let c = session.screen.cols
        let r = session.screen.rows
        session.lock.unlock()
        session.setWinsize(cols: c, rows: r)
        needsDisplay = true
    }

    public override func scrollWheel(with event: NSEvent) {
        session.lock.lock()
        let inAlt = session.screen.inAlt
        let sendAlt = session.screen.sendsAlternateScroll
        let appCursor = session.screen.decckm
        session.lock.unlock()
        if inAlt {
            if sendAlt {
                let bs = max(window?.backingScaleFactor ?? 1, 1)
                let chPt = max(CGFloat(cellHPx) / bs, 1)
                let dy = event.scrollingDeltaY
                let deltaRows: Double
                if event.hasPreciseScrollingDeltas {
                    deltaRows = Double(dy / chPt)
                } else if dy == 0 {
                    return
                } else {
                    deltaRows = Double(dy > 0 ? max(dy, 1) : min(dy, -1))
                }
                guard let keys = XtermKeyEncoder.alternateScroll(
                    deltaRows: deltaRows,
                    pending: &altScrollPending,
                    applicationCursor: appCursor
                ) else { return }
                selAnchor = nil
                selEnd = nil
                selecting = false
                session.writeToPty(keys)
            }
            return
        }
        let bs = max(window?.backingScaleFactor ?? 1, 1)
        let chPt = max(CGFloat(cellHPx) / bs, 1)
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * chPt * 3
        let deltaRows = Double(dy / chPt)
        if abs(deltaRows) < 1e-4 { return }
        scrollPhysics.applyImpulse(deltaRows: deltaRows)
        kickScroll()
    }

    private func kickScroll() {
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        if inTitlebarStrip(event) {
            if event.clickCount >= 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        window?.makeFirstResponder(self)
        pendingSelect = cellAt(event)
        selecting = false
        selAnchor = nil
        selEnd = nil
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let cell = cellAt(event)
        if let pending = pendingSelect, (cell.x != pending.x || cell.y != pending.y) {
            selecting = true
            selAnchor = pending
            pendingSelect = nil
        }
        if selecting {
            selEnd = cell
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if selecting {
            selEnd = cellAt(event)
            if config.copyOnSelect { copy(nil) }
        } else {
            selAnchor = nil
            selEnd = nil
        }
        selecting = false
        pendingSelect = nil
        needsDisplay = true
    }

    @objc public func copy(_ sender: Any?) {
        guard let s = selectionCells() else { return }
        session.lock.lock()
        let text = selectedText(s)
        session.lock.unlock()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        session.writeToPty(Array(str.utf8))
    }

    @objc public override func selectAll(_ sender: Any?) {
        session.lock.lock()
        let cols = session.screen.cols
        let rows = session.screen.rows
        let sb = session.screen.viewportHistoryCount
        session.lock.unlock()
        selAnchor = (0, -sb)
        selEnd = (max(0, cols - 1), max(0, rows - 1))
        needsDisplay = true
    }

    private func inTitlebarStrip(_ event: NSEvent) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen) else { return false }
        return event.locationInWindow.y >= window.contentLayoutRect.maxY
    }

    private func cellAt(_ event: NSEvent) -> (x: Int, y: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let bs = max(window?.backingScaleFactor ?? 1, 1)
        let sa = safeAreaInsets
        let cw = CGFloat(cellWPx) / bs
        let ch = CGFloat(cellHPx) / bs
        let x = Int(floor((p.x - padPt - sa.left) / cw))
        let yFromTop = Int(floor((bounds.height - p.y - padPt - sa.top) / ch))
        session.lock.lock()
        let cols = session.screen.cols
        let sb = session.screen.viewportHistoryCount
        session.lock.unlock()
        let start = Int(scrollPhysics.integerRow(maxOffset: Double(sb)))
        let docY = start + yFromTop
        let liveY = docY - sb
        return (max(0, min(cols - 1, x)), liveY)
    }

    private func selectionCells() -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard let a = selAnchor, let b = selEnd else { return nil }
        return (a.x, a.y, b.x, b.y)
    }

    private func selectedText(_ s: (x0: Int, y0: Int, x1: Int, y1: Int)) -> String {
        var a = (x: s.x0, y: s.y0)
        var b = (x: s.x1, y: s.y1)
        if a.y > b.y || (a.y == b.y && a.x > b.x) { swap(&a, &b) }
        let sb = session.screen.viewportHistoryCount
        var out = ""
        var y = a.y
        while y <= b.y {
            let liveY = y
            let row: [CVt.Cell]
            if liveY < 0 {
                let hi = sb + liveY
                row = hi >= 0 ? session.screen.historyRow(hi) : []
            } else {
                row = session.screen.row(liveY)
            }
            let lo = y == a.y ? a.x : 0
            let hi = y == b.y ? b.x : row.count - 1
            if !row.isEmpty {
                for x in max(0, lo)...min(row.count - 1, hi) {
                    let p = row[x].contentPayload
                    if p == 0 { continue }
                    if let u = UnicodeScalar(p) { out.append(Character(u)) }
                }
            }
            let wrapped = liveY >= 0 && session.screen.isWrapped(liveY)
            if y < b.y && !wrapped { out.append("\n") }
            y += 1
        }
        return out
    }
}
