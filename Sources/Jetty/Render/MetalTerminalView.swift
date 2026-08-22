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
    private var pageHoldKey: UInt16 = 0
    private var pageHoldCount: Int = 0
    private var lastMouseCell: (x: Int, y: Int)?
    private var mouseWheelPending: Double = 0
    private var mouseHostSelect = false
    private var markedText = NSMutableAttributedString()
    private var imeInsert = false

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
            mouseWheelPending = 0
            lastMouseCell = nil
            mouseHostSelect = false
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
        var graphemes: [UInt32: [UInt32]] = [:]
        for cell in paint {
            if (cell.content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME {
                let id = cell.contentPayload
                if graphemes[id] == nil {
                    var n: UInt16 = 0
                    if let cps = jt_grapheme_get(session.screen.implPtr, id, &n), n > 0 {
                        graphemes[id] = Array(UnsafeBufferPointer(start: cps, count: Int(n)))
                    }
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
        let preedit = preeditRuns()
        var ulSlots = 0
        for run in preedit { ulSlots += run.width }
        let n = cellCount
        var drawn = n
        if n > 0, let inst = renderer.prepareInstances(count: n + ulSlots) {
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
                            cursorVisible: cursorOn && preedit.isEmpty,
                            selection: sel,
                            graphemes: graphemes,
                            dest: inst
                        )
                        if !preedit.isEmpty {
                            drawn = n + stampPreedit(
                                preedit,
                                dest: inst,
                                extraStart: n,
                                cols: cols,
                                paintRows: paintRows,
                                cursorX: cx,
                                cursorY: curY,
                                cellW: cw,
                                cellH: ch,
                                fg: dfg,
                                bg: dbg,
                                atlas: renderer.atlas
                            )
                        } else {
                            drawn = n
                        }
                        if renderer.atlas.packGeneration == gen { break }
                    }
                }
            }
        }
        renderer.draw(
            view: self,
            instanceCount: drawn,
            viewport: SIMD2(Float(dw), Float(dh)),
            contentOffsetY: Float(visRows) * ch
        )
        if !preedit.isEmpty {
            inputContext?.invalidateCharacterCoordinates()
        }
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
        if handleScrollbackKeys(event) { return }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        let wasMarked = hasMarkedText()
        imeInsert = false
        interpretKeyEvents([event])
        if !XtermKeyEncoder.shouldEncodeKeyDown(
            hasMarkedText: hasMarkedText(),
            wasMarked: wasMarked,
            insertTextConsumed: imeInsert
        ) {
            pinLiveBottom()
            return
        }
        session.lock.lock()
        let appCursor = session.screen.decckm
        session.lock.unlock()
        guard let bytes = XtermKeyEncoder.bytes(for: event, applicationCursor: appCursor) else {
            super.keyDown(with: event)
            return
        }
        pinLiveBottom()
        session.writeToPty(bytes)
    }

    public override func doCommand(by selector: Selector) {
        _ = selector
    }

    public override func resignFirstResponder() -> Bool {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        return super.resignFirstResponder()
    }

    private func pinLiveBottom() {
        session.lock.lock()
        let inAlt = session.screen.inAlt
        let sb = session.screen.scrollbackCount
        session.lock.unlock()
        if !inAlt {
            scrollPhysics.pinBottom(maxOffset: Double(sb))
        }
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

    @discardableResult
    private func handleScrollbackKeys(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift)
        else { return false }
        let code = Int(event.keyCode)
        let pageUp = code == kVK_PageUp
        let pageDown = code == kVK_PageDown
        let home = code == kVK_Home
        let end = code == kVK_End
        guard pageUp || pageDown || home || end else { return false }

        session.lock.lock()
        let inAlt = session.screen.inAlt
        let sb = session.screen.scrollbackCount
        let rows = session.screen.rows
        session.lock.unlock()
        if inAlt { return true }

        let maxO = Double(sb)
        let vp = Double(max(1, rows))
        if pageUp || pageDown {
            if event.isARepeat, pageHoldKey == event.keyCode {
                pageHoldCount += 1
            } else {
                pageHoldKey = event.keyCode
                pageHoldCount = 1
            }
            let dir: Double = pageUp ? 1 : -1
            scrollPhysics.applyPageImpulse(direction: dir, holdCount: pageHoldCount, viewportRows: vp)
        } else if home {
            scrollPhysics.seekExtreme(direction: 1, holdCount: 1, viewportRows: vp, maxOffset: maxO)
        } else {
            scrollPhysics.seekExtreme(direction: -1, holdCount: 1, viewportRows: vp, maxOffset: maxO)
        }
        kickScroll()
        return true
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

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public override func scrollWheel(with event: NSEvent) {
        session.lock.lock()
        let inAlt = session.screen.inAlt
        let sendAlt = session.screen.sendsAlternateScroll
        let appCursor = session.screen.decckm
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        if mode != 0 {
            reportWheel(event)
            return
        }
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
        handleMousePress(event, button: 0)
    }

    public override func rightMouseDown(with event: NSEvent) {
        handleMousePress(event, button: 2)
    }

    public override func otherMouseDown(with event: NSEvent) {
        handleMousePress(event, button: event.buttonNumber == 2 ? 1 : nil)
    }

    public override func mouseDragged(with event: NSEvent) {
        handleMouseDrag(event, button: 0)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        handleMouseDrag(event, button: 2)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        handleMouseDrag(event, button: 1)
    }

    public override func mouseUp(with event: NSEvent) {
        handleMouseRelease(event, button: 0)
    }

    public override func rightMouseUp(with event: NSEvent) {
        handleMouseRelease(event, button: 2)
    }

    public override func otherMouseUp(with event: NSEvent) {
        handleMouseRelease(event, button: 1)
    }

    public override func mouseMoved(with event: NSEvent) {
        session.lock.lock()
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        if mode == 1003, !event.modifierFlags.contains(.shift) {
            _ = reportMouse(event, action: .motion, button: nil)
        }
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
        session.lock.lock()
        let bracketed = session.screen.bracketedPaste
        session.lock.unlock()
        session.writeToPty(Clipboard.pasteBytes(Array(str.utf8), bracketed: bracketed))
    }

    public func reportFocus(gained: Bool) {
        session.lock.lock()
        let on = session.screen.focusEvent
        session.lock.unlock()
        guard on else { return }
        session.writeToPty(Clipboard.focusBytes(gained: gained))
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

    private func handleMousePress(_ event: NSEvent, button: UInt8?) {
        if inTitlebarStrip(event) {
            if event.clickCount >= 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        window?.makeFirstResponder(self)
        session.lock.lock()
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        let flags = event.modifierFlags
        if flags.contains(.command) { return }
        let host = mode == 0 || flags.contains(.shift)
        mouseHostSelect = host && mode != 0
        if !host {
            if selAnchor != nil || selEnd != nil {
                selAnchor = nil
                selEnd = nil
                selecting = false
                pendingSelect = nil
                needsDisplay = true
            }
            _ = reportMouse(event, action: .press, button: button)
            return
        }
        let cell = cellAt(event)
        if flags.contains(.shift), selAnchor != nil {
            selecting = true
            pendingSelect = nil
            selEnd = cell
        } else {
            pendingSelect = cell
            selecting = false
            selAnchor = nil
            selEnd = nil
        }
        needsDisplay = true
    }

    private func handleMouseDrag(_ event: NSEvent, button: UInt8?) {
        if mouseHostSelect {
            hostSelectDrag(event)
            return
        }
        session.lock.lock()
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        if mode != 0 {
            if event.modifierFlags.contains(.command) { return }
            _ = reportMouse(event, action: .motion, button: button)
            return
        }
        hostSelectDrag(event)
    }

    private func handleMouseRelease(_ event: NSEvent, button: UInt8?) {
        if mouseHostSelect {
            finishHostSelect(event)
            mouseHostSelect = false
            return
        }
        session.lock.lock()
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        if mode != 0 {
            if !event.modifierFlags.contains(.command) {
                _ = reportMouse(event, action: .release, button: button)
            }
            return
        }
        finishHostSelect(event)
    }

    private func hostSelectDrag(_ event: NSEvent) {
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

    private func finishHostSelect(_ event: NSEvent) {
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

    @discardableResult
    private func reportMouse(_ event: NSEvent, action: MouseReport.Action, button: UInt8?) -> Bool {
        session.lock.lock()
        let mode = session.screen.mouseEvent
        let sgr = session.screen.mouseSgr
        let cols = session.screen.cols
        let rows = session.screen.rows
        session.lock.unlock()
        guard mode != 0 else { return false }
        let cell = viewportCell(event, cols: cols, rows: rows)
        if action == .motion, lastMouseCell?.x == cell.x, lastMouseCell?.y == cell.y {
            return false
        }
        let flags = event.modifierFlags
        guard let bytes = MouseReport.packet(
            mode: mode,
            sgr: sgr,
            action: action,
            button: button,
            x: cell.x + 1,
            y: cell.y + 1,
            shift: flags.contains(.shift),
            meta: flags.contains(.option),
            ctrl: flags.contains(.control)
        ) else { return false }
        lastMouseCell = cell
        session.writeToPty(bytes)
        return true
    }

    private func reportWheel(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
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
        mouseWheelPending += deltaRows
        let n = Int(mouseWheelPending.rounded(.towardZero))
        if n == 0 { return }
        mouseWheelPending -= Double(n)
        let count = min(abs(n), 256)
        let btn: UInt8 = n > 0 ? 64 : 65
        for _ in 0..<count {
            _ = reportMouse(event, action: .press, button: btn)
        }
    }

    private func viewportCell(_ event: NSEvent, cols: Int, rows: Int) -> (x: Int, y: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let bs = max(window?.backingScaleFactor ?? 1, 1)
        let sa = safeAreaInsets
        let cw = CGFloat(cellWPx) / bs
        let ch = CGFloat(cellHPx) / bs
        let x = Int(floor((p.x - padPt - sa.left) / cw))
        let yFromTop = Int(floor((bounds.height - p.y - padPt - sa.top) / ch))
        return (
            max(0, min(max(0, cols - 1), x)),
            max(0, min(max(0, rows - 1), yFromTop))
        )
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
                    let wide = row[x].wide
                    if wide == WIDE_TAIL || wide == WIDE_HEAD { continue }
                    if (row[x].content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME {
                        var n: UInt16 = 0
                        if let cps = jt_grapheme_get(session.screen.implPtr, row[x].contentPayload, &n) {
                            for i in 0..<Int(n) {
                                if let u = UnicodeScalar(cps[i]) { out.append(Character(u)) }
                            }
                        }
                        continue
                    }
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

    private struct PreeditRun {
        var scalar: UInt32
        var width: Int
    }

    private func preeditRuns() -> [PreeditRun] {
        guard markedText.length > 0 else { return [] }
        var out: [PreeditRun] = []
        for u in markedText.string.unicodeScalars {
            let w = jt_codepoint_width(u.value)
            if w <= 0 { continue }
            out.append(PreeditRun(scalar: u.value, width: min(2, Int(w))))
        }
        return out
    }

    private func stampPreedit(
        _ runs: [PreeditRun],
        dest: UnsafeMutablePointer<CellInstance>,
        extraStart: Int,
        cols: Int,
        paintRows: Int,
        cursorX: Int,
        cursorY: Int,
        cellW: Float,
        cellH: Float,
        fg: SIMD3<Float>,
        bg: SIMD3<Float>,
        atlas: GlyphAtlas
    ) -> Int {
        guard cursorY >= 0, cursorY < paintRows, cols > 0 else { return 0 }
        let ul = max(1, cellH * 0.08)
        var x = cursorX
        var written = 0
        for run in runs {
            if x >= cols { break }
            let wide = run.width >= 2 && x + 1 < cols
            let cells = wide ? 2 : 1
            let g = atlas.glyph(scalar: run.scalar, bold: false, italic: false, wide: wide)
            let ox = insetLeftPx + Float(x) * cellW
            let oy = insetTopPx + Float(cursorY) * cellH
            let i = cursorY * cols + x
            dest[i] = CellInstance(
                ox: ox, oy: oy, sx: cellW * Float(cells), sy: cellH,
                u0: g.uv.u0, v0: g.uv.v0, u1: g.uv.u1, v1: g.uv.v1,
                fr: bg.x, fg: bg.y, fb: bg.z, fa: 1,
                br: fg.x, bg: fg.y, bb: fg.z, ba: 1,
                atlas: g.color ? 1 : 0, _pad0: 0, _pad1: 0, _pad2: 0
            )
            if wide, x + 1 < cols {
                dest[i + 1] = CellInstance(
                    ox: ox + cellW, oy: oy, sx: 0, sy: 0,
                    u0: 0, v0: 0, u1: 0, v1: 0,
                    fr: 0, fg: 0, fb: 0, fa: 1,
                    br: fg.x, bg: fg.y, bb: fg.z, ba: 1,
                    atlas: 0, _pad0: 0, _pad1: 0, _pad2: 0
                )
            }
            dest[extraStart + written] = CellInstance(
                ox: ox, oy: oy + cellH - ul, sx: cellW * Float(cells), sy: ul,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: bg.x, fg: bg.y, fb: bg.z, fa: 1,
                br: bg.x, bg: bg.y, bb: bg.z, ba: 1,
                atlas: 0, _pad0: 0, _pad1: 0, _pad2: 0
            )
            written += 1
            x += cells
        }
        return written
    }

    private func cursorCellRect() -> NSRect {
        let bs = max(window?.backingScaleFactor ?? 1, 1)
        let sa = safeAreaInsets
        let cw = CGFloat(cellWPx) / bs
        let ch = CGFloat(cellHPx) / bs
        session.lock.lock()
        let cx = session.screen.cursorX
        let cy = session.screen.cursorY
        let inAlt = session.screen.inAlt
        let sb = session.screen.scrollbackCount
        session.lock.unlock()
        let start = inAlt ? sb : Int(scrollPhysics.integerRow(maxOffset: Double(sb)))
        let liveOrigin = inAlt ? 0 : sb - start
        let visRows = inAlt ? 0.0 : scrollPhysics.visualOffsetRows(maxOffset: Double(sb))
        let x = padPt + sa.left + CGFloat(cx) * cw
        let yFromTop = padPt + sa.top + (CGFloat(cy + liveOrigin) + visRows) * ch
        return NSRect(x: x, y: bounds.height - yFromTop - ch, width: cw, height: ch)
    }

    private func writeInsert(_ text: String, composing: Bool) {
        guard let bytes = XtermKeyEncoder.committedUTF8(text, composing: composing) else { return }
        imeInsert = true
        pinLiveBottom()
        session.writeToPty(bytes)
    }
}

extension MetalTerminalView: @preconcurrency NSTextInputClient {
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        guard markedText.length > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.length)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let s as String:
            text = s
        default:
            text = ""
        }
        if text.isEmpty {
            unmarkText()
            return
        }
        markedText = NSMutableAttributedString(string: text)
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText = NSMutableAttributedString()
        needsDisplay = true
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        _ = range
        _ = actualRange
        return nil
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        _ = range
        _ = actualRange
        let viewRect = cursorCellRect()
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let s as String:
            text = s
        default:
            return
        }
        let composing = hasMarkedText()
        unmarkText()
        let option = NSApp.currentEvent?.type == .keyDown
            && (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
            && !(NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        if XtermKeyEncoder.insertTextDefersToMeta(composing: composing, option: option) {
            return
        }
        writeInsert(text, composing: composing)
    }
}
