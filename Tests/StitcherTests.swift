import Foundation
import CoreGraphics

@main struct StitcherTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        count += 1; print("PASS: \(name)")
    }
    static func bytes(_ image: CGImage) -> [UInt8] {
        Array((image.dataProvider!.data! as Data))
    }
    static func frame(width: Int = 128, height: Int = 240, offset: Int = 0, seed: Int = 0) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let yy = y + offset, p = (y * width + x) * 4
            data[p] = UInt8(((yy * 17 + x * 7 + yy * x * 3 + seed * 31) ^ (yy >> 2)) % 256)
            data[p+1] = UInt8(((yy * 31 + x * 11 + seed * 97) ^ (yy >> 1)) % 256)
            data[p+2] = UInt8((yy * yy + x * 23 + seed * 157) % 256)
        }}
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func rejects(_ operation: () throws -> StitchResult, _ name: String) {
        do { _ = try operation(); fatalError("FAIL: \(name) accepted") }
        catch { count += 1; print("PASS: \(name) (\(error.localizedDescription))") }
    }

    static func repetitiveFrame(offset: Int) -> CGImage {
        let width = 128, height = 240
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let value: UInt8 = ((y + offset) % 24 < 12) ? 20 : 240
            let p = (y * width + x) * 4
            data[p] = value; data[p+1] = value; data[p+2] = value
        }}
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func main() throws {
        let first = frame(), next = frame(offset: 120)
        let merged = try ImageStitcher.append(previous: first, next: next)
        check(merged.addedRows == 120 && merged.image.height == 360, "correct overlap")
        check(bytes(merged.image) == bytes(frame(height: 360)), "pixel-exact orientation and complete rows")
        let third = try ImageStitcher.append(previous: merged.image, next: frame(offset: 240))
        check(third.addedRows == 120 && bytes(third.image) == bytes(frame(height: 480)), "append to tall composite")
        let duplicate = try ImageStitcher.append(previous: third.image, next: frame(offset: 240))
        check(duplicate.addedRows == 0 && duplicate.image.height == third.image.height, "duplicate frame")
        let shortScroll = try ImageStitcher.append(previous: first, next: frame(offset: 1))
        check(shortScroll.addedRows == 1, "one-pixel scroll")
        let largeScroll = try ImageStitcher.append(previous: first, next: frame(offset: 210))
        check(largeScroll.addedRows == 210, "small overlap accepted")
        rejects({ try ImageStitcher.append(previous: first, next: frame(width: 64)) }, "reject width change")
        rejects({ try ImageStitcher.append(previous: first, next: frame(seed: 1)) }, "reject unrelated content")
        rejects({ try ImageStitcher.append(previous: frame(offset: 120), next: first) }, "reject upward scroll")
        rejects({ try ImageStitcher.append(previous: first, next: frame(height: 400)) }, "reject viewport height larger than composite")
        rejects({ try ImageStitcher.append(previous: first, next: frame(offset: 235)) }, "reject insufficient overlap")
        rejects({ try ImageStitcher.append(previous: frame(width: 16, height: 32769), next: frame(width: 16)) }, "reject dimension limit before pixel allocation")
        rejects({ try ImageStitcher.append(previous: repetitiveFrame(offset: 0), next: repetitiveFrame(offset: 12)) }, "reject ambiguous repetitive stripes")
        let started = Date()
        let large = try ImageStitcher.append(previous: frame(width: 1920, height: 1080), next: frame(width: 1920, height: 1080, offset: 520))
        check(large.addedRows == 520 && large.image.height == 1600, "Retina-size viewport")
        print("Large-image stitch elapsed: \(Date().timeIntervalSince(started))s")
        print("\(count) stitch tests passed")
    }
}
