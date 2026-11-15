import Foundation
import AVFoundation
import ScreenCaptureKit
import AudioToolbox
@main struct RecordingAVIntegrationTests {
 static func check(_ value:Bool,_ reason:String)throws{if !value{throw NSError(domain:"SyntheticRecordingTest",code:1,userInfo:[NSLocalizedDescriptionKey:reason])}}
 static func video(_ index:Int,_ fps:Int)throws->CMSampleBuffer {
  var pixel:CVPixelBuffer?;try check(CVPixelBufferCreate(kCFAllocatorDefault,160,96,kCVPixelFormatType_32BGRA,nil,&pixel)==kCVReturnSuccess,"pixel allocation")
  let p=pixel!;CVPixelBufferLockBaseAddress(p,[]);let b=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(p)
  for y in 0..<96{for x in 0..<160{let n=y*stride+x*4;b[n]=20;b[n+1]=(x>=index*2%140 && x<index*2%140+12) ? 230:30;b[n+2]=50;b[n+3]=255}}
  CVPixelBufferUnlockBaseAddress(p,[])
  var format:CMVideoFormatDescription?;try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:p,formatDescriptionOut:&format)==noErr,"video format")
  var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:Int32(fps)),presentationTimeStamp:CMTime(value:Int64(index),timescale:Int32(fps)),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
  try check(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:p,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,"video sample")
  let attachments=CMSampleBufferGetSampleAttachmentsArray(sample!,createIfNecessary:true)! as NSArray
  (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue]=SCFrameStatus.complete.rawValue
  return sample!
 }
 static func audio(_ index:Int,_ fps:Int,_ frequency:Double,_ channels:Int)throws->CMSampleBuffer {
  let frames=48000/fps;var pcm=[Float](repeating:0,count:frames*channels)
  for i in 0..<frames {let value=Float(0.4*sin(2*Double.pi*frequency*Double(index*frames+i)/48000));for c in 0..<channels{pcm[i*channels+c]=value}}
  var asbd=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:UInt32(channels*4),mFramesPerPacket:1,mBytesPerFrame:UInt32(channels*4),mChannelsPerFrame:UInt32(channels),mBitsPerChannel:32,mReserved:0)
  var format:CMAudioFormatDescription?;try check(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format)==noErr,"audio format")
  var block:CMBlockBuffer?;let length=pcm.count*4
  try check(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:length,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:length,flags:0,blockBufferOut:&block)==noErr,"PCM buffer")
  let copied=pcm.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:length)};try check(copied==noErr,"PCM copy")
  var sample:CMSampleBuffer?
  try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault,dataBuffer:block!,formatDescription:format!,sampleCount:frames,presentationTimeStamp:CMTime(value:Int64(index),timescale:Int32(fps)),packetDescriptions:nil,sampleBufferOut:&sample)==noErr,"audio sample")
  return sample!
 }
 static func packets(_ url:URL)async throws->([Data],[Double],Float){
  let asset=AVURLAsset(url:url)
  guard let actual=try await asset.loadTracks(withMediaType:.video).first else{throw NSError(domain:"SyntheticRecordingTest",code:2,userInfo:[NSLocalizedDescriptionKey:"missing video track"])}
  let reader=try AVAssetReader(asset:asset),out=AVAssetReaderTrackOutput(track:actual,outputSettings:nil);reader.add(out);try check(reader.startReading(),"packet reader")
  var data:[Data]=[],times:[Double]=[]
  while let sample=out.copyNextSampleBuffer(){
   guard let block=CMSampleBufferGetDataBuffer(sample) else{continue}
   let length=CMBlockBufferGetDataLength(block);var bytes=[UInt8](repeating:0,count:length)
   try check(CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:&bytes)==noErr,"packet bytes")
   data.append(Data(bytes));times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
  }
  try check(reader.status == .completed,"packet completion")
  return(data,times,try await actual.load(.nominalFrameRate))
 }
 static func tones(_ url:URL)async throws->(Double,Double){
  let asset=AVURLAsset(url:url),tracks=try await AVURLAsset(url:url).loadTracks(withMediaType:.audio)
  try check(tracks.count==1,"final must have one mixed audio track")
  guard let actual=try await asset.loadTracks(withMediaType:.audio).first else{throw NSError(domain:"SyntheticRecordingTest",code:3)}
  let reader=try AVAssetReader(asset:asset),out=AVAssetReaderTrackOutput(track:actual,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false]);reader.add(out);try check(reader.startReading(),"PCM reader")
  var values:[Float]=[]
  while let sample=out.copyNextSampleBuffer(){guard let block=CMSampleBufferGetDataBuffer(sample) else{continue};let length=CMBlockBufferGetDataLength(block);var floats=[Float](repeating:0,count:length/4);try check(CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:&floats)==noErr,"PCM read");for n in stride(from:0,to:floats.count,by:2){values.append(floats[n])}}
  try check(reader.status == .completed && values.count>40000,"decoded audio duration")
  func strength(_ hz:Double)->Double{var re=0.0,im=0.0;for (i,v) in values.enumerated(){let a=2*Double.pi*hz*Double(i)/48000;re += Double(v)*cos(a);im += Double(v)*sin(a)};return hypot(re,im)/Double(values.count)}
  return(strength(440),strength(880))
 }
 static func main()async{
  setbuf(stdout,nil)
  do{
   let folder=FileManager.default.temporaryDirectory.appendingPathComponent("LightCapture-AV-"+UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   for rate in RecordingFrameRate.allCases {
    let input=folder.appendingPathComponent("source-\(rate.rawValue).mp4"),output=folder.appendingPathComponent("mixed-\(rate.rawValue).mp4")
    let writer=try CaptureMovieWriter(url:input,width:160,height:96,systemAudio:true,microphone:true,frameRate:rate,started:{},failed:{_ in})
    for i in 0..<rate.rawValue {
     let v=try video(i,rate.rawValue),system=try audio(i,rate.rawValue,440,2),mic=try audio(i,rate.rawValue,880,1)
     await withCheckedContinuation{c in writer.queue.async{writer.consume(v,of:.screen);writer.consume(system,of:.audio);writer.consume(mic,of:.microphone);c.resume()}}
     try await Task.sleep(nanoseconds:12_000_000)
    }
    let source=try await writer.finish();print("ENCODED",rate.rawValue);let mixed=try await RecordingAudioMixdown.mix(source,output:output)
    print("MIXED",rate.rawValue);let a=try await packets(source),b=try await packets(mixed);print("PACKETS",a.0.count,b.0.count,"payloadEqual",a.0==b.0,"timingEqual",a.1==b.1);try check(a.0==b.0 && a.1==b.1,"compressed video packets and PTS must be identical")
    try check(a.0.count>=rate.rawValue && abs(b.2-a.2)<0.001,"source average frame rate retained")
    try check(Array(a.1.prefix(rate.rawValue)).enumerated().allSatisfy{abs($0.element-Double($0.offset)/Double(rate.rawValue))<0.000001},"selected frame cadence retained, excluding optional held idle tail")
    let amplitude=try await tones(mixed);try check(amplitude.0>0.02 && amplitude.1>0.02,"both source tones must be audible in single track")
    try check(FileManager.default.fileExists(atPath:source.path),"mixer does not delete original")
    print("PASS \(rate.rawValue) fps: exact video packets+PTS retained, one mixed AAC track, both independent tones detected")
   }
   for (systemOn,micOn,label) in [(true,false,"system-only"),(false,true,"microphone-only"),(false,false,"silent")] {
    let input=folder.appendingPathComponent(label+".mp4")
    let writer=try CaptureMovieWriter(url:input,width:160,height:96,systemAudio:systemOn,microphone:micOn,frameRate:.fps30,started:{},failed:{_ in})
    for i in 0..<30 {
     let v=try video(i,30),system=try audio(i,30,440,2),mic=try audio(i,30,880,1)
     await withCheckedContinuation{c in writer.queue.async{writer.consume(v,of:.screen);if systemOn{writer.consume(system,of:.audio)};if micOn{writer.consume(mic,of:.microphone)};c.resume()}}
     try await Task.sleep(nanoseconds:12_000_000)
    }
    let source=try await writer.finish()
    let result=try await RecordingAudioMixdown.mix(source)
    try check(result==source,"zero/single track must avoid mix/export")
    let tracks=try await AVURLAsset(url:result).loadTracks(withMediaType:.audio)
    try check(tracks.count == (systemOn || micOn ? 1:0),"independent audio toggle track count")
    if systemOn || micOn {
     let amplitude=try await tones(result)
     try check(systemOn ? amplitude.0>0.02 && amplitude.1<0.01 : amplitude.1>0.02 && amplitude.0<0.01,"only selected source tone present")
    }
    print("PASS independent audio option: \(label)")
   }
  }catch{let e=error as NSError;print("NOT PASS: \(e.domain) code=\(e.code) \(e.localizedDescription)");exit(2)}
 }
}
