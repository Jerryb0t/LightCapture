import Foundation
import AVFoundation
import ScreenCaptureKit
import Darwin
@main struct ExplicitWriterSyntheticTests {
 static func sample(index:Int) throws -> CMSampleBuffer {
  var pixel:CVPixelBuffer?;precondition(CVPixelBufferCreate(kCFAllocatorDefault,160,96,kCVPixelFormatType_32BGRA,nil,&pixel)==kCVReturnSuccess)
  let p=pixel!;CVPixelBufferLockBaseAddress(p,[])
  let bytes=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(p),bar=(index*2)%140
  for y in 0..<96{for x in 0..<160{let n=y*stride+x*4;bytes[n]=20;bytes[n+1]=(x>=bar && x<bar+12) ? 230:30;bytes[n+2]=50;bytes[n+3]=255}}
  CVPixelBufferUnlockBaseAddress(p,[])
  var format:CMVideoFormatDescription?;precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:p,formatDescriptionOut:&format)==noErr)
  var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(index),timescale:30),decodeTimeStamp:.invalid),buffer:CMSampleBuffer?
  precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:p,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&buffer)==noErr)
  let attachments=CMSampleBufferGetSampleAttachmentsArray(buffer!,createIfNecessary:true)! as NSArray
  let dictionary=attachments[0] as! NSMutableDictionary;dictionary[SCStreamFrameInfo.status.rawValue]=SCFrameStatus.complete.rawValue
  return buffer!
 }
 static func main() async {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/explicit-recording/synthetic-"+UUID().uuidString,isDirectory:true)
  do{
   try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
   let movie=try CaptureMovieWriter(url:root.appendingPathComponent("moving-idle-moving.mp4"),width:160,height:96,systemAudio:false,started:{},failed:{_ in})
   // Actual new writer, synthetic frames only. Later moving content follows a real PTS gap.
   for i in Array(0..<30)+Array(300..<330) {
    let buffer=try sample(index:i)
    await withCheckedContinuation{continuation in movie.queue.async{movie.consume(buffer,of:.screen);continuation.resume()}}
    try await Task.sleep(nanoseconds:35_000_000)
   }
   let url=try await movie.finish()
   let asset=AVURLAsset(url:url)
   let track=try await asset.loadTracks(withMediaType:.video)[0]
   let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:nil);reader.add(output);guard reader.startReading() else{throw reader.error!}
   var early=0,late=0
   while let frame=output.copyNextSampleBuffer(){let t=CMSampleBufferGetPresentationTimeStamp(frame).seconds;if t<1{early += 1};if t>=10{late += 1}}
   precondition(reader.status == .completed && early>20 && late>20)
   print("PASS actual explicit writer produced early and late synthetic moving samples across idle PTS gap")
  }catch{
   let e=error as NSError;print("BLOCKED actual synthetic writer: domain=\(e.domain) code=\(e.code); not a pass")
   exit(2)
  }
 }
}
