import Foundation
import CoreGraphics

@main struct EditorTests {
    static var count = 0
    static func check(_ yes: @autoclosure () -> Bool, _ name: String) { guard yes() else { fatalError("FAIL \(name)") }; count += 1; print("PASS \(name)") }
    static func pixels(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }
    static func main() {
        let w = 200, h = 160
        var data = [UInt8](repeating: 255,count:w*h*4)
        // Distinct top-left point detects accidental flips even without annotations.
        data[0] = 0; data[1] = 20; data[2] = 100
        let original = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),provider:CGDataProvider(data:Data(data) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let untouched = CaptureEditorRenderer.render(image:original,annotations:[])!
        check(untouched === original,"unannotated capture reuses original buffer")
        check(pixels(untouched)==data,"unchanged original pixel orientation")
        let red = CGColor(red:1,green:0,blue:0,alpha:1)
        let rect = CaptureAnnotation(kind:.rectangle,points:[CGPoint(x:20,y:20),CGPoint(x:80,y:60)],color:red,width:4)
        let rendered = CaptureEditorRenderer.render(image:original,annotations:[rect])!
        let output = pixels(rendered), top = (20*w+40)*4, bottomMirror = (140*w+40)*4
        check(rendered.width == w && rendered.height == h,"native pixel resolution")
        check(output[top] > 240 && output[top+1] < 70,"annotation top-left coordinates")
        check(output[bottomMirror+1] > 240,"annotation not vertically mirrored")
        check(pixels(original)==data,"original remains unmodified")
        let marks = [
            CaptureAnnotation(kind:.pen,points:[CGPoint(x:10,y:90),CGPoint(x:90,y:110)],color:red,width:4),
            CaptureAnnotation(kind:.arrow,points:[CGPoint(x:100,y:20),CGPoint(x:180,y:70)],color:red,width:4),
            CaptureAnnotation(kind:.text,points:[CGPoint(x:20,y:120)],text:"测试 Test",color:red,fontSize:20)
        ]
        let all = CaptureEditorRenderer.render(image:original,annotations:marks)!
        check(pixels(all) != data,"pen arrow and text render")
        print("\(count) editor rendering tests passed")
    }
}
