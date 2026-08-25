import XCTest
@testable import Jetty

final class DirtySkipTests: XCTestCase {
    func testIdleSecondFrameExpandsOnlyCursorRow() {
        let mask = expand(
            paintRows: 5,
            liveOrigin: 0,
            liveRows: 5,
            dirty: [0, 0, 0, 0, 0],
            liveGenChanged: false,
            cursorPaintY: 4
        )
        XCTAssertEqual(mask, [false, false, false, false, true])
    }

    func testDirtyLiveRowExpandsThatRow() {
        let mask = expand(
            paintRows: 5,
            liveOrigin: 0,
            liveRows: 5,
            dirty: [0, 0, 1, 0, 0],
            liveGenChanged: false,
            cursorPaintY: 4
        )
        XCTAssertEqual(mask, [false, false, true, false, true])
    }

    func testDamageGenChangeExpandsAllLiveHistoryMaySkip() {
        let mask = expand(
            paintRows: 5,
            liveOrigin: 3,
            liveRows: 2,
            dirty: [0, 0],
            liveGenChanged: true,
            lastDocId: [10, 11, 12, 13, 14],
            start: 10
        )
        XCTAssertEqual(mask, [false, false, false, true, true])
    }

    func testHistoryDocIdMismatchExpands() {
        let mask = expand(
            paintRows: 3,
            liveOrigin: 3,
            liveRows: 2,
            dirty: [0, 0],
            liveGenChanged: false,
            lastDocId: [9, 11, 12],
            start: 10
        )
        XCTAssertEqual(mask, [true, false, false])
    }

    func testBlinkPhaseExpandsBlinkRows() {
        let mask = expand(
            paintRows: 4,
            liveOrigin: 0,
            liveRows: 4,
            dirty: [0, 0, 0, 0],
            liveGenChanged: false,
            cursorPaintY: 0,
            blinkPhaseChanged: true,
            blinkRows: [2]
        )
        XCTAssertEqual(mask, [true, false, true, false])
    }

    func testLastCursorRowAlsoExpands() {
        let mask = expand(
            paintRows: 4,
            liveOrigin: 0,
            liveRows: 4,
            dirty: [0, 0, 0, 0],
            liveGenChanged: false,
            cursorPaintY: 3,
            lastCursorPaintY: 1
        )
        XCTAssertEqual(mask, [false, true, false, true])
    }

    func testFullRebuildOnOverscrollSelectionPreedit() {
        let base = DirtySkip.Key(
            integerRow: 10,
            extra: 0,
            contentOffset: false,
            inAlt: false,
            cols: 80,
            rows: 24,
            cellW: 12,
            cellH: 24,
            originX: 0,
            originY: 0,
            packGeneration: 1,
            reverse: false,
            paletteSignature: 9,
            selection: nil,
            searchSig: 0,
            preedit: false
        )
        XCTAssertFalse(DirtySkip.fullRebuild(now: base, last: base))
        var extra = base
        extra.extra = 1
        XCTAssertTrue(DirtySkip.fullRebuild(now: extra, last: base))
        var off = base
        off.contentOffset = true
        XCTAssertTrue(DirtySkip.fullRebuild(now: off, last: base))
        var sel = base
        sel.selection = DirtySkip.Sel(x0: 0, y0: 0, x1: 1, y1: 0)
        XCTAssertTrue(DirtySkip.fullRebuild(now: sel, last: base))
        XCTAssertTrue(DirtySkip.fullRebuild(now: base, last: sel))
        var pre = base
        pre.preedit = true
        XCTAssertTrue(DirtySkip.fullRebuild(now: pre, last: base))
        var row = base
        row.integerRow = 11
        XCTAssertTrue(DirtySkip.fullRebuild(now: row, last: base))
        XCTAssertTrue(DirtySkip.fullRebuild(now: base, last: nil))
        var search = base
        search.searchSig = 1
        XCTAssertTrue(DirtySkip.fullRebuild(now: search, last: base))
        XCTAssertFalse(DirtySkip.fullRebuild(now: search, last: search))
        var stream = base
        stream.selection = DirtySkip.Sel(x0: 0, y0: 0, x1: 2, y1: 2, rect: false)
        var rect = stream
        rect.selection = DirtySkip.Sel(x0: 0, y0: 0, x1: 2, y1: 2, rect: true)
        XCTAssertTrue(DirtySkip.fullRebuild(now: rect, last: stream))
        var under = base
        under.imagesUnderText = true
        XCTAssertTrue(DirtySkip.fullRebuild(now: under, last: under))
        XCTAssertTrue(DirtySkip.fullRebuild(now: under, last: base))
        XCTAssertTrue(DirtySkip.fullRebuild(now: base, last: under))
        XCTAssertFalse(DirtySkip.fullRebuild(now: base, last: base))
    }

    private func expand(
        paintRows: Int,
        liveOrigin: Int,
        liveRows: Int,
        dirty: [UInt8],
        liveGenChanged: Bool,
        cursorPaintY: Int? = nil,
        lastCursorPaintY: Int? = nil,
        blinkPhaseChanged: Bool = false,
        blinkRows: Set<Int> = [],
        lastDocId: [Int] = [],
        start: Int = 0
    ) -> [Bool] {
        dirty.withUnsafeBufferPointer { buf in
            DirtySkip.expandRows(
                paintRows: paintRows,
                liveOrigin: liveOrigin,
                liveRows: liveRows,
                dirty: buf.baseAddress!,
                dirtyCount: dirty.count,
                liveGenChanged: liveGenChanged,
                cursorPaintY: cursorPaintY,
                lastCursorPaintY: lastCursorPaintY,
                blinkPhaseChanged: blinkPhaseChanged,
                rowHasBlink: { blinkRows.contains($0) },
                docRow: { start + $0 },
                lastDocId: lastDocId
            )
        }
    }
}
