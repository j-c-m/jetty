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
