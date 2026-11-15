import Foundation
import CoreMedia
@main struct RecordingFrameRouterTests {
 final class Frame {let marker:Int;init(_ marker:Int){self.marker=marker}}
 static func main(){
  var route=RecordingFrameRouter<Frame>();var written:[(Int,Double,Bool)]=[]
  func sink(_ f:Frame,_ t:CMTime,_ first:Bool)->Bool{written.append((f.marker,t.seconds,first));return true}
  func time(_ n:Double)->CMTime{CMTime(seconds:n,preferredTimescale:60000)}
  for n in 0..<30 {_=route.offer(Frame(n),at:time(Double(n)/30),isNewFrame:true,ready:true,append:sink)}
  for n in 30..<300 {_=route.offer(nil,at:time(Double(n)/30),isNewFrame:false,ready:true,append:sink)}
  for n in 300..<330 {_=route.offer(Frame(n),at:time(Double(n)/30),isNewFrame:true,ready:true,append:sink)}
  precondition(written.count == 60 && written[30].0 == 300 && written[30].1 == 10)
  precondition(written.filter{$0.2}.count == 1 && written.last!.0 == 329)
  print("PASS moving → 9s idle gap → moving: late fresh payloads reach sink, one session, no idle-frame flood")
  _=route.appendTail(endingAt:time(16),ready:true,append:sink)
  precondition(written.count == 61 && written.last!.0 == 329 && abs(written.last!.1-(16-1.0/30))<0.0001)
  precondition(zip(written,written.dropFirst()).allSatisfy{$0.1<$1.1})
  print("PASS single tail uses newest changed frame, extends idle duration with strictly increasing timestamps")
  let count=written.count
  _=route.offer(Frame(-1),at:time(9),isNewFrame:true,ready:true,append:sink)
  _=route.offer(Frame(-1),at:.invalid,isNewFrame:true,ready:true,append:sink)
  _=route.offer(nil,at:time(20),isNewFrame:true,ready:true,append:sink)
  precondition(written.count == count)
  print("PASS out-of-order, invalid, and no-image samples cannot replace latest frame")
  var pressure=RecordingFrameRouter<Frame>();var starts=0
  _=pressure.offer(Frame(1),at:time(1),isNewFrame:true,ready:false){_,_,_ in fatalError("must not call sink")}
  precondition(pressure.firstTime == nil && pressure.deferredFrames == 1)
  _=pressure.offer(Frame(2),at:time(2),isNewFrame:true,ready:true){f,_,first in precondition(f.marker == 2 && first);starts += 1;return true}
  precondition(starts == 1 && pressure.acceptedFrames == 1)
  let failed=pressure.offer(Frame(3),at:time(3),isNewFrame:true,ready:true){_,_,_ in false}
  if case .failed=failed {}else{fatalError("expected failed")}
  precondition(pressure.lastFrame!.marker == 2)
  precondition(pressure.pendingFrame == nil)
  _=pressure.offer(Frame(4),at:time(4),isNewFrame:true,ready:false){_,_,_ in false}
  _=pressure.offer(Frame(5),at:time(5),isNewFrame:true,ready:false){_,_,_ in false}
  _=pressure.offer(nil,at:time(6),isNewFrame:false,ready:true){_,_,_ in fatalError("idle must not append")}
  precondition(pressure.pendingFrame!.marker == 5)
  _=pressure.flushPending(ready:true){f,t,first in precondition(f.marker == 5 && t.seconds == 5 && !first);return true}
  precondition(pressure.lastFrame!.marker == 5 && pressure.pendingFrame == nil)
  print("PASS backpressure keeps latest pending change, flushes after idle without needing a new frame; failed append does not advance")
  weak var firstFrame:Frame?
  var bounded=RecordingFrameRouter<Frame>()
  do{let f=Frame(1);firstFrame=f;_=bounded.offer(f,at:time(1),isNewFrame:true,ready:true){_,_,_ in true}}
  precondition(firstFrame != nil)
  _=bounded.offer(Frame(2),at:time(2),isNewFrame:true,ready:true){_,_,_ in true}
  precondition(firstFrame == nil);bounded.releaseFrame();precondition(bounded.lastFrame == nil)
  print("PASS only latest frame retained and released on finish/abort")
 }
}
