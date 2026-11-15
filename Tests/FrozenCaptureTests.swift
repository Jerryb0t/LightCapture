import AppKit
@main struct FrozenCaptureTests {
 @MainActor static func main(){
  func check(_ ok:Bool,_ label:String){if !ok{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
  do{
   // Asymmetric row/column markers; rows are CGImage top-to-bottom pixels.
   let w=8,h=6;var bytes=[UInt8](repeating:0,count:w*h*4)
   for y in 0..<h {for x in 0..<w {let p=(y*w+x)*4;bytes[p]=UInt8(x*20);bytes[p+1]=UInt8(y*30);bytes[p+2]=UInt8(x+y);bytes[p+3]=255}}
   let provider=CGDataProvider(data:Data(bytes) as CFData)!
   let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
   let frame=FrozenFrame(image:image,logicalSize:CGSize(width:4,height:3))
   let result=try frame.crop(CGRect(x:1,y:1,width:2,height:1))
   check(result.width==4 && result.height==2,"Retina crop dimensions")
   let data=result.dataProvider!.data! as Data
   check(data.count==32,"compact crop must not retain full-screen backing storage")
   for y in 0..<2 {for x in 0..<4 {let p=y*result.bytesPerRow+x*4;check(data[p]==UInt8((x+2)*20) && data[p+1]==UInt8((y+2)*30),"top-left row/column orientation")}}
   check(try frame.crop(CGRect(x:0,y:0,width:4,height:3)) === image,"full screen avoids duplicate allocation")
   let fractional=try frame.crop(CGRect(x:0.5,y:0.5,width:1,height:1));check(fractional.width==2 && fractional.height==2,"half-point Retina precision")
   check(FrozenBudget.displays(pixelCounts:[8_000_000,8_000_000],cursorIndex:1,limit:24_000_000)==[0,1],"multiple screens within budget")
   check(FrozenBudget.displays(pixelCounts:[16_000_000,16_000_000],cursorIndex:1,limit:24_000_000)==[1],"cursor-first fallback")
   check(FrozenBudget.displays(pixelCounts:[33_000_000],cursorIndex:0,limit:24_000_000).isEmpty,"over-limit rejects safely")
   let screen=CGRect(x:-900,y:100,width:900,height:700)
   func snap(_ layer:Int,_ alpha:Double,_ rect:CGRect,_ owner:String="App",_ own:Bool=false)->Bool{WindowSnapPolicy.permits(layer:layer,alpha:alpha,frame:rect,displayBounds:screen,owner:owner,isOwn:own)}
   let popup=CGRect(x:-300,y:500,width:250,height:250),normal=CGRect(x:-850,y:150,width:800,height:600)
   check(snap(25,1,popup) && snap(0,1,normal),"popup and ordinary windows allowed with negative screen origin")
   check(!snap(24,1,CGRect(x:-900,y:770,width:900,height:30)) && !snap(0,0,normal) && !snap(0,1,normal,"Dock") && !snap(8,1,popup,"App",true),"bar, invisible, Dock and own overlay rejected")
   check(!snap(8,1,CGRect(x:-950,y:0,width:1500,height:1000)),"oversized popup placeholder rejected")
   NSApplication.shared.setActivationPolicy(.prohibited)
   let view=SelectionView(frame:CGRect(x:0,y:0,width:900,height:700));view.frozenImage=image
   view.cancelSelection();check(view.frozenImage==nil,"cancel releases view snapshot synchronously")
   let app=try String(contentsOfFile:"Sources/App.swift",encoding:.utf8)
   let route=app.components(separatedBy:"func takeScreenshot")[1].components(separatedBy:"func finalizeScreenshot")[0]
   check(!route.contains("CaptureEngine.screenshot") && !route.contains("Task.sleep") && route.contains("target.frozenImage"),"confirmation never re-grabs live screen")
   print("PASS frozen Retina/asymmetric crop, compact ownership, full-frame reuse, bounds budget, popup eligibility, cancel release and no-live-regrab route; no screen read")
  }catch{fputs("FAIL: synthetic freeze test\n",stderr);exit(1)}
 }
}
