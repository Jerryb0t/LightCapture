import Foundation
import AVFoundation
import ScreenCaptureKit
@main struct RecordingFrameRateTests {
 static func main(){
  func check(_ yes:Bool,_ label:String){if !yes{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
  let name="LightCaptureFPS-"+UUID().uuidString;let defaults=UserDefaults(suiteName:name)!
  defer{defaults.removePersistentDomain(forName:name)}
  check(RecordingFrameRate.load(from:defaults) == .fps30,"fresh/legacy defaults to 30")
  defaults.set(120,forKey:RecordingFrameRate.preferenceKey);check(RecordingFrameRate.load(from:defaults) == .fps30,"invalid preference falls back to 30")
  for rate in RecordingFrameRate.allCases {
   rate.save(to:defaults);check(RecordingFrameRate.load(from:defaults)==rate,"independent persisted FPS")
   let config=SCStreamConfiguration();rate.configure(config);check(CMTimeCompare(config.minimumFrameInterval,rate.interval)==0,"SCK target interval")
   let settings=CaptureMovieWriter.videoSettings(width:3840,height:2160,frameRate:rate)
   let compression=settings[AVVideoCompressionPropertiesKey] as! [String:Any]
   check(compression[AVVideoExpectedSourceFrameRateKey] as? Int == rate.rawValue,"writer expected source rate")
   check(settings[AVVideoWidthKey] as? Int == 3840 && settings[AVVideoHeightKey] as? Int == 2160,"FPS never changes resolution")
   var router=RecordingFrameRouter<Int>();var times:[CMTime]=[]
   for frame in 0..<rate.rawValue {
    _=router.offer(frame,at:CMTime(value:Int64(frame),timescale:Int32(rate.rawValue)),isNewFrame:true,ready:true){_,time,_ in times.append(time);return true}
   }
   _=router.offer(999,at:CMTime(seconds:8,preferredTimescale:60000),isNewFrame:true,ready:true){_,time,_ in times.append(time);return true}
   _=router.appendTail(endingAt:CMTime(seconds:9,preferredTimescale:60000),ready:true,frameDuration:rate.interval){_,time,_ in times.append(time);return true}
   check(times.count==rate.rawValue+2,"fresh frames and late motion accepted without idle duplication")
   check(CMTimeCompare(times.last!,CMTimeSubtract(CMTime(seconds:9,preferredTimescale:60000),rate.interval))==0,"tail uses selected frame duration")
   check(zip(times,times.dropFirst()).allSatisfy{CMTimeCompare($0,$1)<0},"monotonic video times")
  }
  print("PASS 24/30/60 target interval, encoder rate, independent settings/default migration, per-rate timing, late motion and no idle frame flood")
 }
}
