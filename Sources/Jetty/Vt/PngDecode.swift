import CVt
import CoreGraphics
import Foundation
import ImageIO

func pngDecodeRGBA(_ png: UnsafePointer<UInt8>, count: Int) -> (rgba: UnsafeMutablePointer<UInt8>, w: UInt32, h: UInt32)? {
    let data = Data(bytes: png, count: count)
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, [
              kCGImageSourceShouldCache: false
          ] as CFDictionary)
    else { return nil }
    let w = img.width
    let h = img.height
    if w <= 0 || h <= 0 || w > Int(JT_IMG_MAX_DIM) || h > Int(JT_IMG_MAX_DIM) { return nil }
    let bytes = w * h * 4
    if bytes > Int(JT_IMG_MAX_BYTES) { return nil }
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard let buf = malloc(bytes) else { return nil }
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let ctx = CGContext(
        data: buf,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: cs,
        bitmapInfo: info
    ) else {
        free(buf)
        return nil
    }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf.assumingMemoryBound(to: UInt8.self), UInt32(w), UInt32(h))
}
