import AppKit
import ScreenCaptureKit

struct FrozenFrame {
    let image:CGImage
    let logicalSize:CGSize
    /// Rect is display-local, top-left logical points. Copy out so the result
    /// never retains a full-screen crop provider after selection is dismissed.
    func crop(_ rect:CGRect)throws->CGImage {
        let sx=CGFloat(image.width)/logicalSize.width,sy=CGFloat(image.height)/logicalSize.height
        let requested=CGRect(x:rect.minX*sx,y:rect.minY*sy,width:rect.width*sx,height:rect.height*sy).integral
        let pixels=requested.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        if pixels == CGRect(x:0,y:0,width:image.width,height:image.height){return image}
        guard !pixels.isEmpty,let cropped=image.cropping(to:pixels),let context=CGContext(data:nil,width:cropped.width,height:cropped.height,bitsPerComponent:8,bytesPerRow:cropped.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw CaptureFailure.message(L("无法裁剪冻结画面，请重新截图。"))}
        context.interpolationQuality = .none
        context.draw(cropped,in:CGRect(x:0,y:0,width:cropped.width,height:cropped.height))
        guard let result=context.makeImage() else{throw CaptureFailure.message(L("无法裁剪冻结画面，请重新截图。"))};return result
    }
}
struct WindowSnapPolicy {
    static func permits(layer:Int,alpha:Double,frame:CGRect,displayBounds:CGRect,owner:String,isOwn:Bool)->Bool {
        guard !isOwn,alpha>0.01,layer>=0,layer<=101,frame.width>=16,frame.height>=16,!frame.isEmpty,
              owner != "Dock",owner != "Window Server",frame.intersects(displayBounds) else{return false}
        // Exclude menu/status bars themselves, not a popover extending below them.
        if layer>=20 && frame.width>=displayBounds.width*0.8 && frame.height<=80{return false}
        if layer>0 && (frame.width>displayBounds.width*1.05 || frame.height>displayBounds.height*1.05){return false}
        return true
    }
}
enum FrozenBudget {
    static func displays(pixelCounts:[Int],cursorIndex:Int,limit:Int)->[Int]{
        guard !pixelCounts.isEmpty else{return []}
        if pixelCounts.reduce(0,+)<=limit{return Array(pixelCounts.indices)}
        let active=pixelCounts.indices.contains(cursorIndex) ? cursorIndex : 0
        return pixelCounts[active]<=limit ? [active] : []
    }
}
struct PreparedCapture {
    let content:SCShareableContent
    let order:[[String:Any]]
    let frames:[CGDirectDisplayID:FrozenFrame]
    let notice:String?
    var screenshotAvailable=true
}
@MainActor enum FrozenCapture {
    static let pixelBudget=24_000_000 // ~96 MB of packed pixels; no idle cache.
    static func prepare(freeze:Bool,liveFallback:Bool=false) async throws->PreparedCapture {
        let content=try await CaptureEngine.content()
        let order=(CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]) ?? []
        guard freeze else{return PreparedCapture(content:content,order:order,frames:[:],notice:nil)}
        do {
        let cursor=NSEvent.mouseLocation
        let screens=NSScreen.screens.filter{screen in content.displays.contains{$0.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value}}
        func pixels(_ screen:NSScreen)->Int{Int(screen.frame.width*screen.backingScaleFactor)*Int(screen.frame.height*screen.backingScaleFactor)}
        let chosen=FrozenBudget.displays(pixelCounts:screens.map(pixels),cursorIndex:screens.firstIndex(where:{$0.frame.contains(cursor)}) ?? 0,limit:pixelBudget)
        let limited=chosen.count<screens.count
        let selected=chosen.map{screens[$0]}
        guard !selected.isEmpty,selected.reduce(0,{$0+pixels($1)})<=pixelBudget else{throw CaptureFailure.message(L("当前屏幕超出安全截图大小，请降低显示分辨率后重试。"))}
        var frames:[CGDirectDisplayID:FrozenFrame]=[:]
        for screen in selected {
            try Task.checkCancellation()
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            guard let display=content.displays.first(where:{$0.displayID==id}) else{continue}
            let target=CaptureTarget(display:display,rect:CGRect(origin:.zero,size:screen.frame.size))
            let filter=try CaptureEngine.filter(target:target,content:content);filter.includeMenuBar=true
            let config=CaptureEngine.configuration(target:target,recording:false)
            let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            try Task.checkCancellation()
            guard image.width*image.height+frames.values.reduce(0,{$0+$1.image.width*$1.image.height})<=pixelBudget else{throw CaptureFailure.message(L("当前屏幕超出安全截图大小，请降低显示分辨率后重试。"))}
            frames[id]=FrozenFrame(image:image,logicalSize:screen.frame.size)
        }
        return PreparedCapture(content:content,order:order,frames:frames,notice:limited ? L("为控制内存，本次仅冻结鼠标所在屏幕；其他屏幕请移入鼠标后重新截图。") : nil)
        }catch{
            if liveFallback {return PreparedCapture(content:content,order:order,frames:[:],notice:L("冻结画面不可用，本次仅支持录屏或长截图；普通截图请重新发起。"),screenshotAvailable:false)}
            throw error
        }
    }
}
