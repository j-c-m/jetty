import CVt

final class ParserGlue {
    unowned(unsafe) var parser: Parser!
}

func jtHostWritePty(_ ctx: UnsafeMutableRawPointer?, _ p: UnsafePointer<UInt8>?, _ n: Int) {
    guard let ctx, let p, n > 0 else { return }
    let glue = Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue()
    glue.parser.onWritePty(UnsafeBufferPointer(start: p, count: n))
}

func jtHostBell(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.onBell()
}

func jtHostSetTitle(_ ctx: UnsafeMutableRawPointer?, _ p: UnsafePointer<UInt8>?, _ n: Int) {
    guard let ctx else { return }
    let bytes: [UInt8]
    if let p, n > 0 { bytes = Array(UnsafeBufferPointer(start: p, count: n)) }
    else { bytes = [] }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleTitle(bytes)
}

func jtHostOsc52Write(
    _ ctx: UnsafeMutableRawPointer?,
    _ kind: UInt8,
    _ p: UnsafePointer<UInt8>?,
    _ n: Int
) {
    guard let ctx else { return }
    let bytes: [UInt8]
    if let p, n > 0 { bytes = Array(UnsafeBufferPointer(start: p, count: n)) }
    else { bytes = [] }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleOsc52Write(kind, bytes)
}

func jtHostOsc52Read(_ ctx: UnsafeMutableRawPointer?, _ kind: UInt8) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleOsc52Read(kind)
}

func jtHostPaletteChanged(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handlePaletteChanged()
}

func jtHostOsc7(_ ctx: UnsafeMutableRawPointer?, _ p: UnsafePointer<UInt8>?, _ n: Int) {
    guard let ctx else { return }
    let bytes: [UInt8]
    if let p, n > 0 { bytes = Array(UnsafeBufferPointer(start: p, count: n)) }
    else { bytes = [] }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleOsc7(bytes)
}

func jtHostOsc133(_ ctx: UnsafeMutableRawPointer?, _ action: UInt8, _ p: UnsafePointer<UInt8>?, _ n: Int) {
    guard let ctx else { return }
    let bytes: [UInt8]
    if let p, n > 0 { bytes = Array(UnsafeBufferPointer(start: p, count: n)) }
    else { bytes = [] }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleOsc133(action, bytes)
}

func jtHostSizeReport(_ ctx: UnsafeMutableRawPointer?, _ kind: Int32) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleSizeReport(kind)
}

func jtHostHistoryCleared(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleHistoryCleared()
}

func jtHostNotify(
    _ ctx: UnsafeMutableRawPointer?,
    _ title: UnsafePointer<UInt8>?,
    _ nt: Int,
    _ body: UnsafePointer<UInt8>?,
    _ nb: Int
) {
    guard let ctx else { return }
    let t: [UInt8]
    if let title, nt > 0 { t = Array(UnsafeBufferPointer(start: title, count: nt)) }
    else { t = [] }
    let b: [UInt8]
    if let body, nb > 0 { b = Array(UnsafeBufferPointer(start: body, count: nb)) }
    else { b = [] }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleNotify(t, b)
}

func jtHostProgress(_ ctx: UnsafeMutableRawPointer?, _ state: UInt8, _ percent: UInt8) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.handleProgress(state, percent)
}

func jtHostUnlockForIO(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.unlockForIO?()
}

func jtHostRelock(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<ParserGlue>.fromOpaque(ctx).takeUnretainedValue().parser.relock?()
}

func jtHostPngDecode(
    _ ctx: UnsafeMutableRawPointer?,
    _ png: UnsafePointer<UInt8>?,
    _ n: Int,
    _ outRGBA: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outW: UnsafeMutablePointer<UInt32>?,
    _ outH: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    _ = ctx
    guard let png, n > 0, let outRGBA, let outW, let outH else { return -1 }
    guard let decoded = pngDecodeRGBA(png, count: n) else { return -1 }
    outRGBA.pointee = decoded.rgba
    outW.pointee = decoded.w
    outH.pointee = decoded.h
    return 0
}
