import AppKit
import ScreenCaptureKit
import AVFoundation

@MainActor final class CaptureEngine: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var movie: CaptureMovieWriter?
    private var sessionID=UUID()
    private var stopping=false
    private var needsAudioMix=false
    private var firstFrameDeadline:Task<Void,Never>?
    private let recordingContentDeadline=DeadlineRequest<SCShareableContent>()
    private let recordingStopDeadline=DeadlineRequest<Void>()
    private var tempURL: URL?
    private var completion: ((Result<URL,Error>) -> Void)?
    var started: (() -> Void)?
    var active: Bool { stream != nil }

    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    static func configuration(target: CaptureTarget, recording: Bool, systemAudio: Bool = false, microphone:Bool = false, highQuality: Bool = false, frameRate:RecordingFrameRate = .fps30) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = target.rect
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.display.displayID }
        let scale = screen?.backingScaleFactor ?? 2
        let requestedWidth = target.rect.width * scale
        let requestedHeight = target.rect.height * scale
        let limit: CGFloat = recording ? (highQuality ? 3840 : 1920) : max(requestedWidth, requestedHeight)
        let ratio = min(1, limit / max(requestedWidth, requestedHeight))
        config.width = max(2, Int(requestedWidth * ratio) / 2 * 2)
        config.height = max(2, Int(requestedHeight * ratio) / 2 * 2)
        config.showsCursor = recording
        config.capturesAudio = recording && systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = recording && microphone
        if recording {config.pixelFormat=kCVPixelFormatType_32BGRA;config.sampleRate=48000;config.channelCount=2}
        config.queueDepth = recording ? 5 : 3
        frameRate.configure(config)
        return config
    }
    static func filter(target: CaptureTarget, content: SCShareableContent, recording:Bool = false) throws -> SCContentFilter {
        if !recording, let window = target.window {
            guard let current = content.windows.first(where:{$0.windowID == window.windowID}) else {throw CaptureFailure.message(L("目标窗口已关闭，请重新选择。"))};return SCContentFilter(desktopIndependentWindow:current)
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // Application exclusion also covers controls created after this snapshot.
        return SCContentFilter(display: target.display, excludingApplications: own, exceptingWindows: [])
    }
    static func screenshot(target: CaptureTarget) async throws -> CGImage {
        let content = try await content()
        guard content.displays.contains(where: {$0.displayID == target.display.displayID}) else { throw CaptureFailure.message(L("屏幕已断开，请重新选择区域。")) }
        let filter = try filter(target:target,content:content)
        let config = configuration(target:target,recording:false)
        if target.window != nil {
            config.sourceRect = .zero
            config.width = max(2,Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
            config.height = max(2,Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
            config.ignoreShadowsSingleWindow = true
        }
        return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
    }
    func start(target: CaptureTarget, systemAudio: Bool, microphone:Bool = false, highQuality: Bool, frameRate:RecordingFrameRate = .fps30, completion: @escaping (Result<URL,Error>) -> Void) async throws {
        guard stream == nil else {throw CaptureFailure.message(L("已有录屏任务。"))}
        let content:SCShareableContent=try await withCheckedThrowingContinuation{ continuation in
            recordingContentDeadline.start(seconds:8,operation:{try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)},completion:{continuation.resume(with:$0)})
        }
        guard content.displays.contains(where:{$0.displayID == target.display.displayID}) else{throw CaptureFailure.message(L("屏幕已断开。"))}
        let url=try CaptureStorage.temporaryURL(ext:"mp4")
        let config=Self.configuration(target:target,recording:true,systemAudio:systemAudio,microphone:microphone,highQuality:highQuality,frameRate:frameRate)
        let token=UUID();sessionID=token;stopping=false;needsAudioMix=systemAudio && microphone
        let movie=try CaptureMovieWriter(url:url,width:config.width,height:config.height,systemAudio:systemAudio,microphone:microphone,frameRate:frameRate,started:{[weak self] in
            Task{@MainActor in guard let self,self.sessionID == token,self.stream != nil,!self.stopping else{return};self.firstFrameDeadline?.cancel();self.firstFrameDeadline=nil;self.started?()}
        },failed:{[weak self] error in
            Task{@MainActor in guard let self,self.sessionID == token else{return};await self.writerFailed(error)}
        })
        let stream=SCStream(filter:try Self.filter(target:target,content:content,recording:true),configuration:config,delegate:self)
        do{
            try stream.addStreamOutput(movie,type:.screen,sampleHandlerQueue:movie.queue)
            if systemAudio {try stream.addStreamOutput(movie,type:.audio,sampleHandlerQueue:movie.queue)}
            if microphone {try stream.addStreamOutput(movie,type:.microphone,sampleHandlerQueue:movie.queue)}
            self.stream=stream;self.movie=movie;tempURL=url;self.completion=completion
            firstFrameDeadline=Task{[weak self,weak stream,weak movie] in
                do{try await Task.sleep(nanoseconds:10_000_000_000)}catch{return}
                guard let self,self.sessionID == token,self.firstFrameDeadline != nil else{return}
                movie?.abort();self.finish(.failure(CaptureFailure.message(L("10 秒内未收到首个可用视频帧，已取消录屏，请重试。"))))
                if let stream {try? await stream.stopCapture()}
            }
            try await stream.startCapture()
        }catch{
            movie.abort();guard sessionID == token else{return};firstFrameDeadline?.cancel();firstFrameDeadline=nil;self.stream=nil;self.movie=nil;self.completion=nil;tempURL=nil;sessionID=UUID();throw error
        }
    }
    func stop() async throws {
        guard let stream,let movie,!stopping else{return};stopping=true
        let token=sessionID;firstFrameDeadline?.cancel();firstFrameDeadline=nil
        do{
            try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
                recordingStopDeadline.start(seconds:8,operation:{try await stream.stopCapture()},completion:{continuation.resume(with:$0)})
            }
        }catch{if token == sessionID {movie.abort();finish(.failure(error))};return}
        guard token == sessionID else{return}
        do{
            let original=try await movie.finish();guard token == sessionID else{return}
            let url=needsAudioMix ? try await RecordingAudioMixdown.mix(original) : original
            guard token == sessionID else{return}
            if url != original {try? FileManager.default.removeItem(at:original)}
            finish(.success(url))
        }
        catch{guard token == sessionID else{return};finish(.failure(error))}
    }
    private func writerFailed(_ error:Error) async {
        guard let stream,!stopping else{return}
        movie?.abort();finish(.failure(error))
        // The UI/session are released first. A stuck old OS stop cannot block a retry.
        try? await stream.stopCapture()
    }
    private func finish(_ result:Result<URL,Error>){
        guard let callback=completion else{return}
        firstFrameDeadline?.cancel();firstFrameDeadline=nil;completion=nil;stream=nil;movie=nil;tempURL=nil;stopping=false;needsAudioMix=false;sessionID=UUID();callback(result)
    }
    nonisolated func stream(_ stream:SCStream,didStopWithError error:Error){
        Task{@MainActor in guard self.stream === stream else{return};self.movie?.abort();self.finish(.failure(error))}
    }
}
