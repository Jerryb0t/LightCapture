import Foundation
import CoreMedia

/// One accepted tail plus at most one latest pending frame, no backlog. A real later frame always supersedes the idle tail.
struct RecordingFrameRouter<Frame> {
    enum Outcome {case accepted, ignored, backpressure, failed}
    private(set) var firstTime:CMTime?
    private(set) var lastTime:CMTime?
    private(set) var lastFrame:Frame?
    private(set) var acceptedFrames=0
    private(set) var deferredFrames=0
    private(set) var pendingFrame:Frame?
    private(set) var pendingTime:CMTime?
    mutating func offer(_ frame:Frame?,at time:CMTime,isNewFrame:Bool,ready:Bool,append:(Frame,CMTime,Bool)->Bool)->Outcome {
        guard isNewFrame,let frame,time.isNumeric,time.seconds.isFinite else{return .ignored}
        if let lastTime,CMTimeCompare(time,lastTime)<=0{return .ignored}
        if let pendingTime,CMTimeCompare(time,pendingTime)<0{return .ignored}
        guard ready else{pendingFrame=frame;pendingTime=time;deferredFrames += 1;return .backpressure}
        guard append(frame,time,firstTime == nil) else{return .failed}
        if firstTime == nil{firstTime=time};lastTime=time;lastFrame=frame;pendingFrame=nil;pendingTime=nil;acceptedFrames += 1
        return .accepted
    }
    mutating func flushPending(ready:Bool,append:(Frame,CMTime,Bool)->Bool)->Outcome {
        guard let pendingFrame,let pendingTime else{return .ignored}
        return offer(pendingFrame,at:pendingTime,isNewFrame:true,ready:ready,append:append)
    }
    /// At most one explicit terminal frame, never a timer that repeats static frames.
    mutating func appendTail(endingAt end:CMTime,ready:Bool,frameDuration:CMTime = CMTime(value:1,timescale:30),append:(Frame,CMTime,Bool)->Bool)->Outcome {
        guard let frame=lastFrame,let lastTime,end.isNumeric else{return .ignored}
        let tail=CMTimeSubtract(end,frameDuration)
        guard CMTimeCompare(tail,lastTime)>0 else{return .ignored}
        guard ready else{return .backpressure}
        guard append(frame,tail,false) else{return .failed}
        self.lastTime=tail;return .accepted
    }
    mutating func releaseFrame(){lastFrame=nil;pendingFrame=nil;pendingTime=nil}
}
