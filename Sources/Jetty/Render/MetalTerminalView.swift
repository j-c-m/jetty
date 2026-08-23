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
    private var syncHoldStart: UInt64 = 0
    private var syncTimeoutWork: DispatchWorkItem?
    private var cursorBlinkWork: DispatchWorkItem?
    private var liveDirty = ContiguousArray<UInt8>()
    private var skipLast: DirtySkip.Key?
    private var rowDocId: [Int] = []
    private var lastCursorPaintY: Int?
    private var lastBlinkOn = true
    private var lastDamageGen: UInt32 = 0
    private var forceFullRebuild = true
    private let shaper = ShaperCache()
    private var ligaHide = ContiguousArray<UInt8>()
    private var lastInk = false
    private var lastBackingScale: CGFloat

    public init(session: TerminalSession, config: AppConfig, device: MTLDevice, backingScale: CGFloat) {
        self.session = session
        self.config = config
        let scale = max(backingScale, 1)
        self.lastBackingScale = scale
        self.metrics = CellMetrics.measure(
            family: config.fontFamily,
            fontSize: config.fontSize,
            backingScale: scale,
            adjustWidth: config.adjustCellWidth,
            adjustHeight: config.adjustCellHeight
        )
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
        if !syncBackingScale() {
            relayout()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        _ = syncBackingScale()
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
        if skipSyncPresent() { return }
        session.lockDemand()
        let cols = session.screen.cols
        let rows = session.screen.rows
        session.screen.copyPalette256(&palPacked)
        let defFG = session.screen.defaultFgRGB
        let defBG = session.screen.defaultBgRGB
        let cx = session.screen.cursorX
        let cy = session.screen.cursorY
        let vis = session.screen.cursorVisible
        let curStyle = session.screen.cursorStyle
        let curRGB = session.screen.cursorRGB
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
        if liveDirty.count != rows {
            liveDirty = ContiguousArray(repeating: 0, count: max(rows, 0))
        }
        let damageGen = liveDirty.withUnsafeMutableBufferPointer { buf -> UInt32 in
            guard let p = buf.baseAddress, rows > 0 else { return 0 }
            return session.screen.takeDirty(into: p, count: rows)
        }
        var graphemes: [UInt32: [UInt32]] = [:]
        var ulColors: [UInt16: UInt32] = [:]
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
            if cell.extra != 0, ulColors[cell.extra] == nil {
                var rare = jt_rare()
                if jt_rare_get(session.screen.implPtr, cell.extra, &rare) == 1 {
                    ulColors[cell.extra] = rare.ul_color
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
        let focused = window?.isKeyWindow == true
        let blinks = curStyle == 0 || curStyle == 1 || curStyle == 3 || curStyle == 5
        let phaseOn = Int(dtNow * 2) % 2 == 0
        let blinkOn = !blinks || phaseOn
        let blockStyle = curStyle <= 2
        let cursorOn = vis && focused && blockStyle && blinkOn && curY >= 0 && curY < paintRows
        if vis, blinks, focused { armCursorBlink() }
        let preedit = preeditRuns()
        let n = cellCount
        let palSig = palPacked.withUnsafeBufferPointer { buf -> UInt64 in
            guard let p = buf.baseAddress else { return 0 }
            return DirtySkip.paletteSignature(packed: p, defFG: defFG, defBG: defBG, reverse: rev)
        }
        var skipKey = DirtySkip.Key(
            integerRow: start,
            extra: extra,
            contentOffset: abs(visRows) >= 1e-6,
            inAlt: inAlt,
            cols: cols,
            rows: rows,
            cellW: cellWPx,
            cellH: cellHPx,
            originX: insetLeftPx,
            originY: insetTopPx,
            packGeneration: renderer.atlas.packGeneration,
            reverse: rev,
            paletteSignature: palSig,
            selection: sel.map { DirtySkip.Sel(x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1) },
            searchActive: false,
            preedit: !preedit.isEmpty
        )
        var skipExpand: [Bool]?
        if !forceFullRebuild,
           !DirtySkip.fullRebuild(now: skipKey, last: skipLast)
        {
            let blinkPhaseChanged = phaseOn != lastBlinkOn
            let cursorPaintY = (vis && curY >= 0 && curY < paintRows) ? curY : nil
            let lastCur = lastCursorPaintY.flatMap { y in (y >= 0 && y < paintRows) ? y : nil }
            skipExpand = liveDirty.withUnsafeBufferPointer { buf in
                guard let dp = buf.baseAddress else { return nil }
                return DirtySkip.expandRows(
                    paintRows: paintRows,
                    liveOrigin: liveOrigin,
                    liveRows: rows,
                    dirty: dp,
                    dirtyCount: buf.count,
                    liveGenChanged: damageGen != lastDamageGen,
                    cursorPaintY: cursorPaintY,
                    lastCursorPaintY: lastCur,
                    blinkPhaseChanged: blinkPhaseChanged,
                    rowHasBlink: { y in self.paintRowHasBlink(y, cols: cols) },
                    docRow: { y in start + y },
                    lastDocId: self.rowDocId
                )
            }
        }
        if ligaHide.count != n {
            ligaHide = ContiguousArray(repeating: 0, count: max(n, 0))
        }
        var ligaSpans: [LigaSpan] = []
        if config.ligatures != .off, n > 0, cols > 0, paintRows > 0 {
            ligaSpans = ligaHide.withUnsafeMutableBufferPointer { hideBuf in
                paint.withUnsafeBufferPointer { cellBuf in
                    guard let cp = cellBuf.baseAddress, let hp = hideBuf.baseAddress else { return [] }
                    return LigatureExpand.collect(
                        cells: cp,
                        cols: cols,
                        rows: paintRows,
                        mode: config.ligatures,
                        shaper: shaper,
                        font: { bold, italic in self.metrics.face(bold: bold, italic: italic) },
                        fontPx: Int(metrics.fontPx.rounded()),
                        feature: config.fontFeature,
                        hide: hp
                    )
                }
            }
        }
        let wantInk = config.ligatures != .off && (!ligaSpans.isEmpty || lastInk)
        let instCount = n + (wantInk ? n : 0)
        if n > 0, let inst = renderer.prepareInstances(count: instCount) {
            rgb.withUnsafeMutableBufferPointer { pal in
                palPacked.withUnsafeBufferPointer { packed in
                    guard let pp = packed.baseAddress, let dp = pal.baseAddress else { return }
                    GridExpand.fillPalette(pp, reverseVideo: rev, dest: dp)
                }
                let dfg = SIMD3(Float(defFG.r) / 255, Float(defFG.g) / 255, Float(defFG.b) / 255)
                let dbg = SIMD3(Float(defBG.r) / 255, Float(defBG.g) / 255, Float(defBG.b) / 255)
                ligaHide.withUnsafeBufferPointer { hideBuf in
                paint.withUnsafeBufferPointer { cellBuf in
                    guard let cp = cellBuf.baseAddress, let palBase = pal.baseAddress else { return }
                    let hidePtr: UnsafePointer<UInt8>? =
                        config.ligatures == .off ? nil : hideBuf.baseAddress
                    var useSkip = skipExpand
                    if useSkip != nil && !renderer.canCopyFromPresented(count: instCount) {
                        useSkip = nil
                    }
                    for _ in 0..<3 {
                        let gen = renderer.atlas.packGeneration
                        if let mask = useSkip {
                            var y = 0
                            while y < paintRows {
                                if mask[y] {
                                    GridExpand.expandRow(
                                        rowCells: cp + y * cols,
                                        cols: cols,
                                        rowY: y,
                                        cellW: cw,
                                        cellH: ch,
                                        originX: insetLeftPx,
                                        originY: insetTopPx,
                                        palette: palBase,
                                        defFG: dfg,
                                        defBG: dbg,
                                        atlas: renderer.atlas,
                                        cursorX: cx,
                                        cursorY: curY,
                                        cursorVisible: cursorOn && preedit.isEmpty,
                                        blinkOff: !phaseOn,
                                        selection: sel,
                                        graphemes: graphemes,
                                        hideGlyphs: hidePtr,
                                        dest: inst + y * cols
                                    )
                                } else {
                                    renderer.copyPresentedRow(
                                        to: inst, row: y, cols: cols,
                                        inkBase: wantInk ? n : nil
                                    )
                                }
                                y += 1
                            }
                        } else {
                            GridExpand.expand(
                                cells: cp,
                                cols: cols,
                                rows: paintRows,
                                cellW: cw,
                                cellH: ch,
                                originX: insetLeftPx,
                                originY: insetTopPx,
                                palette: palBase,
                                defFG: dfg,
                                defBG: dbg,
                                atlas: renderer.atlas,
                                cursorX: cx,
                                cursorY: curY,
                                cursorVisible: cursorOn && preedit.isEmpty,
                                blinkOff: !phaseOn,
                                selection: sel,
                                graphemes: graphemes,
                                hideGlyphs: hidePtr,
                                dest: inst
                            )
                        }
                        if wantInk {
                            let ink = inst + n
                            ink.update(repeating: .empty, count: n)
                            writeLigaInk(
                                spans: ligaSpans,
                                dest: ink,
                                cells: cp,
                                cols: cols,
                                cellW: cw,
                                cellH: ch,
                                palette: palBase,
                                defFG: dfg,
                                defBG: dbg,
                                blinkOff: !phaseOn
                            )
                        }
                        if !preedit.isEmpty {
                            stampPreedit(
                                preedit,
                                dest: inst,
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
                        }
                        if renderer.atlas.packGeneration == gen { break }
                        useSkip = nil
                    }
                }
                }
            }
        }
        var overlayN = 0
        let ulNeed = underlineOverlayCount(cols: cols, paintRows: paintRows)
        let preNeed = preeditUnderlineCount(preedit, cols: cols, cursorX: cx)
        let curNeed = (vis && preedit.isEmpty && curY >= 0 && curY < paintRows && (blinkOn || !focused)) ? 4 : 0
        let dfg = SIMD3(Float(defFG.r) / 255, Float(defFG.g) / 255, Float(defFG.b) / 255)
        let dbg = SIMD3(Float(defBG.r) / 255, Float(defBG.g) / 255, Float(defBG.b) / 255)
        if ulNeed + curNeed + preNeed > 0, let ov = renderer.prepareOverlays(count: ulNeed + curNeed + preNeed) {
            if curNeed > 0 {
                overlayN += writeCursorOverlay(
                    dest: ov,
                    at: overlayN,
                    style: curStyle,
                    focused: focused,
                    ox: insetLeftPx + Float(cx) * cw,
                    oy: insetTopPx + Float(curY) * ch,
                    cw: cw,
                    ch: ch,
                    rgb: curRGB
                )
            }
            overlayN += writeUnderlineOverlays(
                dest: ov,
                at: overlayN,
                cols: cols,
                paintRows: paintRows,
                cellW: cw,
                cellH: ch,
                defFG: dfg,
                defBG: dbg,
                ulColors: ulColors
            )
            if preNeed > 0 {
                overlayN += writePreeditUnderlineOverlays(
                    dest: ov,
                    at: overlayN,
                    runs: preedit,
                    cols: cols,
                    paintRows: paintRows,
                    cursorX: cx,
                    cursorY: curY,
                    cellW: cw,
                    cellH: ch,
                    rgb: defBG
                )
            }
        }
        skipKey.packGeneration = renderer.atlas.packGeneration
        let presented = renderer.draw(
            view: self,
            instanceCount: n,
            inkCount: wantInk ? n : 0,
            overlayCount: overlayN,
            viewport: SIMD2(Float(dw), Float(dh)),
            contentOffsetY: Float(visRows) * ch
        )
        if presented {
            skipLast = skipKey
            lastDamageGen = damageGen
            lastBlinkOn = phaseOn
            lastCursorPaintY = (vis && curY >= 0 && curY < paintRows) ? curY : nil
            if paintRows > 0 {
                rowDocId = (0..<paintRows).map { start + $0 }
            } else {
                rowDocId = []
            }
            forceFullRebuild = false
            lastInk = wantInk
        } else {
            forceFullRebuild = true
        }
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

    private func skipSyncPresent() -> Bool {
        session.lock.lock()
        let sync = session.screen.syncOutput
        session.lock.unlock()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if Dec2026.skipPresent(sync: sync, holdStart: syncHoldStart, now: now) {
            if syncHoldStart == 0 { syncHoldStart = now }
            armSyncTimeout()
            return true
        }
        if sync {
            session.lock.lock()
            session.screen.syncOutput = false
            session.lock.unlock()
        }
        syncHoldStart = 0
        syncTimeoutWork?.cancel()
        syncTimeoutWork = nil
        return false
    }

    private func armCursorBlink() {
        if cursorBlinkWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.cursorBlinkWork = nil
            self?.needsDisplay = true
        }
        cursorBlinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeCursorOverlay(
        dest: UnsafeMutablePointer<OverlayInstance>,
        at: Int,
        style: UInt8,
        focused: Bool,
        ox: Float,
        oy: Float,
        cw: Float,
        ch: Float,
        rgb: RGB
    ) -> Int {
        let r = Float(rgb.r) / 255
        let g = Float(rgb.g) / 255
        let b = Float(rgb.b) / 255
        let t: Float = max(1, ch * 0.08)
        let bar: Float = max(1, cw * 0.12)
        func quad(_ i: Int, _ x: Float, _ y: Float, _ w: Float, _ h: Float) {
            dest[at + i] = OverlayInstance(ox: x, oy: y, sx: w, sy: h, r: r, g: g, b: b, a: 1)
        }
        let block = style <= 2
        if block && focused { return 0 }
        if block {
            quad(0, ox, oy, cw, t)
            quad(1, ox, oy + ch - t, cw, t)
            quad(2, ox, oy, t, ch)
            quad(3, ox + cw - t, oy, t, ch)
            return 4
        }
        if style == 3 || style == 4 {
            quad(0, ox, oy + ch - t * 2, cw, t * 2)
        } else {
            quad(0, ox, oy, bar, ch)
        }
        return 1
    }

    private func underlineOverlayCount(cols: Int, paintRows: Int) -> Int {
        var n = 0
        var hasBlink = false
        let cap = min(paint.count, cols * paintRows)
        var i = 0
        while i < cap {
            let cell = paint[i]
            if (cell.attrs & UInt16(ATTR_BLINK)) != 0 { hasBlink = true }
            n += OverlayPaint.count(
                attrs: cell.attrs, wide: cell.wide, cellW: Float(cellWPx), cellH: Float(cellHPx)
            )
            i += 1
        }
        if hasBlink { armCursorBlink() }
        return n
    }

    private func writeUnderlineOverlays(
        dest: UnsafeMutablePointer<OverlayInstance>,
        at: Int,
        cols: Int,
        paintRows: Int,
        cellW: Float,
        cellH: Float,
        defFG: SIMD3<Float>,
        defBG: SIMD3<Float>,
        ulColors: [UInt16: UInt32]
    ) -> Int {
        var w = 0
        let cap = min(paint.count, cols * paintRows)
        rgb.withUnsafeBufferPointer { pal in
            guard let palBase = pal.baseAddress else { return }
            var i = 0
            while i < cap {
                let cell = paint[i]
                let x = i % cols
                let y = i / cols
                w += OverlayPaint.write(
                    cell: cell,
                    ox: insetLeftPx + Float(x) * cellW,
                    oy: insetTopPx + Float(y) * cellH,
                    cellW: cellW,
                    cellH: cellH,
                    palette: palBase,
                    defFG: defFG,
                    defBG: defBG,
                    ulColor: cell.extra != 0 ? ulColors[cell.extra] : nil,
                    dest: dest,
                    at: at + w
                )
                i += 1
            }
        }
        return w
    }

    private func armSyncTimeout() {
        if syncTimeoutWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.syncTimeoutWork = nil
            self?.needsDisplay = true
        }
        syncTimeoutWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(Dec2026.timeoutNs / 1_000_000) + 50),
            execute: work
        )
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

    public func applyLiveConfig(_ next: AppConfig) {
        config = next
        session.osc52WriteAllow = next.osc52Write == .allow
        session.osc52ReadAsk = next.osc52Read == .ask
        session.lock.lock()
        session.screen.setPaletteOverlay(next.paletteOverlay, mask: next.paletteOverlayMask)
        session.lock.unlock()
        let bs = max(window?.backingScaleFactor ?? lastBackingScale, 1)
        lastBackingScale = bs
        replaceMetrics(measureMetrics(fontSize: next.fontSize, backingScale: bs))
    }

    private func measureMetrics(fontSize: CGFloat, backingScale: CGFloat) -> CellMetrics {
        CellMetrics.measure(
            family: config.fontFamily,
            fontSize: fontSize,
            backingScale: backingScale,
            adjustWidth: config.adjustCellWidth,
            adjustHeight: config.adjustCellHeight
        )
    }

    private func applyFontSize(_ next: CGFloat) {
        let next = min(72, max(8, next.rounded()))
        guard abs(next - metrics.fontSize) > 0.1 else { return }
        let bs = max(window?.backingScaleFactor ?? lastBackingScale, 1)
        lastBackingScale = bs
        replaceMetrics(measureMetrics(fontSize: next, backingScale: bs))
    }

    /// Remeasure cells when the window moves to a different scale (Retina ↔ 1x).
    @discardableResult
    private func syncBackingScale() -> Bool {
        let bs = max(window?.backingScaleFactor ?? lastBackingScale, 1)
        guard abs(bs - lastBackingScale) > 0.01 else { return false }
        lastBackingScale = bs
        replaceMetrics(measureMetrics(fontSize: metrics.fontSize, backingScale: bs))
        return true
    }

    private func replaceMetrics(_ next: CellMetrics) {
        guard let device else { return }
        shaper.clear()
        metrics = next
        if let atlas = GlyphAtlas(device: device, metrics: metrics) {
            renderer?.atlas = atlas
        }
        forceFullRebuild = true
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
        let cell = cellAt(event)
        session.lock.lock()
        let mode = session.screen.mouseEvent
        let cmd = event.modifierFlags.contains(.command)
        var hand = false
        if (mode == 0 || cmd), cell.y >= 0,
           let uri = session.screen.uri(at: cell.x, y: cell.y),
           LinkURL.openable(uri) != nil {
            hand = true
        }
        session.lock.unlock()
        if mode == 0 || cmd {
            if hand { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        if mode == 1003, !event.modifierFlags.contains(.shift) {
            _ = reportMouse(event, action: .motion, button: nil)
        }
    }

    private func openLink(at event: NSEvent) {
        let cell = cellAt(event)
        guard cell.y >= 0 else { return }
        session.lock.lock()
        let uri = session.screen.uri(at: cell.x, y: cell.y)
        session.lock.unlock()
        guard let uri, let url = LinkURL.openable(uri) else { return }
        NSWorkspace.shared.open(url)
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
        if flags.contains(.command) {
            openLink(at: event)
            return
        }
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
        session.screen.copySelection(x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1)
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

    private func paintRowHasBlink(_ y: Int, cols: Int) -> Bool {
        guard cols > 0, y >= 0 else { return false }
        let base = y * cols
        if base < 0 || base + cols > paint.count { return false }
        var x = 0
        while x < cols {
            if (paint[base + x].attrs & UInt16(ATTR_BLINK)) != 0 { return true }
            x += 1
        }
        return false
    }

    private func preeditUnderlineCount(_ runs: [PreeditRun], cols: Int, cursorX: Int) -> Int {
        var x = cursorX
        var n = 0
        for run in runs {
            if x >= cols { break }
            n += 1
            x += run.width >= 2 && x + 1 < cols ? 2 : 1
        }
        return n
    }

    private func writePreeditUnderlineOverlays(
        dest: UnsafeMutablePointer<OverlayInstance>,
        at: Int,
        runs: [PreeditRun],
        cols: Int,
        paintRows: Int,
        cursorX: Int,
        cursorY: Int,
        cellW: Float,
        cellH: Float,
        rgb: RGB
    ) -> Int {
        guard cursorY >= 0, cursorY < paintRows, cols > 0 else { return 0 }
        let ul = max(1, cellH * 0.08)
        let r = Float(rgb.r) / 255, g = Float(rgb.g) / 255, b = Float(rgb.b) / 255
        var x = cursorX
        var w = 0
        for run in runs {
            if x >= cols { break }
            let cells = run.width >= 2 && x + 1 < cols ? 2 : 1
            let ox = insetLeftPx + Float(x) * cellW
            let oy = insetTopPx + Float(cursorY) * cellH + cellH - ul
            dest[at + w] = OverlayInstance(
                ox: ox, oy: oy, sx: cellW * Float(cells), sy: ul, r: r, g: g, b: b, a: 1
            )
            w += 1
            x += cells
        }
        return w
    }

    private func writeLigaInk(
        spans: [LigaSpan],
        dest: UnsafeMutablePointer<CellInstance>,
        cells: UnsafePointer<CVt.Cell>,
        cols: Int,
        cellW: Float,
        cellH: Float,
        palette: UnsafePointer<SIMD3<Float>>,
        defFG: SIMD3<Float>,
        defBG: SIMD3<Float>,
        blinkOff: Bool
    ) {
        guard let atlas = renderer?.atlas else { return }
        for span in spans {
            let cell = cells[span.row * cols + span.x]
            if blinkOff && (cell.attrs & UInt16(ATTR_BLINK)) != 0 { continue }
            let face = shaper.featuredFont(
                metrics.face(bold: span.bold, italic: span.italic),
                feature: config.fontFeature
            )
            let g = atlas.spanCoverage(text: span.text, font: face, cells: span.n)
            var fg = GridExpand.resolve(cell.fg, palette: palette, def: defFG)
            var bg = GridExpand.resolve(cell.bg, palette: palette, def: defBG)
            if (cell.attrs & UInt16(ATTR_REVERSE)) != 0 { swap(&fg, &bg) }
            if (cell.attrs & UInt16(ATTR_HIDDEN)) != 0 { fg = bg }
            dest[span.row * cols + span.x] = CellInstance(
                originX: insetLeftPx + Float(span.x) * cellW,
                originY: insetTopPx + Float(span.row) * cellH,
                width: cellW * Float(span.n), height: cellH,
                uv: g.uv,
                fgRGB: fg, bgRGB: bg,
                colorAtlas: g.color
            )
        }
    }

    private func stampPreedit(
        _ runs: [PreeditRun],
        dest: UnsafeMutablePointer<CellInstance>,
        cols: Int,
        paintRows: Int,
        cursorX: Int,
        cursorY: Int,
        cellW: Float,
        cellH: Float,
        fg: SIMD3<Float>,
        bg: SIMD3<Float>,
        atlas: GlyphAtlas
    ) {
        guard cursorY >= 0, cursorY < paintRows, cols > 0 else { return }
        var x = cursorX
        for run in runs {
            if x >= cols { break }
            let wide = run.width >= 2 && x + 1 < cols
            let cells = wide ? 2 : 1
            let g = atlas.glyph(scalar: run.scalar, bold: false, italic: false, wide: wide)
            let ox = insetLeftPx + Float(x) * cellW
            let oy = insetTopPx + Float(cursorY) * cellH
            let i = cursorY * cols + x
            dest[i] = CellInstance(
                originX: ox, originY: oy,
                width: cellW * Float(cells), height: cellH,
                uv: g.uv,
                fgRGB: bg, bgRGB: fg,
                colorAtlas: g.color
            )
            if wide, x + 1 < cols {
                dest[i + 1] = CellInstance(
                    originX: ox + cellW, originY: oy,
                    width: 0, height: 0,
                    uv: .empty,
                    fgRGB: .zero, bgRGB: fg,
                    colorAtlas: false
                )
            }
            x += cells
        }
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
        if XtermKeyEncoder.insertTextDefersToEncoder(composing: composing, event: NSApp.currentEvent) {
            return
        }
        writeInsert(text, composing: composing)
    }
}
