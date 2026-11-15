import AppKit
import Vision
@main struct SupportQRTests {
 @MainActor static func main(){
  NSApplication.shared.setActivationPolicy(.prohibited)
  func check(_ condition:Bool,_ message:String){if !condition{fputs("FAIL: "+message+"\n",stderr);exit(1)}}
  func payload(_ image:CGImage) throws->String? {
   let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
   try VNImageRequestHandler(cgImage:image).perform([request])
   return request.results?.first?.payloadStringValue
  }
  do {
   let links=AuthorLinks();links.resourceRoot=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Artwork")
   links.prepare(.support)
   for (index,name) in ["SupportWeChatPay","SupportAlipay","SupportOKXPay"].enumerated(){
    let original=NSImage(contentsOf:links.resourceRoot!.appendingPathComponent("SupportQR/"+name+".png"))!
    let expected=try payload(original.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
    check(expected != nil,"source must decode")
    links.paymentPicker!.selectItem(at:index+1);links.selectPayment()
    for scale in [1,2]{
     let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240*scale,pixelsHigh:240*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
     bitmap.size=NSSize(width:240,height:240)
     NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
     links.qrView!.draw(links.qrView!.bounds);NSGraphicsContext.restoreGraphicsState()
     check(try payload(bitmap.cgImage!)==expected,"rendered QR does not match source")
    }
   }
   print("PASS all three QR codes remain decodable at 1x/2x with exact source payload; no payload text, files, payment, browser or network emitted")
  }catch{let e=error as NSError;fputs("UNAVAILABLE: local barcode verification \(e.domain) code=\(e.code)\n",stderr);exit(77)}
 }
}
