import Foundation
import CoreGraphics

/// Deterministic browser-like layout: white margins, multi-word glyph rows, headings
/// and colored line markers. Each document row differs; no full-page periodic tile.
@main struct LongScrollSequenceTests {
    static let width = 640, viewport = 360
    static var checks = 0
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name); checks += 1; print("PASS \(name)")
    }
    static func hash(_ value: UInt64) -> UInt64 {
        var result = value &+ 0x9e3779b97f4a7c15
        result = (result ^ (result >> 30)) &* 0xbf58476d1ce4e5b9
        result = (result ^ (result >> 27)) &* 0x94d049bb133111eb
        return result ^ (result >> 31)
    }
    static func frame(offset: Int, height: Int = viewport, seed: Int = 0) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let documentY = y + offset, line = documentY / 20, row = documentY % 20
            guard row >= 3 && row < 14 else { continue }
            for x in 36..<(width - 42) {
                let column = (x - 36) / 7, glyphX = (x - 36) % 7
                let word = hash(UInt64(line * 1009 + column * 17 + seed * 104729))
                let lineLength = 45 + Int(hash(UInt64(line + seed * 311)) % 30)
                guard column < lineLength, column % 9 != 8, glyphX < 5 else { continue }
                let bit = (row - 3) * 5 + glyphX
                if (word >> bit) & 1 == 1 {
                    let index = (y * width + x) * 4
                    if line % 7 == 0 { bytes[index] = 28; bytes[index+1] = 92; bytes[index+2] = 170 }
                    else { bytes[index] = 35; bytes[index+1] = 35; bytes[index+2] = 38 }
                }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
    static func main() throws {
        let firstOffset = 200
        var composite = frame(offset: firstOffset)
        var lastSignature: Data? = try LongFrameProcessor.signature(composite)
        var frontier = firstOffset
        for offset in [320, 440, 370, 260, 200, 200, 320, 440, 560, 500, 560, 680] {
            let before = composite
            let result = try LongFrameProcessor.process(previous: composite, next: frame(offset: offset), lastSignature: lastSignature)
            let expectedAdded = max(0, offset - frontier)
            check(result.stitch.addedRows == expectedAdded, "offset \(offset) adds only \(expectedAdded) unseen rows")
            if expectedAdded == 0 { check(result.stitch.image === before, "offset \(offset) reuses original composite allocation") }
            frontier = max(frontier, offset)
            composite = result.stitch.image; lastSignature = result.signature
            check(composite.height == viewport + frontier - firstOffset, "offset \(offset) preserves unique assembled height")
            check(bytes(composite) == bytes(frame(offset: firstOffset, height: composite.height)), "offset \(offset) keeps exact row order and pixels")
        }
        let before = composite
        let idle = try LongFrameProcessor.process(previous: composite, next: frame(offset: 680), lastSignature: lastSignature)
        check(idle.stitch.image === before && idle.stitch.addedRows == 0, "unchanged viewport uses bounded signature fast path")
        check(idle.signature.count == 96*96*4, "signature remains 36 KiB")
        do {
            _ = try LongFrameProcessor.process(previous: composite, next: frame(offset: 100), lastSignature: lastSignature)
            preconditionFailure("scroll above original start must not append")
        } catch is StitchError { check(true, "upward extension before initial viewport conservatively rejected") }
        do {
            _ = try LongFrameProcessor.process(previous: composite, next: frame(offset: 800, seed: 913), lastSignature: lastSignature)
            preconditionFailure("unrelated text document must not append")
        } catch is StitchError { check(true, "unrelated browser-like document rejected") }
        check(bytes(composite) == bytes(before), "rejected frames cannot alter prior image")
        // Confirm a large return into a much older part, rather than only the last viewport.
        let longPage = frame(offset: 0, height: 7000)
        let start = Date()
        let revisit = try LongFrameProcessor.process(previous: longPage, next: frame(offset: 40), lastSignature: nil)
        check(revisit.stitch.image === longPage && revisit.stitch.addedRows == 0, "old viewport anywhere in tall composite ignored")
        print("Tall-composite revisit seconds: \(Date().timeIntervalSince(start))")
        print("\(checks) long-scroll sequence checks passed")
    }
}
