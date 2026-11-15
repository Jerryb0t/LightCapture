import CoreGraphics
@main struct ScreenshotDeliveryTests {
 static func main() throws {
  let c=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  let image=c.makeImage()!;var copies=0,saves=0
  try ScreenshotDelivery.finalize(image,copyOnly:false,copy:{_ in copies += 1;return true},save:{_ in saves += 1})
  precondition(copies == 1 && saves == 1)
  try ScreenshotDelivery.finalize(image,copyOnly:true,copy:{_ in copies += 1;return true},save:{_ in saves += 1})
  precondition(copies == 2 && saves == 1)
  do {try ScreenshotDelivery.finalize(image,copyOnly:false,copy:{_ in false},save:{_ in saves += 1});fatalError("expected failure")}
  catch ScreenshotDelivery.Failure.clipboard {precondition(saves == 1)}
  print("PASS direct copy+save, copy-only, visible clipboard error without save (injected effects)")
 }
}
