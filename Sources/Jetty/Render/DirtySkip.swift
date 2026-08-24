enum DirtySkip {
    static func paletteSignature(
        packed: UnsafePointer<UInt32>,
        defFG: RGB,
        defBG: RGB,
        reverse: Bool
    ) -> UInt64 {
        var h: UInt64 = 2_166_136_261
        h = (h &* 16_777_619) ^ (reverse ? 1 : 0)
        h = (h &* 16_777_619) ^ (UInt64(defFG.r) << 16 | UInt64(defFG.g) << 8 | UInt64(defFG.b))
        h = (h &* 16_777_619) ^ (UInt64(defBG.r) << 16 | UInt64(defBG.g) << 8 | UInt64(defBG.b))
        var i = 0
        while i < 256 {
            h = (h &* 16_777_619) ^ UInt64(packed[i])
            i += 1
        }
        return h
    }

    struct Sel: Equatable {
        var x0: Int
        var y0: Int
        var x1: Int
        var y1: Int
    }

    struct Key: Equatable {
        var integerRow: Int
        var extra: Int
        var contentOffset: Bool
        var inAlt: Bool
        var cols: Int
        var rows: Int
        var cellW: Int
        var cellH: Int
        var originX: Float
        var originY: Float
        var packGeneration: Int
        var reverse: Bool
        var paletteSignature: UInt64
        var selection: Sel?
        var searchSig: UInt64
        var preedit: Bool
    }

    static func fullRebuild(now: Key, last: Key?) -> Bool {
        guard let last else { return true }
        if now.extra != 0 || now.contentOffset { return true }
        if now.integerRow != last.integerRow { return true }
        if now.inAlt != last.inAlt { return true }
        if now.cols != last.cols || now.rows != last.rows { return true }
        if now.cellW != last.cellW || now.cellH != last.cellH { return true }
        if now.originX != last.originX || now.originY != last.originY { return true }
        if now.packGeneration != last.packGeneration { return true }
        if now.reverse != last.reverse { return true }
        if now.paletteSignature != last.paletteSignature { return true }
        if now.selection != nil || now.selection != last.selection { return true }
        if now.searchSig != last.searchSig { return true }
        if now.preedit || now.preedit != last.preedit { return true }
        return false
    }

    /// `true` = expand the paint row; `false` = memcpy from the last presented slot.
    static func expandRows(
        paintRows: Int,
        liveOrigin: Int,
        liveRows: Int,
        dirty: UnsafePointer<UInt8>,
        dirtyCount: Int,
        liveGenChanged: Bool,
        cursorPaintY: Int?,
        lastCursorPaintY: Int?,
        blinkPhaseChanged: Bool,
        rowHasBlink: (Int) -> Bool,
        docRow: (Int) -> Int,
        lastDocId: [Int]
    ) -> [Bool] {
        if paintRows <= 0 { return [] }
        var expand = [Bool](repeating: false, count: paintRows)
        var y = 0
        while y < paintRows {
            let liveY = y - liveOrigin
            let isLive = liveY >= 0 && liveY < liveRows
            if isLive {
                if liveGenChanged {
                    expand[y] = true
                } else if liveY < dirtyCount && dirty[liveY] != 0 {
                    expand[y] = true
                } else if cursorPaintY == y || lastCursorPaintY == y {
                    expand[y] = true
                } else if blinkPhaseChanged && rowHasBlink(y) {
                    expand[y] = true
                }
            } else if y < lastDocId.count && lastDocId[y] == docRow(y) {
                if blinkPhaseChanged && rowHasBlink(y) {
                    expand[y] = true
                }
            } else {
                expand[y] = true
            }
            y += 1
        }
        return expand
    }
}
