import Foundation
import CoreGraphics
@main struct LongFrameProcessorTests {
 static func image(_ gray:CGFloat)->CGImage {
  let c=CGContext(data:nil,width:256,height:240,bitsPerComponent:8,bytesPerRow:1024,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.setFillColor(CGColor(gray:gray,alpha:1));c.fill(CGRect(x:0,y:0,width:256,height:240));return c.makeImage()!
 }
 static func main() throws {
  let original=image(0.3),signature=try LongFrameProcessor.signature(original)
  for _ in 0..<20 {
   let result=try LongFrameProcessor.process(previous:original,next:original,lastSignature:signature)
   precondition(result.stitch.addedRows == 0 && result.stitch.image === original)
   precondition(result.signature.count == 36864)
  }
  print("PASS repeated unchanged viewport keeps same composite without growth; signature bounded 36 KiB")
  let unrelated=image(0.9)
  let different=try LongFrameProcessor.signature(unrelated)
  precondition(different != signature)
  do { _=try LongFrameProcessor.process(previous:original,next:unrelated,lastSignature:signature);fatalError("expected rejection") }
  catch is StitchError {print("PASS unrelated viewport rejected without replacing last successful signature/composite")}
 }
}
