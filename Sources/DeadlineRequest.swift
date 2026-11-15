import Foundation

/// Unstructured worker + independent deadline: never awaits cancellation of a hung API.
/// Result delivery is generation-gated; late results cannot mutate a retry/session.
@MainActor final class DeadlineRequest<Value> {
    enum Failure:LocalizedError {case timeout
        var errorDescription:String? {L("系统屏幕服务响应超时，已取消本次操作。可以重试；若仍超时，请退出后重新打开轻截。")}
    }
    private var worker:Task<Void,Never>?
    private var deadline:Task<Void,Never>?
    private var generation:UInt64=0
    private var completion:((Result<Value,Error>)->Void)?
    var pending:Bool {completion != nil}
    func start(seconds:Double,operation:@escaping () async throws -> Value,completion:@escaping(Result<Value,Error>)->Void){
        cancel();let token=generation;self.completion=completion
        worker=Task{[weak self] in
            let result:Result<Value,Error>
            do{result = .success(try await operation())}catch{result = .failure(error)}
            self?.resolve(token:token,result:result)
        }
        deadline=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:UInt64(max(0.01,seconds)*1_000_000_000))}catch{return}
            self?.resolve(token:token,result:.failure(Failure.timeout))
        }
    }
    private func resolve(token:UInt64,result:Result<Value,Error>){
        guard token == generation,let callback=completion else{return}
        cancel();callback(result)
    }
    func cancel(){
        generation &+= 1;completion=nil;worker?.cancel();worker=nil;deadline?.cancel();deadline=nil
    }
    deinit{worker?.cancel();deadline?.cancel()}
}
