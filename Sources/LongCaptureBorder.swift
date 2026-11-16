import AppKit

/// Session-only visual marker. Never activates or intercepts pointer/scroll events.
@MainActor final class LongCaptureBorder {
    private(set) var panel:NSPanel?
    static func frame(capture:CGRect,screen:CGRect)->CGRect {capture.insetBy(dx:-2,dy:-2).intersection(screen)}
    func show(capture:CGRect,screen:CGRect) {
        close()
        let frame=Self.frame(capture:capture,screen:screen)
        guard !frame.isEmpty else{return}
        let p=NSPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque=false;p.backgroundColor = .clear;p.hasShadow=false;p.ignoresMouseEvents=true
        p.hidesOnDeactivate=false;p.level = .floating;p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        p.isReleasedWhenClosed=false;p.sharingType = .none
        p.contentView=BorderView(frame:CGRect(origin:.zero,size:frame.size));p.orderFrontRegardless();panel=p
    }
    func close(){panel?.orderOut(nil);panel?.contentView=nil;panel?.close();panel=nil}
    private final class BorderView:NSView {
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func draw(_ dirtyRect:NSRect){NSColor.systemTeal.setStroke();let path=NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5));path.lineWidth=1;path.stroke()}
    }
}
