import Foundation
import CoreGraphics

struct LongFrameResult {
    let stitch: StitchResult
    let signature: Data
}
enum LongFrameProcessor {
    // A bounded 96x96 thumbnail avoids decoding the entire growing composite
    // when the visible viewport has not changed. Tiny changes can be ignored;
    // this is a sampling heuristic, not a general image-equality assertion.
    static func signature(_ image: CGImage) throws -> Data {
        guard let context=CGContext(data:nil,width:96,height:96,bitsPerComponent:8,bytesPerRow:384,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let data=context.data else {throw StitchError.cannotDecode}
        context.interpolationQuality = .low
        context.draw(image,in:CGRect(x:0,y:0,width:96,height:96))
        return Data(bytes:data,count:96*96*4)
    }
    static func process(previous:CGImage,next:CGImage,lastSignature:Data?) throws -> LongFrameResult {
        guard previous.width == next.width, next.height <= previous.height else {throw StitchError.incompatibleSize}
        let signature=try signature(next)
        if signature == lastSignature {return LongFrameResult(stitch:StitchResult(image:previous,addedRows:0),signature:signature)}
        return LongFrameResult(stitch:try ImageStitcher.append(previous:previous,next:next),signature:signature)
    }
}
