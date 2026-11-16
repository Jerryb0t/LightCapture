import CoreGraphics
import Foundation

/// Coordinates one explicit selection until Enter/Esc. Frame sources and output are
/// injected so the real lifecycle can be tested without permission or capturing a desktop.
@MainActor final class LongCaptureSession {
    typealias FrameSource = @MainActor () async throws -> CGImage
    typealias Prepare = @MainActor () async throws -> FrameSource
    enum Failure: LocalizedError {
        case noGrowth
        var errorDescription:String? { L("没截到新内容：请重试，向下滚动再按 Enter。") }
    }

    private let sampler = SessionSampler<LongFrameResult>(interval:0.12)
    private let initial = DeadlineRequest<FrameSource>()
    private let final = DeadlineRequest<LongFrameResult>()
    private var source:FrameSource?
    private var completed:((Result<CGImage,Error>,CGImage?)->Void)?
    private var signature:Data?
    private var allowFixedWindowBands=false
    private var initialHeight:Int?
    private var captureInFlight=false
    private var finishRequested=false
    private var finishing=false
    private(set) var composite:CGImage?
    var active:Bool {completed != nil}
    var draining:Bool {captureInFlight || sampler.inFlight}

    func start(seed:CGImage?, allowFixedWindowBands:Bool=false, prepare:@escaping Prepare,
               completion:@escaping (Result<CGImage,Error>,CGImage?)->Void) {
        guard !active,!draining else{return}
        completed=completion
        self.allowFixedWindowBands=allowFixedWindowBands
        if let seed {
            do{try setBaseline(seed)}catch{complete(.failure(error));return}
        }
        initial.start(seconds:8,operation:prepare){[weak self] result in
            guard let self,self.active else{return}
            switch result {
            case .failure(let error):self.complete(.failure(error))
            case .success(let source):
                self.source=source
                if self.composite != nil {self.ready()}
                else {self.captureBaseline(source)}
            }
        }
    }

    private func captureBaseline(_ source:@escaping FrameSource){
        baseline.start(seconds:8,operation:{[weak self] in
            guard let self else{throw CancellationError()}
            return try await self.capture(using:source)
        }){[weak self] result in
            guard let self,self.active else{return}
            do {try self.setBaseline(result.get());self.ready()}
            catch {self.complete(.failure(error))}
        }
    }
    private let baseline=DeadlineRequest<CGImage>()
    private func setBaseline(_ image:CGImage)throws{
        signature=try LongFrameProcessor.signature(image)
        composite=image;initialHeight=image.height;CaptureDiagnostics.record(.longBaseline)
    }
    private func ready(){
        if finishRequested {finish();return}
        sampler.start(operation:{[weak self] in
            guard let self else{throw CancellationError()}
            return try await self.processNext()
        },receive:{[weak self] frame in self?.apply(frame)},failure:{[weak self] error in
            guard let self else{return}
            if let stitch=error as? StitchError {
                switch stitch{case .noOverlap,.ambiguousOverlap:CaptureDiagnostics.record(.longNoOverlap,error:stitch);return
                default:break}
            }
            self.complete(.failure(error))
        })
        sampler.sample()
    }
    private func capture(using source:FrameSource) async throws -> CGImage {
        try Task.checkCancellation()
        guard !captureInFlight else{throw CancellationError()}
        captureInFlight=true
        defer{captureInFlight=false}
        return try await source()
    }
    private func processNext() async throws -> LongFrameResult {
        guard let previous=composite,let source else{throw CancellationError()}
        let image=try await capture(using:source), currentSignature=signature
        let fixedBands=allowFixedWindowBands
        try Task.checkCancellation()
        return try await Task.detached(priority:.userInitiated){
            try LongFrameProcessor.process(previous:previous,next:image,lastSignature:currentSignature,allowFixedWindowBands:fixedBands)
        }.value
    }
    private func apply(_ frame:LongFrameResult){
        signature=frame.signature
        if frame.stitch.addedRows>0{composite=frame.stitch.image;CaptureDiagnostics.record(.longExtended)}
    }

    func finish(){
        guard active,!finishing else{return}
        finishRequested=true
        guard source != nil,composite != nil else{return}
        finishing=true;sampler.pause()
        final.start(seconds:8,operation:{[weak self] in
            guard let self else{throw CancellationError()}
            while self.sampler.inFlight{try await Task.sleep(nanoseconds:15_000_000);try Task.checkCancellation()}
            self.sampler.stop()
            return try await self.processNext()
        }){[weak self] result in
            guard let self,self.active else{return}
            switch result {
            case .success(let frame):
                self.apply(frame)
                if let image=self.composite,let height=self.initialHeight,image.height>height {
                    CaptureDiagnostics.record(.longFinished);self.complete(.success(image))
                }else{self.complete(.failure(Failure.noGrowth))}
            case .failure(let error):self.complete(.failure(error))
            }
        }
    }

    func fail(_ error:Error){if active{complete(.failure(error))}}

    func cancel(){
        initial.cancel();baseline.cancel();final.cancel();sampler.stop()
        completed=nil;source=nil;signature=nil;composite=nil;initialHeight=nil
        finishing=false;finishRequested=false;allowFixedWindowBands=false
    }
    private func complete(_ result:Result<CGImage,Error>){
        let completion=completed
        let partial=(composite?.height ?? 0) > (initialHeight ?? 0) ? composite : nil
        cancel()
        completion?(result,partial)
    }
}
