import Foundation
import AVFoundation
import AudioToolbox

/// Offline mixdown only when both capture inputs were requested. Video packets
/// are passed through unchanged; no video decoder, scaling or frame-rate preset.
enum RecordingAudioMixdown {
    static func mix(_ source:URL, output destination:URL? = nil) async throws->URL {
        let asset=AVURLAsset(url:source)
        let tracks=try await asset.loadTracks(withMediaType:.audio)
        guard tracks.count>1 else{return source}
        guard let video=try await asset.loadTracks(withMediaType:.video).first,
              let format=try await video.load(.formatDescriptions).first else{throw CaptureFailure.message(L("音频合成失败：原视频轨不可用，原文件已保留。"))}
        let duration=try await asset.load(.duration)
        let output:URL
        if let destination {output=destination}else{output=try CaptureStorage.temporaryURL(ext:"mp4")}
        let job=try MixJob(asset:asset,video:video,format:format,audio:tracks,output:output,duration:duration)
        return try await withTaskCancellationHandler(operation:{try await job.run()},onCancel:{job.cancel()})
    }
    private final class MixJob:@unchecked Sendable {
        let queue=DispatchQueue(label:"local.lightcapture.audio-mix",qos:.userInitiated)
        let reader:AVAssetReader,writer:AVAssetWriter
        let videoRead:AVAssetReaderTrackOutput,audioRead:AVAssetReaderAudioMixOutput
        let videoWrite:AVAssetWriterInput,audioWrite:AVAssetWriterInput
        let output:URL,duration:CMTime
        var continuation:CheckedContinuation<URL,Error>?
        var terminal=false,cancelled=false,finished=0
        var ended=Set<ObjectIdentifier>()
        var timeout:DispatchWorkItem?
        init(asset:AVAsset,video:AVAssetTrack,format:CMFormatDescription,audio:[AVAssetTrack],output:URL,duration:CMTime)throws {
            self.output=output;self.duration=duration
            reader=try AVAssetReader(asset:asset);writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
            videoRead=AVAssetReaderTrackOutput(track:video,outputSettings:nil);videoRead.alwaysCopiesSampleData=false
            audioRead=AVAssetReaderAudioMixOutput(audioTracks:audio,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false]);audioRead.alwaysCopiesSampleData=false
            let mix=AVMutableAudioMix();mix.inputParameters=audio.map{track in let p=AVMutableAudioMixInputParameters(track:track);p.setVolume(1/Float(audio.count),at:.zero);return p};audioRead.audioMix=mix
            videoWrite=AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:format)
            audioWrite=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
            guard reader.canAdd(videoRead),reader.canAdd(audioRead),writer.canAdd(videoWrite),writer.canAdd(audioWrite) else{throw CaptureFailure.message(L("此设备无法合成系统声音与麦克风；原文件已保留。"))}
            reader.add(videoRead);reader.add(audioRead);writer.add(videoWrite);writer.add(audioWrite)
        }
        func run() async throws->URL {
            try await withCheckedThrowingContinuation{c in queue.async{[self] in
                continuation=c
                if cancelled {complete(.failure(CancellationError()));return}
                guard writer.startWriting(),reader.startReading() else{complete(.failure(writer.error ?? reader.error ?? CaptureFailure.message(L("音频合成未能启动，原文件已保留。"))));return}
                writer.startSession(atSourceTime:.zero)
                videoWrite.requestMediaDataWhenReady(on:queue){[weak self] in guard let self else{return};self.pump(self.videoRead,into:self.videoWrite)}
                audioWrite.requestMediaDataWhenReady(on:queue){[weak self] in guard let self else{return};self.pump(self.audioRead,into:self.audioWrite)}
                let seconds=duration.seconds.isFinite ? max(30,min(1800,duration.seconds*2+30)) : 300
                let deadline=DispatchWorkItem{[weak self] in self?.complete(.failure(CaptureFailure.message(L("音频合成超时，原文件已保留。"))))};timeout=deadline;queue.asyncAfter(deadline:.now()+seconds,execute:deadline)
            }}
        }
        func pump(_ input:AVAssetReaderOutput,into target:AVAssetWriterInput){
            guard !terminal,!ended.contains(ObjectIdentifier(target)) else{return}
            while target.isReadyForMoreMediaData && !terminal {
                guard let sample=input.copyNextSampleBuffer() else{
                    ended.insert(ObjectIdentifier(target));target.markAsFinished();finished += 1
                    if reader.status == .failed {complete(.failure(reader.error ?? CaptureFailure.message(L("音频合成读取失败，原文件已保留。"))));return}
                    if finished==2 {writer.finishWriting{[self] in queue.async{[self] in
                        if writer.status == .completed {complete(.success(output))}else{complete(.failure(writer.error ?? CaptureFailure.message(L("音频合成未能完成，原文件已保留。"))))}
                    }}}
                    return
                }
                if !target.append(sample){complete(.failure(writer.error ?? CaptureFailure.message(L("音频合成写入失败，原文件已保留。"))));return}
            }
        }
        func complete(_ result:Result<URL,Error>){
            guard !terminal else{return};terminal=true;timeout?.cancel();timeout=nil
            if case .failure=result {reader.cancelReading();writer.cancelWriting();try? FileManager.default.removeItem(at:output)}
            let c=continuation;continuation=nil;c?.resume(with:result)
        }
        func cancel(){queue.async{[self] in cancelled=true;if continuation != nil{complete(.failure(CancellationError()))}}}
    }
}
