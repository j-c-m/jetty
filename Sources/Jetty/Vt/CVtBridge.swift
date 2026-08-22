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
