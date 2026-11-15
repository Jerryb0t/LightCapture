import Foundation
import CoreGraphics

struct StitchResult {
    let image: CGImage
    let addedRows: Int
}

enum StitchError: LocalizedError {
    case incompatibleSize, imageTooLarge, cannotDecode, noOverlap, ambiguousOverlap
    var errorDescription: String? {
        switch self {
        case .incompatibleSize: return L("截图宽度不一致，或图片太小。请保持同一选区和缩放比例。")
        case .imageTooLarge: return L("长截图已达到安全大小上限，请先保存，再开始新的长截图。")
        case .cannotDecode: return L("无法读取截图像素。")
        case .noOverlap: return L("没有找到可靠的重叠区域。请向下滚动少一点，并避开固定页头和动态内容。")
        case .ambiguousOverlap: return L("画面过于重复或空白，无法可靠拼接。请换一个包含明显文字或图案的位置。")
        }
    }
}

/// Conservative, offline vertical stitching. Never guesses on ambiguous/low-information images.
/// Inputs must represent the same fixed viewport width and scale. Sticky headers, animations,
/// horizontal movement, upward scrolling and zoom changes are deliberately not repaired.
enum ImageStitcher {
    static let maximumPixels = 24_000_000
    static let maximumDimension = 32_768

    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        init(_ image: CGImage) throws {
            let width = image.width, height = image.height
            self.width = width; self.height = height
            guard width > 0, height > 0,
                  width <= ImageStitcher.maximumDimension, height <= ImageStitcher.maximumDimension,
                  width <= ImageStitcher.maximumPixels / height else { throw StitchError.imageTooLarge }
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let ok = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.interpolationQuality = .none
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { throw StitchError.cannotDecode }
            rgba = data
        }
    }

    static func append(previous: CGImage, next: CGImage) throws -> StitchResult {
        guard previous.width == next.width, next.width >= 16, next.height >= 32,
              previous.height >= next.height else { throw StitchError.incompatibleSize }
        let a = try Pixels(previous), b = try Pixels(next)
        let viewport = b.height
        // Compare against the last viewport, not the whole tall composite.
        if a.rgba.suffix(b.rgba.count).elementsEqual(b.rgba) {
            return StitchResult(image: previous, addedRows: 0)
        }
        let minimumOverlap = max(24, viewport / 10)
        guard minimumOverlap < viewport else { throw StitchError.noOverlap }
        var scored: [(overlap: Int, error: Double)] = []
        scored.reserveCapacity(viewport)
        for overlap in minimumOverlap..<viewport {
            let error = difference(a, a.height - overlap, b, 0, overlap, rows: 48, columns: 40)
            scored.append((overlap, error))
        }
        scored.sort { $0.error < $1.error }
        guard let best = scored.first, best.error <= 3.0 else { throw StitchError.noOverlap }
        // Neighboring alignment can score similarly around antialiasing, but a second
        // equally plausible alignment a few pixels away means repeated content: refuse.
        if let rival = scored.first(where: { abs($0.overlap - best.overlap) > 2 }),
           rival.error <= best.error + 0.8 { throw StitchError.ambiguousOverlap }
        guard texture(b, height: best.overlap) >= 5.0 else { throw StitchError.ambiguousOverlap }
        guard difference(a, a.height - best.overlap, b, 0, best.overlap, rows: 180, columns: 96) <= 4.0 else {
            throw StitchError.noOverlap
        }
        let added = viewport - best.overlap
        let height = a.height + added
        guard height <= maximumDimension, a.width <= maximumPixels / height else { throw StitchError.imageTooLarge }
        // Concatenate normalized row bytes directly, avoiding coordinate-system flips.
        var joined = a.rgba
        joined.append(contentsOf: b.rgba[(best.overlap * b.width * 4)...])
        guard let provider = CGDataProvider(data: Data(joined) as CFData),
              let image = CGImage(width: a.width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: a.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw StitchError.cannotDecode
        }
        return StitchResult(image: image, addedRows: added)
    }

    private static func difference(_ a: Pixels, _ ay: Int, _ b: Pixels, _ by: Int,
                                   _ height: Int, rows: Int, columns: Int) -> Double {
        let ny = min(rows, height), nx = min(columns, a.width)
        var sum = 0
        for iy in 0..<ny {
            let y = iy * (height - 1) / max(1, ny - 1)
            for ix in 0..<nx {
                let x = ix * (a.width - 1) / max(1, nx - 1)
                let p = ((ay + y) * a.width + x) * 4, q = ((by + y) * b.width + x) * 4
                sum += abs(Int(a.rgba[p]) - Int(b.rgba[q]))
                sum += abs(Int(a.rgba[p + 1]) - Int(b.rgba[q + 1]))
                sum += abs(Int(a.rgba[p + 2]) - Int(b.rgba[q + 2]))
            }
        }
        return Double(sum) / Double(ny * nx * 3)
    }

    private static func texture(_ image: Pixels, height: Int) -> Double {
        let ny = min(96, height), nx = min(48, image.width)
        var sum = 0.0, squares = 0.0
        for iy in 0..<ny {
            let y = iy * (height - 1) / max(1, ny - 1)
            for ix in 0..<nx {
                let x = ix * (image.width - 1) / max(1, nx - 1), p = (y * image.width + x) * 4
                let value = (Double(image.rgba[p]) + Double(image.rgba[p + 1]) + Double(image.rgba[p + 2])) / 3
                sum += value; squares += value * value
            }
        }
        let n = Double(ny * nx)
        return sqrt(max(0, squares / n - pow(sum / n, 2)))
    }
}
