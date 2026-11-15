import AppKit
import ScreenCaptureKit

enum CaptureMode:Int {case screenshot, recording, longScreenshot}

struct CaptureTarget {
    let display: SCDisplay
    let rect: CGRect // ScreenCaptureKit display-local top-left logical points
    var window: SCWindow? = nil
    var annotationRequested = false
    var mode:CaptureMode = .screenshot
    var frozenImage:CGImage? = nil
}

@MainActor final class SelectionController {
    var failure:((Error)->Void)?
    private var windows: [NSWindow] = []
    private var completion: ((CaptureTarget?) -> Void)?
    func begin(displays: [SCDisplay], availableWindows: [SCWindow] = [], mode:CaptureMode = .screenshot, frames:[CGDirectDisplayID:FrozenFrame] = [:], windowOrder:[[String:Any]] = [], notice:String? = nil, allowsScreenshot:Bool = true, completion: @escaping (CaptureTarget?) -> Void) {
        cancel(notify: false)
        self.completion = completion
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = displays.first(where: { $0.displayID == id.uint32Value }) else { continue }
            if !frames.isEmpty && frames[display.displayID] == nil {continue}
            let frozen=frames[display.displayID]
            if let frozen,frozen.logicalSize != screen.frame.size{cancel(notify:false);failure?(CaptureFailure.message(L("屏幕布局已变化，请重新截图。")));return}
            let win = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false; win.acceptsMouseMovedEvents = true
            win.isOpaque = false; win.backgroundColor = .clear; win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.setMode(mode);view.setScreenshotAllowed(allowsScreenshot);view.frozenImage=frozen?.image;view.notice=notice
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            view.candidates = WindowSnapCandidates.make(order:windowOrder,
                fallback:WindowSnapCandidates.records(availableWindows),screen:screen.frame,
                primaryHeight:primaryHeight,ownPID:ProcessInfo.processInfo.processIdentifier).map{rect,id in
                    (rect,availableWindows.first{$0.windowID==id})
                }
            view.finished = { [weak self, weak view] rect, selectedWindow, annotate in
                guard let self else { return }
                if let rect {
                    let converted = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                    let selectedMode=view?.selectedMode ?? .screenshot
                    let cropped:CGImage?
                    do{cropped=selectedMode == .screenshot ? try frozen?.crop(converted) : nil}
                    catch{let failure=self.failure;self.cancel(notify:false);failure?(error);return}
                    let cb = self.completion; self.cancel(notify: false)
                    cb?(CaptureTarget(display: display, rect: converted, window: selectedWindow, annotationRequested: annotate, mode:selectedMode,frozenImage:cropped))
                } else { self.cancel(notify: true) }
            }
            view.hovered = view.candidates.first(where:{$0.0.contains(CGPoint(x:NSEvent.mouseLocation.x-screen.frame.minX,y:NSEvent.mouseLocation.y-screen.frame.minY))})
            win.contentView = view; win.makeKeyAndOrderFront(nil); win.makeFirstResponder(view)
            windows.append(win)
        }
        if windows.isEmpty { cancel(notify: true); return }
        NSApp.activate(ignoringOtherApps: true)
        let active = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows[0]
        active.makeKeyAndOrderFront(nil)
        active.makeFirstResponder(active.contentView)

    }
    func cancel(notify: Bool = true) {
        let callback = completion; completion = nil
        for window in windows {
            window.orderOut(nil)
            if let view = window.contentView as? SelectionView {
                view.finished = nil;view.frozenImage=nil; view.candidates.removeAll(); view.hovered = nil
            }
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        if notify { callback?(nil) }
    }
}
final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender:Any?){(contentView as? SelectionView)?.cancelSelection()}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
            return contentView?.performKeyEquivalent(with:event) ?? false
        }
        return super.performKeyEquivalent(with:event)
    }
}
final class SelectionView: NSView {
    var frozenImage:CGImage?
    var notice:String?
    var finished: ((CGRect?, SCWindow?, Bool) -> Void)?
    var candidates: [(CGRect,SCWindow?)] = []
    var hovered: (CGRect,SCWindow?)?
    private(set) var pendingRect: CGRect?
    private var pendingWindow: SCWindow?
    private var completed = false
    private let toolbar = NSVisualEffectView()
    private let modePicker = NSPopUpButton()
    var selectedMode:CaptureMode {CaptureMode(rawValue:modePicker.indexOfSelectedItem) ?? .screenshot}
    func setMode(_ mode:CaptureMode){modePicker.selectItem(at:mode.rawValue);updateMode()}
    func setScreenshotAllowed(_ allowed:Bool){modePicker.item(at:0)?.isEnabled=allowed;updateMode()}
    @objc private func updateMode(){annotateButton.isEnabled = pendingRect != nil && selectedMode == .screenshot}
    private let annotateButton = NSButton(title:L("标注…"),target:nil,action:nil)
    private let confirmButton = NSButton(title:L("确认 ↩"),target:nil,action:nil)
    private let cancelButton = NSButton(title:L("取消 Esc"),target:nil,action:nil)
    override init(frame: NSRect) {
        super.init(frame:frame)
        confirmButton.target=self;confirmButton.action=#selector(confirmSelection)
        cancelButton.target=self;cancelButton.action=#selector(cancelSelection)
        confirmButton.bezelStyle = .rounded;cancelButton.bezelStyle = .rounded
        confirmButton.isEnabled=false;annotateButton.isEnabled=false
        modePicker.addItems(withTitles:[L("截图"),L("录屏"),L("长截图")]);modePicker.target=self;modePicker.action=#selector(updateMode)
        annotateButton.target=self;annotateButton.action=#selector(annotateSelection);annotateButton.bezelStyle = .rounded
        toolbar.material = .hudWindow;toolbar.blendingMode = .withinWindow;toolbar.state = .active
        toolbar.wantsLayer=true;toolbar.layer?.cornerRadius=10;toolbar.layer?.masksToBounds=true
        confirmButton.bezelColor = .systemGreen
        addSubview(toolbar)
        for button in [modePicker,annotateButton,cancelButton,confirmButton] {toolbar.addSubview(button)}
        layout() // Explicit initial frames, even before AppKit schedules a layout pass.
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func layout(){
        super.layout()
        let widths=[max(88,modePicker.intrinsicContentSize.width),max(66,annotateButton.intrinsicContentSize.width),max(80,cancelButton.intrinsicContentSize.width),max(90,confirmButton.intrinsicContentSize.width)]
        let width:CGFloat=widths.reduce(0,+)+26,height:CGFloat=44,padding:CGFloat=10
        let anchor=pendingRect
        let x=min(max(padding,(anchor?.maxX ?? bounds.maxX)-width),max(padding,bounds.width-width-padding))
        let preferredY:CGFloat
        if let anchor {preferredY=anchor.minY >= height+padding*2 ? anchor.minY-height-padding : anchor.maxY+padding}
        else {preferredY=bounds.height-height-padding}
        let y=min(max(padding,preferredY),max(padding,bounds.height-height-padding))
        toolbar.frame=NSRect(x:x,y:y,width:width,height:height)
        var nextX:CGFloat=8
        for (index,view) in [modePicker,annotateButton,cancelButton,confirmButton].enumerated(){
            view.frame=NSRect(x:nextX,y:7,width:widths[index],height:30);nextX += widths[index]+4
        }
    }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    @objc func confirmSelection(){
        guard !completed,let rect=pendingRect else{return}
        CaptureDiagnostics.record(.buttonConfirm)
        completed=true;frozenImage=nil;finished?(rect,pendingWindow,false)
    }
    @objc func annotateSelection(){
        guard !completed,let rect=pendingRect else{return}
        completed=true;frozenImage=nil;finished?(rect,pendingWindow,true)
    }
    @objc func cancelSelection(){guard !completed else{return};CaptureDiagnostics.record(.cancel);completed=true;frozenImage=nil;finished?(nil,nil,false)}
    override func cancelOperation(_ sender:Any?){cancelSelection()}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if event.keyCode == 53 {cancelSelection();return true}
        if event.keyCode == 36 || event.keyCode == 76 {confirmSelection();return true}
        return super.performKeyEquivalent(with:event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeAlways,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseMoved(with event:NSEvent) {
        guard pendingRect == nil else{return}
        let p=convert(event.locationInWindow,from:nil);hovered=candidates.first(where:{$0.0.contains(p)});needsDisplay=true
    }
    private var start: CGPoint?; private var current: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    var selected: CGRect? {
        guard let a = start, let b = current else { return nil }
        return CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)).intersection(bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        if let image=frozenImage{NSImage(cgImage:image,size:bounds.size).draw(in:bounds)}
        NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
        if let r = (selected.flatMap { $0.width > 4 && $0.height > 4 ? $0 : nil } ?? pendingRect ?? hovered?.0) {
            // Keep hit-testing surface nontransparent so clicks do not pass through to another app.
            if let image=frozenImage{
                NSGraphicsContext.saveGraphicsState();r.clip();NSImage(cgImage:image,size:bounds.size).draw(in:bounds);NSGraphicsContext.restoreGraphicsState()
            }else{NSColor.black.withAlphaComponent(0.02).setFill(); r.fill(using: .copy)}
            NSColor.systemCyan.setStroke(); let p = NSBezierPath(rect:r); p.lineWidth=2; p.stroke()
        }
        let text = pendingRect == nil ? L("拖动选区 · 双击已选区域确认 · Esc 取消") : ""
        if let notice {notice.draw(at:CGPoint(x:24,y:bounds.height-62),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.white])}
        text.draw(at: CGPoint(x:24,y:bounds.height-40), withAttributes: [.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { guard !completed else{return};CaptureDiagnostics.record(.mouseDown)
        let point=convert(event.locationInWindow,from:nil)
        if event.clickCount >= 2,let locked=pendingRect,locked.contains(point) {
            CaptureDiagnostics.record(.doubleClickConfirm);confirmSelection();return
        }
        window?.makeKey();window?.makeFirstResponder(self);start=convert(event.locationInWindow,from:nil); current=start;hovered=candidates.first(where:{$0.0.contains(start!)}); needsDisplay=true }
    override func mouseDragged(with event:NSEvent) { current=convert(event.locationInWindow,from:nil); needsDisplay=true }
    override func mouseUp(with event:NSEvent) {
        guard !completed else{return}
        CaptureDiagnostics.record(.mouseUp)
        current=convert(event.locationInWindow,from:nil)
        if let r=selected,r.width>=20,r.height>=20 {pendingRect=r;pendingWindow=nil}
        else if pendingRect == nil,let origin=start,let end=current,hypot(origin.x-end.x,origin.y-end.y)<=4,let hovered {pendingRect=hovered.0;pendingWindow=hovered.1}
        start=nil;current=nil;confirmButton.isEnabled = pendingRect != nil;updateMode();layout();needsDisplay=true
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 {cancelSelection()}
        else if event.keyCode == 36 || event.keyCode == 76 {confirmSelection()}
        else {super.keyDown(with:event)}
    }
}
