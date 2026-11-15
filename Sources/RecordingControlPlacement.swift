import Foundation
import CoreGraphics

/// All geometry is AppKit global points (bottom-left origin), never backing pixels.
enum RecordingControlPlacement {
    static func globalCapture(localTopLeft rect:CGRect, screen:CGRect)->CGRect {
        CGRect(x:screen.minX+rect.minX,y:screen.maxY-rect.maxY,width:rect.width,height:rect.height)
    }
    /// Prefer outside the selected region on its screen, then a different display.
    /// Nil means menu/main-window stop only. Never fall back to covering the recording.
    static func frame(size:CGSize, capture:CGRect, visibleScreens:[CGRect], recordedScreenIndex:Int, gap:CGFloat=12)->CGRect? {
        guard visibleScreens.indices.contains(recordedScreenIndex),size.width>0,size.height>0 else{return nil}
        let visible=visibleScreens[recordedScreenIndex]
        func clamped(_ x:CGFloat,_ y:CGFloat,in bounds:CGRect)->CGRect? {
            guard size.width<=bounds.width,size.height<=bounds.height else{return nil}
            return CGRect(x:min(max(x,bounds.minX),bounds.maxX-size.width),y:min(max(y,bounds.minY),bounds.maxY-size.height),width:size.width,height:size.height)
        }
        let positions:[CGPoint]=[
            CGPoint(x:capture.maxX-size.width,y:capture.minY-gap-size.height),
            CGPoint(x:capture.maxX-size.width,y:capture.maxY+gap),
            CGPoint(x:capture.maxX+gap,y:capture.midY-size.height/2),
            CGPoint(x:capture.minX-gap-size.width,y:capture.midY-size.height/2)]
        let protected=capture.insetBy(dx:-gap,dy:-gap)
        for p in positions {
            if let frame=clamped(p.x,p.y,in:visible),!frame.intersects(protected){return frame}
        }
        for (index,bounds) in visibleScreens.enumerated() where index != recordedScreenIndex {
            if let frame=clamped(bounds.maxX-size.width-gap,bounds.maxY-size.height-gap,in:bounds),!frame.intersects(protected){return frame}
        }
        return nil
    }
}
