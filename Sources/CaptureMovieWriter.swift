import AppKit
import ScreenCaptureKit
import AVFoundation
import AudioToolbox

/// All mutable encoder state is confined to queue, also used as SCStream's sampleHandlerQueue.
final class CaptureMovieWriter:NSObject,SCStreamOutput, @unchecked Sendable {
    let queue=DispatchQueue(label:"local.lightcapture.movie-writer",qos:.userInitiated)
    private let writer:AVAssetWriter
    private let video:AVAssetWriterInput
    private let adaptor:AVAssetWriterInputPixelBufferAdaptor
    private let audio:AVAssetWriterInput?
    private let url:URL
    private var frames=RecordingFrameRouter<CVPixelBuffer>()
    private var accepting=true
    private var finishing=false
    private var audioFinished=false
    private var pendingSince:Double?
    private var drainScheduled=false
    private var finishTicket:UUID?
    private var error:Error?
    private var lastAudioTime:CMTime?
    private var firstFrameUptime:Double?
    private var startCallback:(()->Void)?
    private var failureCallback:((Error)->Void)?

    init(url:URL,width:Int,height:Int,systemAudio:Bool,started:@escaping()->Void,failed:@escaping(Error)->Void) throws {
        self.url=url;writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        video=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoExpectedSourceFrameRateKey:30,AVVideoAllowFrameReorderingKey:false]])
        video.expectsMediaDataInRealTime=true
        adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:video,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
        if systemAudio {
            let input=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000])
            input.expectsMediaDataInRealTime=true;audio=input
        }else{audio=nil}
        super.init()
        guard writer.canAdd(video) else{throw CaptureFailure.message(L("此设备暂不支持所选录屏编码。"))};writer.add(video)
        if let audio{guard writer.canAdd(audio) else{throw CaptureFailure.message(L("此设备暂不支持录制系统音频。"))};writer.add(audio)}
        guard writer.startWriting() else{throw writer.error ?? CaptureFailure.message(L("无法启动录屏编码器。")) }
        startCallback=started;failureCallback=failed
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType){
        consume(sampleBuffer,of:type)
    }
    // Also used by synthetic, screen-free encoder regression tests.
    func consume(_ sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType){
        dispatchPrecondition(condition:.onQueue(queue))
        guard accepting,!finishing,CMSampleBufferIsValid(sampleBuffer),CMSampleBufferDataIsReady(sampleBuffer) else{return}
        let time=CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if type == .screen {
            guard let attachments=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],let raw=attachments.first?[.status] as? Int,let status=SCFrameStatus(rawValue:raw) else{return}
            let isNew=status == .complete || status == .started
            let image=CMSampleBufferGetImageBuffer(sampleBuffer)
            // Copy only the tiny routing state; CVPixelBuffer is a retained reference, not a pixel copy.
            var route=frames
            let result=route.offer(image,at:time,isNewFrame:isNew,ready:video.isReadyForMoreMediaData,append:appendVideo)
            frames=route
            if case .failed=result{fail(writer.error ?? CaptureFailure.message(L("录屏视频帧写入失败。")));return}
            if frames.pendingFrame != nil {schedulePendingDrain()}else{pendingSince=nil}
            notifyFirstFrame()
        }else if type == .audio,let audio,let first=frames.firstTime,time.isNumeric,CMTimeCompare(time,first)>=0 {
            if let lastAudioTime,CMTimeCompare(time,lastAudioTime)<=0{return}
            guard audio.isReadyForMoreMediaData else{return}
            guard audio.append(sampleBuffer) else{fail(writer.error ?? CaptureFailure.message(L("录屏音频写入失败。")));return}
            lastAudioTime=time
        }
    }
    private func appendVideo(_ pixel:CVPixelBuffer,_ pts:CMTime,_ first:Bool)->Bool {
        if first {writer.startSession(atSourceTime:pts)}
        return adaptor.append(pixel,withPresentationTime:pts)
    }
    private func notifyFirstFrame(){
        if frames.acceptedFrames >= 1,let callback=startCallback {
            firstFrameUptime=ProcessInfo.processInfo.systemUptime;startCallback=nil;callback()
        }
    }
    private func schedulePendingDrain(){
        if pendingSince == nil {pendingSince=ProcessInfo.processInfo.systemUptime}
        guard !drainScheduled else{return};drainScheduled=true
        queue.asyncAfter(deadline:.now()+0.01){[self] in
            drainScheduled=false;guard accepting,!finishing,frames.pendingFrame != nil else{return}
            var route=frames;let result=route.flushPending(ready:video.isReadyForMoreMediaData,append:appendVideo);frames=route
            if case .failed=result{fail(writer.error ?? CaptureFailure.message(L("录屏视频帧写入失败。")));return}
            notifyFirstFrame()
            if frames.pendingFrame == nil {pendingSince=nil;return}
            if ProcessInfo.processInfo.systemUptime-(pendingSince ?? 0)>2 {fail(CaptureFailure.message(L("录屏编码器持续繁忙，最新画面未能写入，已停止录制。")));return}
            schedulePendingDrain()
        }
    }
    private func finishAudio(){if !audioFinished {audio?.markAsFinished();audioFinished=true}}
    private func fail(_ failure:Error){
        guard error == nil else{return};error=failure;accepting=false
        let callback=failureCallback;failureCallback=nil;callback?(failure)
    }
    /// Call after stopCapture finishes. Serial queue drains already-delivered callbacks before closing inputs.
    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finishing else{continuation.resume(throwing:CaptureFailure.message(L("录屏正在结束，请稍候。")));return}
                finishing=true;accepting=false;startCallback=nil;failureCallback=nil
                if let error {closePreservingOutput();frames.releaseFrame();continuation.resume(throwing:error);return}
                if writer.status == .failed || writer.status == .cancelled {frames.releaseFrame();continuation.resume(throwing:writer.error ?? CaptureFailure.message(L("录屏编码器已停止。")));return}
                guard let first=frames.firstTime,let last=frames.lastTime,let uptime=firstFrameUptime else{
                    writer.cancelWriting();frames.releaseFrame();continuation.resume(throwing:CaptureFailure.message(L("没有收到可用视频帧，未生成有效录屏。")));return
                }
                // Use a monotonic elapsed interval aligned to first media PTS, not wall-clock dates.
                let elapsed=max(0,ProcessInfo.processInfo.systemUptime-uptime)
                let end=CMTimeMaximum(CMTimeAdd(first,CMTime(seconds:elapsed,preferredTimescale:60000)),CMTimeAdd(last,CMTime(value:1,timescale:30)))
                finishAudio()
                finishPending(end:end,deadline:ProcessInfo.processInfo.systemUptime+2,continuation:continuation)
            }
        }
    }
    private func finishPending(end:CMTime,deadline:Double,continuation:CheckedContinuation<URL,Error>){
        if frames.pendingFrame != nil {
            var route=frames;let result=route.flushPending(ready:video.isReadyForMoreMediaData,append:appendVideo);frames=route
            if case .failed=result{closePreservingOutput();frames.releaseFrame();continuation.resume(throwing:writer.error ?? CaptureFailure.message(L("最新视频帧写入失败。")));return}
            if frames.pendingFrame != nil {
                if ProcessInfo.processInfo.systemUptime<deadline {queue.asyncAfter(deadline:.now()+0.01){[self] in finishPending(end:end,deadline:deadline,continuation:continuation)};return}
                closePreservingOutput();frames.releaseFrame();continuation.resume(throwing:CaptureFailure.message(L("最新视频帧持续无法写入，录屏未完整完成。")));return
            }
        }
        let finalEnd=CMTimeMaximum(end,CMTimeAdd(frames.lastTime!,CMTime(value:1,timescale:30)))
        finishTail(end:finalEnd,deadline:deadline,continuation:continuation)
    }
    private func finishTail(end:CMTime,deadline:Double,continuation:CheckedContinuation<URL,Error>){
        if writer.status == .failed || writer.status == .cancelled {let e=writer.error ?? CaptureFailure.message(L("录屏编码失败。"));frames.releaseFrame();continuation.resume(throwing:e);return}
        if !video.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime<deadline {
            queue.asyncAfter(deadline:.now()+0.01){[self] in finishTail(end:end,deadline:deadline,continuation:continuation)};return
        }
        var route=frames
        let outcome=route.appendTail(endingAt:end,ready:video.isReadyForMoreMediaData){[self] pixel,time,_ in adaptor.append(pixel,withPresentationTime:time)}
        route.releaseFrame();frames=route
        if case .failed=outcome {closePreservingOutput();continuation.resume(throwing:writer.error ?? CaptureFailure.message(L("录屏尾帧写入失败。")));return}
        // If only the optional tail cannot be appended, finalize accepted frames; never delete a recording for this.
        video.markAsFinished();finishAudio();writer.endSession(atSourceTime:end)
        let ticket=UUID();finishTicket=ticket
        queue.asyncAfter(deadline:.now()+10){[self] in
            guard finishTicket == ticket else{return};finishTicket=nil
            continuation.resume(throwing:CaptureFailure.message(L("录屏文件收尾超时，可在待保存目录检查后续结果。")))
        }
        writer.finishWriting{[self] in queue.async{[self] in
            guard finishTicket == ticket else{return};finishTicket=nil
            if writer.status == .completed {continuation.resume(returning:url)}else{continuation.resume(throwing:writer.error ?? CaptureFailure.message(L("录屏文件未能完成写入。")))}
        }}
    }
    private func closePreservingOutput(){
        // cancelWriting deletes the output: use it only if no frame was ever accepted.
        if writer.status == .writing,frames.firstTime != nil {
            video.markAsFinished();finishAudio();writer.finishWriting{[self] in _=writer.status}
        }else if frames.firstTime == nil {writer.cancelWriting()}
    }
    func abort(){queue.async{[self] in accepting=false;startCallback=nil;failureCallback=nil;if !finishing {finishing=true;closePreservingOutput();frames.releaseFrame()}}}
}
