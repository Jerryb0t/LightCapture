import AppKit

/// Session-only visual marker. Never activates or intercepts pointer/scroll events.
/// Render only outside captured pixels, including at a clipped display edge.
@MainActor final class LongCaptureBorder {
    private(set) var panel:NSPanel?
    static func frame(capture:CGRect,screen:CGRect)->CGRect {
        capture.insetBy(dx:-2,dy:-2).intersection(screen)
    }
    static func strips(capture:CGRect,screen:CGRect)->[CGRect] {
        let inset:CGFloat=2
        return [
            CGRect(x:capture.minX-inset,y:capture.minY-inset,width:capture.width+inset*2,height:inset),
            CGRect(x:capture.minX-inset,y:capture.maxY,width:capture.width+inset*2,height:inset),
            CGRect(x:capture.minX-inset,y:capture.minY,width:inset,height:capture.height),
            CGRect(x:capture.maxX,y:capture.minY,width:inset,height:capture.height)
        ].map{$0.intersection(screen)}.filter{!$0.isEmpty}
    }
    func show(capture:CGRect,screen:CGRect) {
        close()
        let frame=Self.frame(capture:capture,screen:screen)
        let strips=Self.strips(capture:capture,screen:screen)
        guard !frame.isEmpty,!strips.isEmpty else{return}
        let p=NSPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque=false;p.backgroundColor = .clear;p.hasShadow=false;p.ignoresMouseEvents=true
        p.hidesOnDeactivate=false;p.level = .floating;p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        p.isReleasedWhenClosed=false;p.sharingType = .none
        p.contentView=BorderView(size:frame.size,strips:strips.map{$0.offsetBy(dx:-frame.minX,dy:-frame.minY)})
        p.orderFrontRegardless();panel=p
    }
    func close(){panel?.orderOut(nil);panel?.contentView=nil;panel?.close();panel=nil}
    private final class BorderView:NSView {
        let strips:[CGRect]
        init(size:CGSize,strips:[CGRect]){
            self.strips=strips;super.init(frame:CGRect(origin:.zero,size:size))
        }
        required init?(coder:NSCoder){nil}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func draw(_ dirtyRect:NSRect){
            NSColor.systemTeal.setFill()
            for strip in strips {NSBezierPath(rect:strip).fill()}
        }
    }
}
