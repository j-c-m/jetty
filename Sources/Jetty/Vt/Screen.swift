import CVt
import Foundation

public final class Screen {
    let implPtr: UnsafeMutablePointer<jt_scr>
    public let scrollbackCapRows: Int

    public var cols: Int { Int(implPtr.pointee.cols) }
    public var rows: Int { Int(implPtr.pointee.rows) }
    public var inAlt: Bool { implPtr.pointee.in_alt != 0 }
    public var linesScrolled: UInt64 { implPtr.pointee.lines_scrolled }
    public var scrollbackCount: Int { Int(jt_scr_sb_len(implPtr)) }
    /// History rows the host may pan. Alternate screen never has a viewport into the primary ring.
    public var viewportHistoryCount: Int { inAlt ? 0 : scrollbackCount }
    public var mouseEvent: UInt16 { implPtr.pointee.mouse_event }
    public var mouseSgr: Bool { implPtr.pointee.mouse_sgr != 0 }
    public var tracksMouse: Bool { mouseEvent != 0 }
    public var bracketedPaste: Bool { implPtr.pointee.bracketed_paste != 0 }
    public var focusEvent: Bool { implPtr.pointee.focus_event != 0 }

    public func codepointWidth(_ scalar: UInt32) -> Int {
        Int(jt_codepoint_width(scalar))
    }
    public var mouseAltScroll: Bool { implPtr.pointee.mouse_alt_scroll != 0 }
    /// Ghostty/xterm 1007: wheel → cursor keys when on alt, no mouse report, and alternate-scroll is on.
    public var sendsAlternateScroll: Bool {
        inAlt && mouseEvent == 0 && mouseAltScroll
    }
    public var autoWrap: Bool {
        get { implPtr.pointee.auto_wrap != 0 }
        set { implPtr.pointee.auto_wrap = newValue ? 1 : 0 }
    }
    public var insertMode: Bool {
        get { implPtr.pointee.insert_mode != 0 }
        set { implPtr.pointee.insert_mode = newValue ? 1 : 0 }
    }
    public var originMode: Bool {
        get { implPtr.pointee.origin_mode != 0 }
        set { implPtr.pointee.origin_mode = newValue ? 1 : 0 }
    }

    public var cursorX: Int {
        get { Int(implPtr.pointee.active.pointee.cx) }
        set { implPtr.pointee.active.pointee.cx = Int32(newValue) }
    }
    public var cursorY: Int {
        get { Int(implPtr.pointee.active.pointee.cy) }
        set { implPtr.pointee.active.pointee.cy = Int32(newValue) }
    }
    public var pendingWrap: Bool {
        get { implPtr.pointee.active.pointee.pending_wrap != 0 }
        set { implPtr.pointee.active.pointee.pending_wrap = newValue ? 1 : 0 }
    }
    public var scrollTop: Int { Int(implPtr.pointee.active.pointee.scroll_top) }
    public var scrollBottom: Int { Int(implPtr.pointee.active.pointee.scroll_bottom) }
    public var reverseVideo: Bool {
        get { implPtr.pointee.reverse_video != 0 }
        set { implPtr.pointee.reverse_video = newValue ? 1 : 0 }
    }
    public var cursorVisible: Bool {
        get { implPtr.pointee.cursor_visible != 0 }
        set { implPtr.pointee.cursor_visible = newValue ? 1 : 0 }
    }
    public var decckm: Bool { implPtr.pointee.decckm != 0 }
    public var syncOutput: Bool {
        get { implPtr.pointee.sync_output != 0 }
        set { implPtr.pointee.sync_output = newValue ? 1 : 0 }
    }
    public var cursorStyle: UInt8 {
        get { implPtr.pointee.cursor_style }
        set { implPtr.pointee.cursor_style = newValue }
    }
    public var cursorBlink: Bool {
        get { implPtr.pointee.cursor_blink != 0 }
        set { implPtr.pointee.cursor_blink = newValue ? 1 : 0 }
    }
    public var cursorRGB: RGB {
        let v = implPtr.pointee.cursor_color
        if PackedColor.type(of: v) == 2 { return RGB.packed(v) }
        return defaultFgRGB
    }

    public var penFG: UInt32 {
        get { implPtr.pointee.pen.fg }
        set { implPtr.pointee.pen.fg = newValue }
    }
    public var penBG: UInt32 {
        get { implPtr.pointee.pen.bg }
        set { implPtr.pointee.pen.bg = newValue }
    }
    public var penAttrs: UInt16 {
        get { implPtr.pointee.pen.attrs }
        set { implPtr.pointee.pen.attrs = newValue }
    }

    public init(cols: Int = 80, rows: Int = 25, scrollbackCapRows: Int = 50_000) {
        self.scrollbackCapRows = max(0, scrollbackCapRows)
        let p = UnsafeMutablePointer<jt_scr>.allocate(capacity: 1)
        p.initialize(to: jt_scr())
        self.implPtr = p
        jt_scr_init(p, Int32(max(2, cols)), Int32(max(1, rows)), Int32(self.scrollbackCapRows))
    }

    deinit {
        jt_scr_deinit(implPtr)
        implPtr.deinitialize(count: 1)
        implPtr.deallocate()
    }

    public func printScalar(_ scalar: UInt32) {
        jt_scr_print_scalar(implPtr, scalar)
    }

    public func printRun(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            jt_scr_print_run(implPtr, p, buf.count)
        }
    }

    public func index() { jt_scr_index(implPtr) }
    public func ri() { jt_scr_ri(implPtr) }
    public func cr() { jt_scr_cr(implPtr) }
    public func nel() { jt_scr_nel(implPtr) }
    public func bs() { jt_scr_bs(implPtr) }
    public func tab() { jt_scr_tab(implPtr) }
    public func cup(row: Int, col: Int) { jt_scr_cup(implPtr, Int32(row), Int32(col)) }
    public func el(_ mode: Int) { jt_scr_el(implPtr, Int32(mode)) }
    public func ed(_ mode: Int) { jt_scr_ed(implPtr, Int32(mode)) }
    public func ech(_ n: Int) { jt_scr_ech(implPtr, Int32(n)) }
    public func ich(_ n: Int) { jt_scr_ich(implPtr, Int32(n)) }
    public func dch(_ n: Int) { jt_scr_dch(implPtr, Int32(n)) }
    public func il(_ n: Int) { jt_scr_il(implPtr, Int32(n)) }
    public func dl(_ n: Int) { jt_scr_dl(implPtr, Int32(n)) }
    public func decstbm(top: Int, bot: Int) { jt_scr_decstbm(implPtr, Int32(top), Int32(bot)) }
    public func switchScreenMode(_ mode: Int, enabled: Bool) {
        jt_scr_switch_screen_mode(implPtr, Int32(mode), enabled ? 1 : 0)
    }
    public func decsc() { jt_scr_decsc(implPtr) }
    public func decrc() { jt_scr_decrc(implPtr) }
    public func clearHistory() { jt_scr_clear_history(implPtr) }
    public func resize(cols: Int, rows: Int) {
        jt_scr_resize(implPtr, Int32(cols), Int32(rows))
    }
    public func isWrapped(_ y: Int) -> Bool {
        jt_scr_is_wrapped(implPtr, Int32(y)) != 0
    }

    public func isHistoryWrapped(_ i: Int) -> Bool {
        jt_scr_sb_wrapped(implPtr, Int32(i)) != 0
    }

    /// Document Y: live row ≥ 0, history row = `i - viewportHistoryCount`.
    public func isDocumentWrapped(_ liveY: Int) -> Bool {
        if liveY >= 0 { return isWrapped(liveY) }
        let hi = viewportHistoryCount + liveY
        return hi >= 0 && isHistoryWrapped(hi)
    }

    public func copySelection(x0: Int, y0: Int, x1: Int, y1: Int) -> String {
        var a = (x: x0, y: y0)
        var b = (x: x1, y: y1)
        if a.y > b.y || (a.y == b.y && a.x > b.x) { swap(&a, &b) }
        let sb = viewportHistoryCount
        var out = ""
        var y = a.y
        while y <= b.y {
            let liveY = y
            let row: [Cell]
            if liveY < 0 {
                let hi = sb + liveY
                row = hi >= 0 ? historyRow(hi) : []
            } else {
                row = self.row(liveY)
            }
            let lo = y == a.y ? a.x : 0
            let hi = y == b.y ? b.x : row.count - 1
            if !row.isEmpty {
                for x in max(0, lo)...min(row.count - 1, hi) {
                    let wide = row[x].wide
                    if wide == WIDE_TAIL || wide == WIDE_HEAD { continue }
                    if (row[x].content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME {
                        var n: UInt16 = 0
                        if let cps = jt_grapheme_get(implPtr, row[x].contentPayload, &n) {
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
            if y < b.y && !isDocumentWrapped(liveY) { out.append("\n") }
            y += 1
        }
        return out
    }

    public func row(_ y: Int) -> [Cell] {
        var out = [Cell](repeating: .empty, count: cols)
        let blank = spaceBlank
        out.withUnsafeMutableBufferPointer { dest in
            guard let d = dest.baseAddress else { return }
            jt_scr_copy_row(implPtr, Int32(y), d, Int32(cols), blank)
        }
        return out
    }

    public func historyRow(_ i: Int) -> [Cell] {
        var out = [Cell](repeating: .empty, count: cols)
        let blank = spaceBlank
        out.withUnsafeMutableBufferPointer { dest in
            guard let d = dest.baseAddress else { return }
            jt_scr_copy_sb_row(implPtr, Int32(i), d, Int32(cols), blank)
        }
        return out
    }

    public var cells: [Cell] {
        (0..<rows).flatMap { row($0) }
    }

    public func paletteColor(_ i: Int) -> RGB {
        var pal = [UInt32](repeating: 0, count: 256)
        copyPalette256(&pal)
        return RGB.packed(pal[max(0, min(255, i))])
    }

    public func copyPalette256(_ dest: UnsafeMutablePointer<UInt32>) {
        withUnsafePointer(to: &implPtr.pointee.palette) { ptr in
            ptr.withMemoryRebound(to: UInt32.self, capacity: 256) { src in
                dest.update(from: src, count: 256)
            }
        }
    }

    public var defaultFgRGB: RGB {
        let v = implPtr.pointee.default_fg
        if PackedColor.type(of: v) == 2 { return RGB.packed(v) }
        return paletteColor(7)
    }

    public var defaultBgRGB: RGB {
        let v = implPtr.pointee.default_bg
        if PackedColor.type(of: v) == 2 { return RGB.packed(v) }
        return paletteColor(0)
    }

    public func uri(at x: Int, y: Int) -> String? {
        guard y >= 0, y < rows, x >= 0, x < cols else { return nil }
        let extra = row(y)[x].extra
        guard extra != 0 else { return nil }
        var rare = jt_rare()
        guard jt_rare_get(implPtr, extra, &rare) == 1, let p = rare.uri else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    public func setPaletteOverlay(_ rgb: [UInt32], mask: UInt16) {
        var colors = rgb
        if colors.count < 16 { colors.append(contentsOf: repeatElement(0, count: 16 - colors.count)) }
        colors.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            jt_scr_set_palette_overlay(implPtr, p, mask)
            jt_scr_palette_reset(implPtr)
        }
    }

    @discardableResult
    public func takeDirty(into dest: UnsafeMutablePointer<UInt8>, count: Int) -> UInt32 {
        var gen: UInt32 = 0
        jt_scr_take_dirty(implPtr, dest, Int32(count), &gen)
        return gen
    }

    public func blitLiveGrid(to dest: UnsafeMutablePointer<Cell>) {
        let blank = spaceBlank
        let c = cols
        for y in 0..<rows {
            jt_scr_copy_row(implPtr, Int32(y), dest + y * c, Int32(c), blank)
        }
    }

    public func blitDocumentRow(
        _ docRow: Int,
        to dest: UnsafeMutablePointer<Cell>,
        destCols: Int,
        liveRows: Int,
        blank: Cell
    ) {
        if inAlt {
            if docRow >= 0 && docRow < liveRows {
                jt_scr_copy_row(implPtr, Int32(docRow), dest, Int32(destCols), blank)
            } else {
                for x in 0..<destCols { dest[x] = blank }
            }
            return
        }
        let sb = scrollbackCount
        if docRow < sb {
            jt_scr_copy_sb_row(implPtr, Int32(docRow), dest, Int32(destCols), blank)
            return
        }
        let liveY = docRow - sb
        if liveY >= 0 && liveY < liveRows {
            jt_scr_copy_row(implPtr, Int32(liveY), dest, Int32(destCols), blank)
            return
        }
        for x in 0..<destCols { dest[x] = blank }
    }

    public func glyph(_ x: Int, _ y: Int) -> UInt32 {
        row(y)[x].contentPayload
    }

    public func plainString() -> String {
        var lines: [String] = []
        for y in 0..<rows {
            let r = row(y)
            var s = ""
            s.reserveCapacity(cols)
            for c in r {
                let p = c.contentPayload
                if p == 0 || p == 0x20 {
                    s.append(" ")
                } else if let u = UnicodeScalar(p) {
                    s.append(Character(u))
                }
            }
            while s.last == " " { s.removeLast() }
            lines.append(s)
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private var spaceBlank: Cell {
        var c = Cell.empty
        c.content = content_scalar(0x20, WIDE_NARROW)
        c.fg = implPtr.pointee.pen.fg
        c.bg = implPtr.pointee.pen.bg
        c.attrs = implPtr.pointee.pen.attrs
        return c
    }
}
