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
    public var onNewWindow: (() -> Void)?
    public var onReloadConfig: (() -> Void)?
    public var onOpenConfig: (() -> Void)?
    public var onToggleSecureInput: (() -> Void)?

    private var renderer: TerminalRenderer?
    private var metrics: CellMetrics
    private let scrollPhysics = ScrollPhysics()
    private var lastFrameTime: CFTimeInterval = 0
    private var selecting = false
    private var selAnchor: (x: Int, y: Int)?
    private var selEnd: (x: Int, y: Int)?
    private var pendingSelect: (x: Int, y: Int)?
    private var selRect = false
    private var pendingRect = false
    private var paint = ContiguousArray<CVt.Cell>()
    private var palPacked = [UInt32](repeating: 0, count: 256)
    private var rgb = [SIMD3<Float>](repeating: .zero, count: 256)
    private var insetLeftPx: Float = 0
    private var insetTopPx: Float = 0
    private var chromePacked: UInt64 = .max
    private var lastLinesScrolled: UInt64 = 0
    private var lastSbCount: Int = 0
    private var lastSafeTop: CGFloat = 0
    private var lastInAlt = false
    private var altScrollPending: Double = 0
    private var lastMouseCell: (x: Int, y: Int)?
    private var mouseWheelPending: Double = 0
    private var mouseHostSelect = false
    private var markedText = NSMutableAttributedString()
    private var imeInsert = false
    private var cursorBlinkWork: DispatchWorkItem?
    private var animWake: DispatchWorkItem?
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
    private var findAccessory: NSTitlebarAccessoryViewController?
    private var findField: NSTextField?
    private var findCountLabel: NSTextField?
    private var findHits: [ScrollSearch.Hit] = []
    private var findSpansByDoc: [Int: [(lo: Int, hi: Int)]] = [:]
    private var findSig: UInt64 = 0
    private var findIndex = 0
    private var autoURLHit: AutoURL.Hit?
    private var progressState: UInt8 = 0
    private var progressPercent: UInt8 = 0
    private var hostBinds = Keybinds.Table()
    public private(set) var isQuitConfirmOpen = false
    private var quitConfirmMode = QuitConfirm.Mode.quit
    private var quitConfirmCompletion: ((Bool) -> Void)?
    private var progressBounceTimer: Timer?
    private var progressStaleTimer: Timer?
    private var progressBouncePos: CGFloat = 0
    private var progressBounceDir: CGFloat = 1
    private let progressChrome = ProgressHairline()

    public init(session: TerminalSession, config: AppConfig, device: MTLDevice, backingScale: CGFloat) {
        self.session = session
        self.config = config
        self.hostBinds = Keybinds.Table(lines: config.keybinds)
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
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
        }
        if let atlas = GlyphAtlas(device: device, metrics: metrics) {
            self.renderer = TerminalRenderer(device: device, atlas: atlas)
        }
        session.cellWidthPx = UInt32(metrics.cellWidthPx)
        session.cellHeightPx = UInt32(metrics.cellHeightPx)
        session.screen.setCellPx(width: session.cellWidthPx, height: session.cellHeightPx)
        session.osc52ReadAsk = config.osc52Read == .ask
        session.screen.setKittyGraphics(config.kittyGraphics)
        session.screen.setOsc52ReadAsk(session.osc52ReadAsk)
        session.onRedraw = { @Sendable [weak self] in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
        registerForDraggedTypes([.fileURL, .string])
        progressChrome.wantsLayer = true
        progressChrome.layerContentsRedrawPolicy = .onSetNeedsDisplay
        progressChrome.layer?.masksToBounds = true
        progressChrome.isHidden = true
        progressChrome.autoresizingMask = [.width, .minYMargin]
        progressChrome.onLayout = { [weak self] in
            self?.applyProgressAppearance()
        }
        session.onProgress = { @Sendable [weak self] state, percent in
            MainActor.assumeIsolated {
                self?.setProgress(state: state, percent: percent)
            }
        }
        session.onOsc5522Prompt = { [weak self] prompt, reply in
            guard let self else {
                reply(.deny)
                return
            }
            self.presentOsc5522Prompt(prompt, reply: reply)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(progressMotionPrefsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
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
    public override var isOpaque: Bool { effectiveBackgroundAlpha() >= 1 }
    /// Grid clicks select.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            abortQuitConfirm()
            stopProgressBounce()
            stopProgressStaleTimer()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome(session.screen.defaultBgRGB, reverse: false)
        refreshInsets()
        if let bar = progressTitlebar() {
            attachProgressChrome(to: bar)
        }
        reportFocus(gained: window?.isKeyWindow == true)
        if progressState != 0 {
            armProgressStaleTimer()
        }
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
            chromePacked = .max
            relayout()
            needsDisplay = true
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        relayout(drawable: size)
    }

    public func draw(in view: MTKView) {
        guard let renderer, let device else { return }
        guard session.tryLockDemand() else { return }
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
            selRect = false
            pendingRect = false
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
            if newRows > 0.5 { clearIdleSelection() }
            let grown = max(0, maxO - Double(lastSbCount))
            let trim = max(0, newRows - grown)
            lastSbCount = sbCount
            if trim > 0.5, !scrollPhysics.pinnedToBottom {
                scrollPhysics.trimTop(trim)
            }
            if findAccessory != nil, trim > 0.5 {
                shiftFindHits(by: Int(trim.rounded()))
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
        let damageGen: UInt32 = liveDirty.withUnsafeMutableBufferPointer { buf -> UInt32 in
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
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 1024)
        var snapN: Int32 = 0
        var rgbaCopy: [UInt32: Data] = [:]
        let animDelay = jt_img_anim_tick(
            session.screen.implPtr,
            UInt64(CACurrentMediaTime() * 1000.0)
        )
        let virtN = jt_img_virtual_n(session.screen.implPtr)
        let relN = jt_img_relative_n(session.screen.implPtr)
        var phHide = ContiguousArray<UInt8>(repeating: 0, count: max(cellCount, 0))
        var phAny = false
        snaps.withUnsafeMutableBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            snapN = jt_img_snapshot(
                session.screen.implPtr,
                Int32(start),
                Int32(paintRows),
                UInt32(cellWPx),
                UInt32(cellHPx),
                p,
                1024
            )
            if virtN > 0, cellCount > 0, cols > 0, paintRows > 0 {
                paint.withUnsafeBufferPointer { cellBuf in
                    phHide.withUnsafeMutableBufferPointer { hideBuf in
                        guard let cp = cellBuf.baseAddress, let hp = hideBuf.baseAddress else { return }
                        let extra = jt_img_placeholder_scan(
                            session.screen.implPtr,
                            cp,
                            Int32(cols),
                            Int32(paintRows),
                            UInt32(cellWPx),
                            UInt32(cellHPx),
                            hp,
                            p + Int(snapN),
                            1024 - snapN
                        )
                        snapN += extra
                    }
                }
                var i = 0
                while i < phHide.count {
                    if phHide[i] != 0 { phAny = true; break }
                    i += 1
                }
            }
            if relN > 0, cols > 0, paintRows > 0 {
                paint.withUnsafeBufferPointer { cellBuf in
                    let extra = jt_img_relative_scan(
                        session.screen.implPtr,
                        cellBuf.baseAddress,
                        Int32(cols),
                        Int32(paintRows),
                        Int32(start),
                        UInt32(cellWPx),
                        UInt32(cellHPx),
                        p + Int(snapN),
                        1024 - snapN
                    )
                    snapN += extra
                }
            }
            if snapN > 1 { jt_img_sort_snaps(p, snapN) }
        }
        if snapN > 0 {
            var i = 0
            while i < Int(snapN) {
                let s = snaps[i]
                if renderer.needsImageUpload(id: s.image_id, generation: s.generation),
                   let rgba = s.rgba, s.width > 0, s.height > 0
                {
                    let n = Int(s.width) * Int(s.height) * 4
                    rgbaCopy[s.image_id] = Data(bytes: rgba, count: n)
                }
                i += 1
            }
        }
        session.unlockDemand()
        if animDelay >= 0 {
            animWake?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.needsDisplay = true
            }
            animWake = item
            let ms = max(Int(animDelay), 1)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(ms),
                execute: item
            )
        }
        applyChrome(defBG, reverse: rev)

        let dw = drawableSize.width
        let dh = drawableSize.height
        let cw = Float(cellWPx)
        let ch = Float(cellHPx)
        let bgA = effectiveBackgroundAlpha()
        let liveOrigin = inAlt ? 0 : sbCount - start
        var sel = selectionCells()
        if let s = sel {
            sel = (s.x0, s.y0 + liveOrigin, s.x1, s.y1 + liveOrigin)
        }
        let curY = cy + liveOrigin
        let focused = window?.isKeyWindow == true
        let preedit = preeditRuns()
        let wantLock = SecureInput.isOn && vis && focused && preedit.isEmpty
            && curY >= 0 && curY < paintRows && cx >= 0 && cx < cols
        let lockGlyph = wantLock ? renderer.atlas.systemSymbol("lock.fill") : .empty
        let showLock = wantLock && lockGlyph.uv.u1 > lockGlyph.uv.u0
        let blinks = !showLock && (curStyle == 0 || curStyle == 1 || curStyle == 3 || curStyle == 5)
        let phaseOn = Int(dtNow * 2) % 2 == 0
        let blinkOn = !blinks || phaseOn
        let blockStyle = curStyle <= 2
        let cursorOn = vis && focused && blockStyle && blinkOn && curY >= 0 && curY < paintRows
            && !showLock
        if vis, blinks, focused { armCursorBlink() }
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
            selection: sel.map {
                DirtySkip.Sel(x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1, rect: selRect)
            },
            searchSig: findSig,
            preedit: !preedit.isEmpty,
            imagesUnderText: (0..<Int(snapN)).contains { snaps[$0].z < 0 },
            imagesVirtual: virtN > 0,
            quitConfirm: isQuitConfirmOpen
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
        if phAny, phHide.count == n {
            var i = 0
            while i < n {
                if phHide[i] != 0 { ligaHide[i] = 1 }
                i += 1
            }
        }
        let wantInk = config.ligatures != .off && (!ligaSpans.isEmpty || lastInk)
        let underText = skipKey.imagesUnderText
        if underText { skipExpand = nil }
        let chromeNeed = isQuitConfirmOpen ? QuitConfirm.instanceCount : 0
        let instCount = n + (underText ? n : 0) + (wantInk ? n : 0) + (showLock ? 1 : 0) + chromeNeed
        var drewLock = false
        var chromeN = 0
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
                        (config.ligatures == .off && !phAny) ? nil : hideBuf.baseAddress
                    var useSkip = skipExpand
                    if useSkip != nil && !renderer.canCopyFromPresented(count: instCount) {
                        useSkip = nil
                    }
                    for _ in 0..<3 {
                        let gen = renderer.atlas.packGeneration
                        if underText {
                            var uy = 0
                            while uy < paintRows {
                                let spans = searchSpans(docRow: start + uy, cols: cols)
                                GridExpand.expandRow(
                                    rowCells: cp + uy * cols,
                                    cols: cols,
                                    rowY: uy,
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
                                    selectionRect: selRect,
                                    searchSpans: spans,
                                    graphemes: graphemes,
                                    hideGlyphs: hidePtr,
                                    bgAlpha: bgA,
                                    pass: .bgOnly,
                                    dest: inst + uy * cols
                                )
                                GridExpand.expandRow(
                                    rowCells: cp + uy * cols,
                                    cols: cols,
                                    rowY: uy,
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
                                    selectionRect: selRect,
                                    searchSpans: spans,
                                    graphemes: graphemes,
                                    hideGlyphs: hidePtr,
                                    bgAlpha: bgA,
                                    pass: .glyphsOnly,
                                    dest: inst + n + uy * cols
                                )
                                uy += 1
                            }
                            if wantInk {
                                let ink = inst + 2 * n
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
                                    dest: inst + n,
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
                            continue
                        }
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
                                        selectionRect: selRect,
                                        searchSpans: searchSpans(docRow: start + y, cols: cols),
                                        graphemes: graphemes,
                                        hideGlyphs: hidePtr,
                                        bgAlpha: bgA,
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
                        } else if findAccessory != nil {
                            var y = 0
                            while y < paintRows {
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
                                    selectionRect: selRect,
                                    searchSpans: searchSpans(docRow: start + y, cols: cols),
                                    graphemes: graphemes,
                                    hideGlyphs: hidePtr,
                                    bgAlpha: bgA,
                                    dest: inst + y * cols
                                )
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
                                selectionRect: selRect,
                                graphemes: graphemes,
                                hideGlyphs: hidePtr,
                                bgAlpha: bgA,
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
                    if showLock {
                        let curF = SIMD3(
                            Float(curRGB.r) / 255, Float(curRGB.g) / 255, Float(curRGB.b) / 255
                        )
                        inst[n + (underText ? n : 0) + (wantInk ? n : 0)] = CellInstance(
                            originX: insetLeftPx + Float(cx) * cw,
                            originY: insetTopPx + Float(curY) * ch,
                            width: cw,
                            height: ch,
                            uv: lockGlyph.uv,
                            fgRGB: curF,
                            bgRGB: .zero,
                            colorAtlas: lockGlyph.color,
                            bgAlpha: 0
                        )
                        drewLock = true
                    }
                    if isQuitConfirmOpen, chromeNeed > 0 {
                        let base = n + (underText ? n : 0) + (wantInk ? n : 0) + (drewLock ? 1 : 0)
                        chromeN = QuitConfirm.write(
                            dest: inst + base,
                            mode: quitConfirmMode,
                            cols: cols,
                            rows: paintRows,
                            cellW: cw,
                            cellH: ch,
                            originX: insetLeftPx,
                            originY: insetTopPx,
                            contentOffsetY: Float(visRows) * ch,
                            fg: dfg,
                            bg: dbg,
                            atlas: renderer.atlas
                        )
                    }
                }
                }
            }
        }
        var overlayN = 0
        var overlayCursorAt = -1
        let ulNeed = underlineOverlayCount(cols: cols, paintRows: paintRows)
        let preNeed = preeditUnderlineCount(preedit, cols: cols, cursorX: cx)
        let curNeed = (!showLock && vis && preedit.isEmpty && curY >= 0 && curY < paintRows
            && (blinkOn || !focused)) ? 4 : 0
        let linkNeed = autoURLOverlayCount(liveOrigin: liveOrigin, paintRows: paintRows)
        let dfg = SIMD3(Float(defFG.r) / 255, Float(defFG.g) / 255, Float(defFG.b) / 255)
        let dbg = SIMD3(Float(defBG.r) / 255, Float(defBG.g) / 255, Float(defBG.b) / 255)
        let imagesOn = snapN > 0
        if ulNeed + curNeed + preNeed + linkNeed > 0,
           let ov = renderer.prepareOverlays(
            count: ulNeed + curNeed + preNeed + linkNeed
           )
        {
            if !imagesOn, curNeed > 0 {
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
            if linkNeed > 0 {
                overlayN += writeAutoURLOverlays(
                    dest: ov,
                    at: overlayN,
                    liveOrigin: liveOrigin,
                    paintRows: paintRows,
                    cellW: cw,
                    cellH: ch,
                    rgb: dfg
                )
            }
            if imagesOn {
                overlayCursorAt = overlayN
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
            }
        }
        var imageBelowBgCount = 0
        var imageBelowTextCount = 0
        var imageOverCount = 0
        if imagesOn {
            var keep = Set<UInt32>()
            var i = 0
            while i < Int(snapN) {
                keep.insert(snaps[i].image_id)
                i += 1
            }
            renderer.pruneImageTextures(keep: keep)
            for (id, data) in rgbaCopy {
                let s = snaps.first { $0.image_id == id }
                guard let s else { continue }
                data.withUnsafeBytes { raw in
                    guard let p = raw.baseAddress else { return }
                    renderer.uploadImage(
                        id: id,
                        generation: s.generation,
                        width: Int(s.width),
                        height: Int(s.height),
                        rgba: p
                    )
                }
            }
            if let inst = renderer.prepareImages(count: Int(snapN)) {
                func band(_ z: Int32) -> Int {
                    if z < -1_073_741_824 { return 0 }
                    if z < 0 { return 1 }
                    return 2
                }
                var di = 0
                while di < Int(snapN) {
                    let s = snaps[di]
                    inst[di] = ImageInstance(
                        ox: CellInstance.i16(insetLeftPx + Float(s.ox)),
                        oy: CellInstance.i16(insetTopPx + Float(s.oy)),
                        sx: CellInstance.u16(Float(s.sx)),
                        sy: CellInstance.u16(Float(s.sy)),
                        u0: s.u0,
                        v0: s.v0,
                        u1: s.u1,
                        v1: s.v1
                    )
                    di += 1
                }
                var draws: [(tex: MTLTexture, start: Int, count: Int, w: Int, h: Int)] = []
                var belowBg = 0
                var belowText = 0
                var over = 0
                var runStart = 0
                while runStart < Int(snapN) {
                    let id = snaps[runStart].image_id
                    let b = band(snaps[runStart].z)
                    var runEnd = runStart + 1
                    while runEnd < Int(snapN),
                          snaps[runEnd].image_id == id,
                          band(snaps[runEnd].z) == b
                    { runEnd += 1 }
                    let count = runEnd - runStart
                    if b == 0 { belowBg += count }
                    else if b == 1 { belowText += count }
                    else { over += count }
                    if let tex = renderer.texture(id: id) {
                        draws.append((
                            tex,
                            runStart,
                            count,
                            Int(snaps[runStart].width),
                            Int(snaps[runStart].height)
                        ))
                    }
                    runStart = runEnd
                }
                renderer.setImageDraws(draws)
                imageBelowBgCount = belowBg
                imageBelowTextCount = belowText
                imageOverCount = over
            }
        } else {
            renderer.setImageDraws([])
        }
        skipKey.packGeneration = renderer.atlas.packGeneration
        let presented = renderer.draw(
            view: self,
            instanceCount: n,
            glyphCount: underText ? n : 0,
            inkCount: wantInk ? n : 0,
            overlayCount: overlayN,
            overlayCursorAt: overlayCursorAt,
            imageBelowBgCount: imageBelowBgCount,
            imageBelowTextCount: imageBelowTextCount,
            imageOverCount: imageOverCount,
            cursorGlyphCount: drewLock ? 1 : 0,
            chromeCount: chromeN,
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
        let alpha = effectiveBackgroundAlpha()
        let alphaByte = UInt64(min(255, max(0, alpha * 255)).rounded())
        let stamp = UInt64(packed) | (alphaByte << 32)
        if stamp == chromePacked { return }
        chromePacked = stamp
        let rf = CGFloat(r) / 255
        let gf = CGFloat(g) / 255
        let bf = CGFloat(b) / 255
        let a = CGFloat(alpha)
        clearColor = MTLClearColorMake(Double(rf), Double(gf), Double(bf), Double(a))
        let opaque = alpha >= 1
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.isOpaque = opaque
        }
        let color = NSColor(srgbRed: rf, green: gf, blue: bf, alpha: a)
        if let window {
            window.isOpaque = opaque
            window.backgroundColor = color
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            paintTitlebar(window, color: color)
            let lum = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            window.appearance = NSAppearance(named: lum < 128 ? .darkAqua : .aqua)
            NSApp.appearance = window.appearance
        }
    }

    /// Solid titlebar fill matching default bg. Native title and traffic lights stay.
    private func paintTitlebar(_ window: NSWindow, color: NSColor) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        titlebar.wantsLayer = true
        titlebar.layer?.backgroundColor = color.cgColor
        guard let container = titlebar.superview else { return }
        container.wantsLayer = true
        container.layer?.backgroundColor = color.cgColor
        for sub in container.subviews {
            if sub is NSVisualEffectView {
                sub.isHidden = true
            }
        }
        if let cls = NSClassFromString("NSTitlebarBackgroundView") {
            for sub in container.subviews where sub.isKind(of: cls) {
                sub.isHidden = true
            }
        }
        attachProgressChrome(to: container)
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
        if handleQuitConfirmKey(event) { return }
        if event.keyCode == UInt16(kVK_Escape), findAccessory != nil {
            endFind()
            return
        }
        if handleHostKeybind(event) { return }
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

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, handleQuitConfirmKey(event) { return true }
        if event.type == .keyDown, handleHostKeybind(event) { return true }
        return super.performKeyEquivalent(with: event)
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

    private func autoURLOverlayCount(liveOrigin: Int, paintRows: Int) -> Int {
        guard let hit = autoURLHit else { return 0 }
        var n = 0
        for s in hit.spans {
            let py = s.y + liveOrigin
            if py >= 0, py < paintRows { n += 1 }
        }
        return n
    }

    private func writeAutoURLOverlays(
        dest: UnsafeMutablePointer<OverlayInstance>,
        at: Int,
        liveOrigin: Int,
        paintRows: Int,
        cellW: Float,
        cellH: Float,
        rgb: SIMD3<Float>
    ) -> Int {
        guard let hit = autoURLHit else { return 0 }
        let t = OverlayPaint.thickness(cellH)
        var w = 0
        for s in hit.spans {
            let py = s.y + liveOrigin
            if py < 0 || py >= paintRows { continue }
            let x0 = max(0, s.x0)
            let x1 = max(x0, s.x1)
            let ox = insetLeftPx + Float(x0) * cellW
            let oy = insetTopPx + Float(py) * cellH
            dest[at + w] = OverlayInstance(
                ox: ox,
                oy: oy + cellH - t * 2,
                sx: cellW * Float(x1 - x0 + 1),
                sy: t,
                r: rgb.x,
                g: rgb.y,
                b: rgb.z,
                a: 1
            )
            w += 1
        }
        return w
    }

    private func setProgress(state: UInt8, percent: UInt8) {
        if !config.progressStyle || state == 0 {
            if progressState == 0 { return }
            progressState = 0
            progressPercent = 0
            stopProgressBounce()
            stopProgressStaleTimer()
            progressBouncePos = 0
            progressBounceDir = 1
            progressChrome.isHidden = true
            return
        }
        let wasBounce = progressIsBounce()
        progressState = state
        progressPercent = percent == 255 ? 255 : min(100, percent)
        if progressIsBounce(), !wasBounce {
            progressBouncePos = 0
            progressBounceDir = 1
        }
        if let bar = progressTitlebar() {
            attachProgressChrome(to: bar)
        }
        progressChrome.isHidden = false
        applyProgressAppearance()
        armProgressStaleTimer()
    }

    private func progressIsBounce() -> Bool {
        if progressState == 0 || progressState > 4 { return false }
        if progressState == 3 { return true }
        if progressState == 4 { return false }
        return progressPercent == 255
    }

    private func progressTitlebar() -> NSView? {
        guard let host = window?.standardWindowButton(.closeButton)?.superview else { return nil }
        return host.superview ?? host
    }

    private func attachProgressChrome(to titlebar: NSView) {
        if progressChrome.superview !== titlebar {
            progressChrome.removeFromSuperview()
            titlebar.addSubview(progressChrome)
        }
        let h: CGFloat = 2
        let w = titlebar.bounds.width
        let y = titlebar.isFlipped ? titlebar.bounds.height - h : 0
        progressChrome.frame = CGRect(x: 0, y: y, width: w, height: h)
        applyProgressAppearance()
    }

    private func applyProgressAppearance() {
        let w = progressChrome.bounds.width
        let h: CGFloat = 2
        guard w > 0 else { return }
        session.lock.lock()
        let ink: RGB
        if progressState == 2 {
            ink = session.screen.paletteColor(1)
        } else if progressState == 4 {
            ink = session.screen.paletteColor(3)
        } else if progressPercent == 100 {
            ink = session.screen.paletteColor(2)
        } else {
            ink = session.screen.defaultFgRGB
        }
        session.lock.unlock()
        let r = CGFloat(ink.r) / 255
        let g = CGFloat(ink.g) / 255
        let b = CGFloat(ink.b) / 255
        let fill = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        if progressIsBounce() {
            progressChrome.trackColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 0.3)
            progressChrome.fillColor = fill
            progressChrome.fillRect = ProgressBounce.fillFrame(
                width: w,
                height: h,
                pos: progressBouncePos
            )
            if window != nil {
                startProgressBounce()
            }
        } else {
            stopProgressBounce()
            progressChrome.trackColor = .clear
            progressChrome.fillColor = fill
            let pct: CGFloat
            if progressPercent == 255 {
                pct = progressState == 4 ? 100 : 0
            } else {
                pct = CGFloat(progressPercent)
            }
            progressChrome.fillRect = CGRect(x: 0, y: 0, width: w * pct / 100, height: h)
        }
        progressChrome.needsDisplay = true
    }

    private func startProgressBounce() {
        let interval = ProgressBounce.tickInterval(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if progressBounceTimer != nil, progressBounceTimer?.timeInterval == interval {
            return
        }
        stopProgressBounce()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stepProgressBounce()
            }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        progressBounceTimer = t
    }

    private func stopProgressBounce() {
        progressBounceTimer?.invalidate()
        progressBounceTimer = nil
    }

    private func armProgressStaleTimer() {
        stopProgressStaleTimer()
        let t = Timer(timeInterval: ProgressBounce.staleTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.setProgress(state: 0, percent: 0)
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        progressStaleTimer = t
    }

    private func stopProgressStaleTimer() {
        progressStaleTimer?.invalidate()
        progressStaleTimer = nil
    }

    private func stepProgressBounce() {
        let next = ProgressBounce.advance(pos: progressBouncePos, dir: progressBounceDir)
        progressBouncePos = next.pos
        progressBounceDir = next.dir
        let w = progressChrome.bounds.width
        guard w > 0 else { return }
        progressChrome.fillRect = ProgressBounce.fillFrame(width: w, height: 2, pos: progressBouncePos)
    }

    @objc private func progressMotionPrefsChanged() {
        guard progressIsBounce(), window != nil else { return }
        startProgressBounce()
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
        if code == kVK_PageUp {
            applyHostScroll(.pageUp)
            return true
        }
        if code == kVK_PageDown {
            applyHostScroll(.pageDown)
            return true
        }
        if code == kVK_Home {
            applyHostScroll(.top)
            return true
        }
        if code == kVK_End {
            applyHostScroll(.bottom)
            return true
        }
        return false
    }

    private enum HostScroll {
        case pageUp, pageDown, top, bottom
    }

    private func applyHostScroll(_ which: HostScroll) {
        session.lock.lock()
        let inAlt = session.screen.inAlt
        let sb = session.screen.scrollbackCount
        let rows = session.screen.rows
        session.lock.unlock()
        if inAlt { return }
        let maxO = Double(sb)
        let vp = Double(max(1, rows))
        switch which {
        case .pageUp:
            scrollPhysics.applyPageImpulse(direction: 1, viewportRows: vp)
        case .pageDown:
            scrollPhysics.applyPageImpulse(direction: -1, viewportRows: vp)
        case .top:
            scrollPhysics.seekExtreme(direction: 1, holdCount: 1, viewportRows: vp, maxOffset: maxO)
        case .bottom:
            scrollPhysics.seekExtreme(direction: -1, holdCount: 1, viewportRows: vp, maxOffset: maxO)
        }
        clearIdleSelection()
        kickScroll()
    }

    @discardableResult
    private func handleHostKeybind(_ event: NSEvent) -> Bool {
        guard let action = hostBinds.action(for: event) else { return false }
        applyHostAction(action)
        return true
    }

    public func performHostAction(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "toggle_fullscreen" {
            window?.toggleFullScreen(nil)
            return true
        }
        guard let action = Keybinds.Table.parseAction(name) else { return false }
        applyHostAction(action)
        return true
    }

    public func presentQuitConfirm(mode: QuitConfirm.Mode, completion: @escaping (Bool) -> Void) {
        if isQuitConfirmOpen {
            completion(false)
            return
        }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        isQuitConfirmOpen = true
        quitConfirmMode = mode
        quitConfirmCompletion = completion
        forceFullRebuild = true
        skipLast = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    public func abortQuitConfirm() {
        resolveQuitConfirm(false)
    }

    @discardableResult
    func handleQuitConfirmKey(_ event: NSEvent) -> Bool {
        guard isQuitConfirmOpen, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch QuitConfirm.reply(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            command: flags.contains(.command)
        ) {
        case .ignore:
            return true
        case .yes:
            resolveQuitConfirm(true)
            return true
        case .no:
            resolveQuitConfirm(false)
            return true
        case .swallow:
            return true
        }
    }

    private func resolveQuitConfirm(_ confirmed: Bool) {
        guard isQuitConfirmOpen else { return }
        isQuitConfirmOpen = false
        let done = quitConfirmCompletion
        quitConfirmCompletion = nil
        forceFullRebuild = true
        skipLast = nil
        needsDisplay = true
        done?(confirmed)
    }

    func applyHostAction(_ action: Keybinds.Action) {
        switch action {
        case .copy: copy(nil)
        case .paste: paste(nil)
        case .selectAll: selectAll(nil)
        case .newWindow: onNewWindow?()
        case .closeWindow: window?.performClose(nil)
        case .increaseFontSize: zoomIn(nil)
        case .decreaseFontSize: zoomOut(nil)
        case .resetFontSize: actualSize(nil)
        case .scrollToTop: applyHostScroll(.top)
        case .scrollToBottom: applyHostScroll(.bottom)
        case .scrollPageUp: applyHostScroll(.pageUp)
        case .scrollPageDown: applyHostScroll(.pageDown)
        case .jumpToPrompt(let dir): jumpPrompt(dir)
        case .startSearch: startFind(nil)
        case .findNext: findNext(nil)
        case .findPrev: findPrevious(nil)
        case .endSearch: endFind()
        case .reloadConfig: onReloadConfig?()
        case .openConfig: onOpenConfig?()
        case .toggleSecureInput: onToggleSecureInput?()
        }
    }

    private func effectiveBackgroundAlpha() -> Float {
        if window?.styleMask.contains(.fullScreen) == true { return 1 }
        return Float(min(1, max(0, config.backgroundOpacity)))
    }

    public func applyLiveConfig(_ next: AppConfig) {
        let opacityChanged = abs(next.backgroundOpacity - config.backgroundOpacity) > 0.001
        config = next
        hostBinds = Keybinds.Table(lines: next.keybinds)
        if opacityChanged {
            forceFullRebuild = true
            chromePacked = .max
        }
        if !next.linkURL, autoURLHit?.osc8 != true {
            autoURLHit = nil
        }
        session.osc52WriteAllow = next.osc52Write == .allow
        session.osc52ReadAsk = next.osc52Read == .ask
        Osc5522StoredPasswords.process = Osc5522StoredPasswords.load()
        session.desktopNotifications = next.desktopNotifications
        session.notifyOnCommandFinish = next.notifyOnCommandFinish
        session.notifyOnCommandFinishAfter = next.notifyOnCommandFinishAfter
        session.notifyOnCommandFinishBell = next.notifyOnCommandFinishBell
        session.notifyOnCommandFinishDesktop = next.notifyOnCommandFinishDesktop
        if !next.progressStyle {
            setProgress(state: 0, percent: 0)
        }
        session.lock.lock()
        session.screen.setPaletteOverlay(next.paletteOverlay, mask: next.paletteOverlayMask)
        session.screen.setKittyGraphics(next.kittyGraphics)
        session.screen.setOsc52ReadAsk(session.osc52ReadAsk)
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
        session.screen.setCellPx(width: session.cellWidthPx, height: session.cellHeightPx)
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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public override func scrollWheel(with event: NSEvent) {
        if isQuitConfirmOpen { return }
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
                selRect = false
                pendingRect = false
                session.writeToPty(keys)
            }
            return
        }
        if event.momentumPhase.contains(.cancelled) || event.phase.contains(.cancelled) {
            scrollPhysics.brake()
            kickScroll()
            if event.phase.isEmpty || event.phase.contains(.cancelled) { return }
        } else if !event.momentumPhase.isEmpty {
            return
        }
        let bs = max(window?.backingScaleFactor ?? 1, 1)
        let chPt = max(CGFloat(cellHPx) / bs, 1)
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * chPt * 3
        let deltaRows = Double(dy / chPt)
        if !event.phase.isEmpty {
            let ended = event.phase.contains(.ended)
            if abs(deltaRows) < 1e-4, !ended { return }
            scrollPhysics.applyPreciseDelta(
                deltaRows: deltaRows,
                timestamp: event.timestamp,
                began: event.phase.contains(.began),
                ended: ended
            )
            if abs(deltaRows) >= 1e-4 { clearIdleSelection() }
            kickScroll()
            return
        }
        if abs(deltaRows) < 1e-4 { return }
        scrollPhysics.applyImpulse(deltaRows: deltaRows)
        clearIdleSelection()
        kickScroll()
    }

    private func kickScroll() {
        needsDisplay = true
    }

    private func searchSpans(docRow: Int, cols: Int) -> [(lo: Int, hi: Int)] {
        guard let spans = findSpansByDoc[docRow] else { return [] }
        return spans.map { (max(0, $0.lo), min(cols - 1, $0.hi)) }
    }

    @objc public func startFind(_ sender: Any?) {
        showFind()
    }

    @objc public func findNext(_ sender: Any?) {
        if findAccessory == nil { showFind(); return }
        stepFind(1)
    }

    @objc public func findPrevious(_ sender: Any?) {
        if findAccessory == nil { showFind(); return }
        stepFind(-1)
    }

    @objc public func previousPrompt(_ sender: Any?) {
        jumpPrompt(-1)
    }

    @objc public func nextPrompt(_ sender: Any?) {
        jumpPrompt(1)
    }

    private func jumpPrompt(_ dir: Int) {
        session.lock.lock()
        let inAlt = session.screen.inAlt
        let lines = session.screen.linesScrolled
        let sb = session.screen.viewportHistoryCount
        let rows = session.screen.rows
        let marks = session.osc133
        session.lock.unlock()
        if inAlt { return }
        let start = Int(scrollPhysics.integerRow(maxOffset: Double(sb)))
        guard let line = PromptJump.target(
            marks: marks.map { ($0.line, $0.action) },
            dir: dir,
            linesScrolled: lines,
            sbLen: sb,
            rows: rows,
            integerRow: start
        ) else { return }
        let doc = PromptJump.docRow(line: line, linesScrolled: lines, sbLen: sb)
        let maxO = Double(sb)
        if doc >= sb {
            scrollPhysics.pinBottom(maxOffset: maxO)
        } else {
            scrollPhysics.smoothTo(offset: Double(doc), maxOffset: maxO)
        }
        clearIdleSelection()
        kickScroll()
    }

    private func showFind() {
        if let field = findField, findAccessory != nil {
            window?.makeFirstResponder(field)
            return
        }
        let field = FindField(string: "")
        field.finder = self
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = self
        field.frame = NSRect(x: 8, y: 3, width: 180, height: 22)
        let count = NSTextField(labelWithString: "0/0")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.drawsBackground = false
        count.frame = NSRect(x: 192, y: 5, width: 52, height: 18)
        let up = findNavButton(symbol: "chevron.up", action: #selector(findNext(_:)))
        let down = findNavButton(symbol: "chevron.down", action: #selector(findPrevious(_:)))
        up.frame = NSRect(x: 248, y: 3, width: 22, height: 22)
        down.frame = NSRect(x: 270, y: 3, width: 22, height: 22)
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        wrap.addSubview(field)
        wrap.addSubview(count)
        wrap.addSubview(up)
        wrap.addSubview(down)
        let acc = NSTitlebarAccessoryViewController()
        acc.view = wrap
        acc.layoutAttribute = .right
        window?.addTitlebarAccessoryViewController(acc)
        findAccessory = acc
        findField = field
        findCountLabel = count
        window?.makeFirstResponder(field)
        relayout()
        needsDisplay = true
    }

    private func findNavButton(symbol: String, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        return b
    }

    private func endFind() {
        if let acc = findAccessory {
            if let i = window?.titlebarAccessoryViewControllers.firstIndex(of: acc) {
                window?.removeTitlebarAccessoryViewController(at: i)
            }
        }
        findAccessory = nil
        findField = nil
        findCountLabel = nil
        findHits = []
        findSpansByDoc = [:]
        findSig = 0
        findIndex = 0
        window?.makeFirstResponder(self)
        relayout()
        needsDisplay = true
    }

    private func rescanFind() {
        let q = findField?.stringValue ?? ""
        session.lock.lock()
        let rows = session.screen.rows
        session.lock.unlock()
        findHits = ScrollSearch.hits(
            query: q, screen: session.screen, liveRows: rows, lock: session.lock
        )
        session.lock.lock()
        let sb = session.screen.scrollbackCount
        session.lock.unlock()
        findIndex = 0
        indexFindSpans()
        if let hit = findHits.first {
            jumpToHit(hit, sb: sb)
        }
        refreshFindCount()
        needsDisplay = true
    }

    private func stepFind(_ dir: Int) {
        guard !findHits.isEmpty else { return }
        findIndex = (findIndex + dir + findHits.count * 4) % findHits.count
        session.lock.lock()
        let sb = session.screen.scrollbackCount
        session.lock.unlock()
        jumpToHit(findHits[findIndex], sb: sb)
        refreshFindCount()
        needsDisplay = true
    }

    private func refreshFindCount() {
        if findHits.isEmpty {
            findCountLabel?.stringValue = "0/0"
        } else {
            findCountLabel?.stringValue = "\(findIndex + 1)/\(findHits.count)"
        }
    }

    private func indexFindSpans() {
        var map: [Int: [(lo: Int, hi: Int)]] = [:]
        for hit in findHits {
            for sp in hit.spans {
                map[sp.docRow, default: []].append((sp.x0, sp.x1))
            }
        }
        findSpansByDoc = map
        var sig: UInt64 = UInt64(findHits.count)
        if let h = findHits.first, let s = h.spans.first {
            sig = sig &* 16_777_619 ^ UInt64(bitPattern: Int64(h.docRow))
            sig = sig &* 16_777_619 ^ UInt64(s.x0) ^ (UInt64(s.x1) << 16)
        }
        findSig = findHits.isEmpty ? 0 : sig
    }

    private func shiftFindHits(by trim: Int) {
        if trim <= 0 { return }
        var next: [ScrollSearch.Hit] = []
        for hit in findHits {
            let spans = hit.spans.compactMap { sp -> ScrollSearch.Span? in
                let r = sp.docRow - trim
                if r < 0 { return nil }
                return ScrollSearch.Span(docRow: r, x0: sp.x0, x1: sp.x1)
            }
            if spans.isEmpty { continue }
            let jump = spans.map(\.docRow).max() ?? (hit.docRow - trim)
            if jump < 0 { continue }
            next.append(ScrollSearch.Hit(docRow: jump, spans: spans))
        }
        findHits = next
        if findIndex >= findHits.count { findIndex = 0 }
        indexFindSpans()
        refreshFindCount()
    }

    private func jumpToHit(_ hit: ScrollSearch.Hit, sb: Int) {
        let maxO = Double(sb)
        if hit.docRow >= sb {
            scrollPhysics.pinBottom(maxOffset: maxO)
        } else {
            scrollPhysics.smoothTo(offset: Double(hit.docRow), maxOffset: maxO)
        }
        clearIdleSelection()
        kickScroll()
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
        if isQuitConfirmOpen { return }
        updateLinkHover(with: event)
        if event.modifierFlags.contains(.shift) { return }
        session.lock.lock()
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        if mode == 1003 {
            _ = reportMouse(event, action: .motion, button: nil)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        updateLinkHover(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        setAutoURLHit(nil)
        NSCursor.arrow.set()
    }

    public override func flagsChanged(with event: NSEvent) {
        updateLinkHover(with: event)
        super.flagsChanged(with: event)
    }

    private func updateLinkHover(with event: NSEvent) {
        let cell = cellAt(event)
        session.lock.lock()
        let mode = session.screen.mouseEvent
        let cmd = event.modifierFlags.contains(.command)
        var hit: AutoURL.Hit?
        var hand = false
        if mode == 0 || cmd {
            if cmd {
                hit = AutoURL.hover(
                    screen: session.screen, x: cell.x, y: cell.y, detect: config.linkURL
                )
                hand = hit != nil
            } else if let uri = session.screen.uri(at: cell.x, y: cell.y),
                      LinkURL.openable(uri) != nil
            {
                hand = true
            }
        }
        session.lock.unlock()
        if mode == 0 || cmd {
            if hand { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        setAutoURLHit(cmd ? hit : nil)
    }

    private func setAutoURLHit(_ next: AutoURL.Hit?) {
        if autoURLHit == next { return }
        autoURLHit = next
        needsDisplay = true
    }

    private func openLink(at event: NSEvent) {
        let cell = cellAt(event)
        session.lock.lock()
        let hit = AutoURL.hover(
            screen: session.screen, x: cell.x, y: cell.y, detect: config.linkURL
        )
        session.lock.unlock()
        guard let url = hit?.url else { return }
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
        session.pasteFromPasteboard(.general)
    }

    private func presentOsc5522Prompt(
        _ prompt: Osc5522Prompt,
        reply: @escaping (Osc5522Decision) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Allow clipboard read?"
        if !prompt.name.isEmpty {
            alert.informativeText = prompt.name
        }
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        if prompt.offersAlways {
            alert.addButton(withTitle: "Always")
            alert.addButton(withTitle: "Ban")
        }
        func decision(_ response: NSApplication.ModalResponse) -> Osc5522Decision {
            let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch response.rawValue {
            case first: return .deny
            case first + 1: return .allow
            case first + 2: return .always
            case first + 3: return .ban
            default: return .deny
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                reply(decision(response))
            }
        } else {
            reply(decision(alert.runModal()))
        }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOperation(sender) != []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isQuitConfirmOpen { return false }
        return session.dropFromPasteboard(sender.draggingPasteboard)
    }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isQuitConfirmOpen { return [] }
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.string) { return .copy }
        return []
    }

    public func reportFocus(gained: Bool) {
        session.lock.lock()
        session.parser.windowFocused = gained
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
        selRect = false
        pendingRect = false
        needsDisplay = true
    }

    private func handleMousePress(_ event: NSEvent, button: UInt8?) {
        if isQuitConfirmOpen {
            if inTitlebarStrip(event) {
                window?.performDrag(with: event)
            }
            return
        }
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
            if event.clickCount >= 3 {
                selectCommandOutput(at: cellAt(event))
            }
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
                selRect = false
                pendingRect = false
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
            selRect = false
            pendingRect = flags.contains(.option)
        }
        needsDisplay = true
    }

    private func handleMouseDrag(_ event: NSEvent, button: UInt8?) {
        if isQuitConfirmOpen { return }
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
        if isQuitConfirmOpen { return }
        if mouseHostSelect {
            finishHostSelect(event)
            mouseHostSelect = false
            return
        }
        session.lock.lock()
        let mode = session.screen.mouseEvent
        session.lock.unlock()
        if event.modifierFlags.contains(.command) {
            if event.clickCount == 1 {
                openLink(at: event)
            }
            return
        }
        if mode != 0 {
            _ = reportMouse(event, action: .release, button: button)
            return
        }
        finishHostSelect(event)
    }

    private func hostSelectDrag(_ event: NSEvent) {
        let cell = cellAt(event)
        if let pending = pendingSelect, (cell.x != pending.x || cell.y != pending.y) {
            selecting = true
            selAnchor = pending
            selRect = pendingRect || event.modifierFlags.contains(.option)
            pendingSelect = nil
        }
        if selecting {
            selEnd = cell
            needsDisplay = true
        }
    }

    private func selectCommandOutput(at cell: (x: Int, y: Int)) {
        session.lock.lock()
        let inAlt = session.screen.inAlt
        let marks = session.osc133.map { (line: $0.line, action: $0.action) }
        let linesScrolled = session.screen.linesScrolled
        let cols = session.screen.cols
        let rows = session.screen.rows
        session.lock.unlock()
        if inAlt { return }
        let doc = CommandOutput.docLine(liveY: cell.y, linesScrolled: linesScrolled)
        let liveEnd = linesScrolled &+ UInt64(max(0, rows))
        guard let span = CommandOutput.span(marks: marks, at: doc, liveEnd: liveEnd) else { return }
        let last = span.end > 0 ? span.end - 1 : span.start
        let y0 = CommandOutput.liveY(doc: span.start, linesScrolled: linesScrolled)
        let y1 = CommandOutput.liveY(doc: last, linesScrolled: linesScrolled)
        selAnchor = (0, y0)
        selEnd = (max(0, cols - 1), y1)
        selRect = false
        selecting = false
        pendingSelect = nil
        pendingRect = false
        needsDisplay = true
        if config.copyOnSelect { copy(nil) }
    }

    private func finishHostSelect(_ event: NSEvent) {
        if selecting {
            selEnd = cellAt(event)
            if config.copyOnSelect { copy(nil) }
        } else {
            selAnchor = nil
            selEnd = nil
            selRect = false
        }
        selecting = false
        pendingSelect = nil
        pendingRect = false
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

    private func clearIdleSelection() {
        if selecting { return }
        if selAnchor == nil, selEnd == nil { return }
        selAnchor = nil
        selEnd = nil
        selRect = false
        pendingSelect = nil
        pendingRect = false
    }

    private func selectedText(_ s: (x0: Int, y0: Int, x1: Int, y1: Int)) -> String {
        session.screen.copySelection(x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1, rect: selRect)
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

private final class ProgressHairline: NSView {
    var onLayout: (() -> Void)?
    var trackColor = NSColor.clear
    var fillColor = NSColor.clear
    var fillRect = CGRect.zero {
        didSet { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if trackColor.alphaComponent > 0 {
            trackColor.setFill()
            bounds.fill()
        }
        if fillColor.alphaComponent > 0, fillRect.intersects(dirtyRect) {
            fillColor.setFill()
            fillRect.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Discrete OSC 9;4 indeterminate marquee. `pos` is 0...1 along the travel.
enum ProgressBounce {
    static let interval: TimeInterval = 0.125
    static let reduceMotionInterval: TimeInterval = 1
    static let chunk: CGFloat = 0.25
    static let step: CGFloat = 0.1
    /// Hide OSC 9;4 if no new report arrives within this interval.
    static let staleTimeout: TimeInterval = 15

    static func tickInterval(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reduceMotionInterval : interval
    }

    static func advance(pos: CGFloat, dir: CGFloat) -> (pos: CGFloat, dir: CGFloat) {
        var p = pos + dir * step
        var d = dir
        if p >= 1 {
            p = 1
            d = -1
        } else if p <= 0 {
            p = 0
            d = 1
        }
        return (p, d)
    }

    static func fillFrame(width: CGFloat, height: CGFloat, pos: CGFloat) -> CGRect {
        let barW = width * chunk
        let x = pos * max(0, width - barW)
        return CGRect(x: x, y: 0, width: barW, height: height)
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

extension MetalTerminalView: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        rescanFind()
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endFind()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            stepFind(shift ? -1 : 1)
            return true
        }
        return false
    }
}

final class FindField: NSTextField {
    weak var finder: MetalTerminalView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command), chars == "g" {
            if flags.contains(.shift) {
                finder?.findPrevious(nil)
            } else {
                finder?.findNext(nil)
            }
            return true
        }
        if flags.contains(.command), !flags.contains(.shift), chars == "f" {
            currentEditor()?.selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func startFind(_ sender: Any?) {
        currentEditor()?.selectAll(nil)
    }

    @objc func findNext(_ sender: Any?) {
        finder?.findNext(sender)
    }

    @objc func findPrevious(_ sender: Any?) {
        finder?.findPrevious(sender)
    }
}
