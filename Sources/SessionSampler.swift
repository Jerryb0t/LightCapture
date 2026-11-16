import Foundation

/// Exists only during an explicitly started capture session. Never queues frames.
@MainActor final class SessionSampler<Value> {
    private var ticker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var accepting=false
    private var deadline:Task<Void,Never>?
    enum SamplingFailure:LocalizedError {case timeout
        var errorDescription:String? {L("屏幕采样超时，本次长截图已取消。请稍后重试；若仍失败，请退出后重开轻截。")}
    }
    private var operation: (() async throws -> Value)?
    private var receive: ((Value) -> Void)?
    private var failure: ((Error) -> Void)?
    private var lastStart = -Double.infinity
    private let interval: Double
    private(set) var inFlight = false
    var active: Bool { accepting }
    init(interval: Double = 0.8) { self.interval = max(0.05, interval) }
    func start(operation: @escaping () async throws -> Value, receive: @escaping (Value) -> Void, failure: @escaping (Error) -> Void) {
        stop()
        accepting=true
        self.operation = operation; self.receive = receive; self.failure = failure
        ticker = Task { [weak self, interval] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }
    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        guard active, !inFlight, now-lastStart >= interval, let operation else { return }
        lastStart = now; inFlight = true
        let token = generation
        deadline=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:8_000_000_000)}catch{return}
            guard let self,self.generation==token,self.active,self.inFlight else{return}
            self.failure?(SamplingFailure.timeout)
        }
        Task { [weak self] in
            let result: Result<Value, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            guard let self else { return }
            self.deadline?.cancel();self.deadline=nil
            self.inFlight = false
            guard token == self.generation, self.active else { return }
            switch result { case .success(let value): self.receive?(value); case .failure(let error): self.failure?(error) }
        }
    }
    /// Stop scheduling but allow the one already captured frame to be applied.
    func pause(){ticker?.cancel();ticker=nil}
    func stop() {
        generation &+= 1;accepting=false;deadline?.cancel();deadline=nil;ticker?.cancel(); ticker = nil
        operation = nil; receive = nil; failure = nil
        // Keep inFlight until the old operation settles. A restart cannot overlap it.
    }
    deinit { ticker?.cancel();deadline?.cancel() }
}
