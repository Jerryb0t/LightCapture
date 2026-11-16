import AppKit
import ImageIO

/// Drives actual app-owned offscreen AppKit fixtures and the production session
/// and PNG export. Never orders a window on-screen, reads a display, or registers
/// global shortcuts; Enter/Esc actions are injected at the session boundary.
@main struct LongCaptureSessionTests {
    static let width=960, viewport=480, documentHeight=2500
    @MainActor static func page() -> CGImage {
        let context=CGContext(data:nil,width:width,height:documentHeight,bitsPerComponent:8,
            bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:documentHeight))
        let graphics=NSGraphicsContext(cgContext:context,flipped:false)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
        for row in 0..<72 {
            let y=documentHeight-row*33-28
            let subtitle="Section \(row + 1)   Capture checkpoint for the local scroll fixture \(row * row + 73)"
            (subtitle as NSString).draw(at:CGPoint(x:72+row%4*7,y:y),withAttributes:[
                .font:NSFont.systemFont(ofSize:row%5==0 ? 23:16,weight:row%5==0 ? .bold:.regular),
                .foregroundColor:row%5==0 ? NSColor.systemBlue:NSColor.black])
            if row%3==1 {
                context.setFillColor(NSColor(red:Double(row%9)/10,green:0.36,blue:0.70,alpha:1).cgColor)
                context.fill(CGRect(x:45,y:y+4,width:10,height:12))
                context.fill(CGRect(x:733,y:y+8,width:20+row*2,height:4))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    static func crop(_ page:CGImage,_ offset:Int,_ height:Int=viewport)->CGImage {
        page.cropping(to:CGRect(x:0,y:offset,width:width,height:height))!
    }
    static func bytes(_ image:CGImage)->Data {
        let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,
            bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return Data(bytes:context.data!,count:image.width*image.height*4)
    }
    static func chromePage(_ content:CGImage,offset:Int,movingHeight:Int)->CGImage {
        let chromeTop=crop(content,1730,84)
        let chromeBottom=crop(content,1200,52)
        let moving=crop(content,offset,movingHeight)
        let height=chromeTop.height+moving.height+chromeBottom.height
        let data=bytes(chromeTop)+bytes(moving)+bytes(chromeBottom)
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    @MainActor static func wait(_ label:String,_ accepted:()->Bool) async throws {
        for _ in 0..<100 {
            if accepted(){return}
            try await Task.sleep(nanoseconds:25_000_000)
        }
        fatalError("Timed out: "+label)
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let page=page()
        let scroll=NSScrollView(frame:CGRect(x:0,y:0,width:width,height:viewport))
        scroll.documentView=NSView(frame:CGRect(x:0,y:0,width:width,height:documentHeight))
        let w=SelectionWindow(contentRect:CGRect(x:0,y:0,width:width+160,height:viewport+160),
            styleMask:.borderless,backing:.buffered,defer:true)
        w.isReleasedWhenClosed=false;defer{w.close()}
        let v=SelectionView(frame:CGRect(x:0,y:0,width:width+160,height:viewport+160))
        w.contentView=v;v.setMode(.longScreenshot)
        func event(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,
                windowNumber:w.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let session=LongCaptureSession()
        let startedAt=ProcessInfo.processInfo.systemUptime
        var received:Result<CGImage,Error>?,partial:CGImage?, starts=0
        var requestedOffsets:[Int]=[]
        func move(_ offset:Int){scroll.contentView.scroll(to:CGPoint(x:0,y:offset))}
        let prepare:LongCaptureSession.Prepare = {
            try await Task.sleep(nanoseconds:90_000_000)
            return {
                let offset=Int(scroll.contentView.bounds.minY)
                requestedOffsets.append(offset)
                return crop(page,offset)
            }
        }
        v.finished={ rect,_,_ in
            precondition(rect==CGRect(x:40,y:55,width:width,height:viewport))
            starts += 1
            session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
        }
        v.mouseDown(with:event(.leftMouseDown,CGPoint(x:40,y:55)))
        v.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:40+width,y:55+viewport)))
        v.mouseUp(with:event(.leftMouseUp,CGPoint(x:40+width,y:55+viewport)))
        precondition(starts==1 && session.active && !w.isVisible)
        // Move immediately after release, even before ScreenCaptureKit preparation
        // could finish; the original first row must still be in the saved PNG.
        for offset in [100,225,380,535,695] {
            move(offset)
            try await wait("assemble \(offset)"){session.composite?.height == viewport+offset}
        }
        move(310)
        try await wait("reverse scroll sampled"){requestedOffsets.contains(310)}
        precondition(session.composite?.height == viewport+695)
        move(795);session.finish()
        try await wait("Enter delivers full PNG input"){received != nil}
        let image=try received!.get()
        precondition(image.height==viewport+795 && image.width==width)
        precondition(bytes(image)==bytes(crop(page,0,viewport+795)))
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("lightcapture-synthetic-\(UUID())")
        defer{try? FileManager.default.removeItem(at:base)}
        let written=try CaptureStorage.writePNG(image,recovery:base.appendingPathComponent("recovery"))
        let exported:URL
        if ProcessInfo.processInfo.environment["LIGHTCAPTURE_TEST_COORDINATED_EXPORT"] == "1" {
            exported=try CaptureStorage.export(written,root:base.appendingPathComponent("output"),category:"长截图")
        }else{
            // OS file coordination needs an XPC service unavailable under some
            // developer sandboxes. The default still writes and decodes the actual PNG.
            exported=written
        }
        let decoded=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(exported as CFURL,nil)!,0,nil)!
        precondition(decoded.width==width && decoded.height==viewport+795)
        precondition(bytes(decoded)==bytes(crop(page,0,viewport+795)))
        print("PASS selection release + immediate scroll + reverse scroll + Enter wrote pixel-verified \(decoded.width)×\(decoded.height) PNG in \(String(format:"%.2f",ProcessInfo.processInfo.systemUptime-startedAt)) s; coordinated export: \(exported != written)")

        received=nil;partial=nil;move(0)
        let snapped=SelectionView(frame:v.frame)
        w.contentView=snapped
        let windowRect=CGRect(x:70,y:60,width:width,height:viewport)
        let other=CGRect(x:80,y:viewport+95,width:160,height:35)
        snapped.candidates=[(other,nil),(windowRect,nil)]
        let point=CGPoint(x:135,y:155)
        w.sendEvent(event(.mouseMoved,point))
        precondition(snapped.selectedMode == .screenshot && snapped.hovered?.0==windowRect)
        snapped.setMode(.longScreenshot)
        precondition(snapped.hovered?.0==windowRect)
        var snappedStarts=0
        let movingHeight=viewport-84-52
        let firstChrome=chromePage(page,offset:0,movingHeight:movingHeight)
        let nextChrome=chromePage(page,offset:140,movingHeight:movingHeight)
        do{
            _=try ImageStitcher.append(previous:firstChrome,next:nextChrome)
            fatalError("old unrestricted overlap incorrectly accepted the fixed chrome fixture")
        }catch is StitchError {}
        snapped.finished={rect,_,_ in
            precondition(snapped.pendingWasSnap && rect==windowRect)
            snappedStarts += 1
            session.start(seed:firstChrome,allowFixedWindowBands:true,prepare:{
                return {chromePage(page,offset:Int(scroll.contentView.bounds.minY),movingHeight:movingHeight)}
            }){received=$0;partial=$1}
        }
        snapped.mouseDown(with:event(.leftMouseDown,point))
        snapped.mouseUp(with:event(.leftMouseUp,CGPoint(x:point.x+1,y:point.y+1)))
        precondition(snappedStarts==1 && session.active)
        for offset in [140,260,390,510]{
            move(offset)
            try await wait("snap assemble \(offset)"){session.composite?.height==viewport+offset}
        }
        move(270)
        try await Task.sleep(nanoseconds:230_000_000)
        precondition(session.composite?.height==viewport+510)
        move(645)
        let localReturn=LongSessionKeyboard.localCommand(keyCode:36,modifiers:[])
        precondition(localReturn==true && LongSessionKeyboard.localCommand(keyCode:36,modifiers:.command)==nil)
        precondition(LongSessionKeyboard.localCommand(keyCode:53,modifiers:[])==false)
        precondition(LongSessionKeyboard.localCommand(keyCode:76,modifiers:[])==true)
        if localReturn==true{session.finish()}
        try await wait("snap enter"){received != nil}
        let snappedImage=try received!.get()
        let expectedSnap=chromePage(page,offset:0,movingHeight:movingHeight+645)
        precondition(snappedImage.width==width && snappedImage.height==viewport+645)
        precondition(bytes(snappedImage)==bytes(expectedSnap))
        let snappedTemp=try CaptureStorage.writePNG(snappedImage,recovery:base.appendingPathComponent("recovery"))
        let snappedPath=ProcessInfo.processInfo.environment["LIGHTCAPTURE_TEST_COORDINATED_EXPORT"] == "1"
            ? try CaptureStorage.export(snappedTemp,root:base.appendingPathComponent("output"),category:"长截图")
            : snappedTemp
        let decodedSnap=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(snappedPath as CFURL,nil)!,0,nil)!
        precondition(bytes(decodedSnap)==bytes(expectedSnap))
        print("PASS Ctrl+A-style hover + mode switch + one click starts same window; fixed top and bottom each appear once in pixel-verified \(decodedSnap.width)×\(decodedSnap.height) PNG")

        // Test the AppKit reopen route while the scoped long controller is active.
        let delegate=AppDelegate()
        delegate.buildUI()
        delegate.longSession.start(seed:crop(page,0),prepare:prepare){_,_ in fatalError("release should not save")}
        precondition(!delegate.window.isVisible)
        precondition(delegate.applicationShouldHandleReopen(NSApplication.shared,hasVisibleWindows:false))
        precondition(!delegate.window.isVisible && delegate.longSession.active)
        delegate.longSession.cancel()
        print("PASS a reopen request during long capture does not open Settings; cancel saves nothing")

        received=nil;partial=nil;move(160)
        session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
        session.finish() // Before the source exists, former code silently ignored Return.
        try await wait("queued Enter"){received != nil}
        let early=try received!.get()
        precondition(early.height==viewport+160)
        print("PASS early Enter waits for the first live frame and finishes")

        received=nil;partial=nil;move(0)
        session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
        session.finish()
        try await wait("unchanged viewport completes"){received != nil}
        guard case .failure(let unmoved)?=received,unmoved is LongCaptureSession.Failure,partial==nil else {
            fatalError("unchanged viewport must not look like a successful long screenshot")
        }

        received=nil;partial=nil
        session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
        session.cancel()
        try await Task.sleep(nanoseconds:240_000_000)
        precondition(received==nil && !session.active && session.composite==nil)
        print("PASS no-growth gives an explicit failure; Escape clears pending work without output")

        received=nil;partial=nil;move(0)
        session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
        // Fixed pace: over one viewport before the first old 800ms polling tick.
        // The new session must bridge several partially overlapping live frames.
        for offset in [135,270,405,540,675] {
            move(offset)
            try await Task.sleep(nanoseconds:155_000_000)
        }
        session.finish()
        try await wait("fixed pace continuous scroll"){received != nil}
        let rapid=try received!.get()
        precondition(rapid.height==viewport+675 && bytes(rapid)==bytes(crop(page,0,viewport+675)))
        print("PASS fixed cadence crossing a full viewport in under 0.8 s retains every row")

        received=nil;partial=nil;move(160)
        let segment=NSSegmentedControl(labels:["Screenshot","Record","Scroll"],trackingMode:.selectOne,target:nil,action:nil)
        var preflights=0,editorStarts=0
        let editor=CaptureEditor(image:crop(page,0),onSave:{_ in fatalError("not a regular screenshot")},
            onCancel:{fatalError("editor mode transition is not cancellation")},onLong:{
                editorStarts += 1
                session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
                session.finish()
            },beforeLong:{
                preflights += 1
                return preflights == 1 ? "Shortcut unavailable" : nil
            })
        segment.selectedSegment=2;editor.changeMode(segment)
        precondition(preflights==1 && editorStarts==0 && segment.selectedSegment==0)
        segment.selectedSegment=2;editor.changeMode(segment)
        try await wait("editor long capture callback"){received != nil}
        let editorImage=try received!.get()
        precondition(preflights==2 && editorStarts==1 && editorImage.height==viewport+160)
        print("PASS editor shortcut conflict keeps editor open; retry enters the same session once")

        received=nil;partial=nil;move(0)
        session.start(seed:crop(page,0),prepare:prepare){received=$0;partial=$1}
        move(155)
        try await wait("valid first extension"){session.composite?.height==viewport+155}
        move(1200);session.finish()  // Last viewport does not overlap: no invented pixels.
        try await wait("non-overlap at Enter"){received != nil}
        guard case .failure?=received,let partial else{fatalError("expected verified partial on gap")}
        precondition(partial.height==viewport+155 && bytes(partial)==bytes(crop(page,0,viewport+155)))
        print("PASS non-overlapping last sample never claims success or fabricates a seam")
    }
}
