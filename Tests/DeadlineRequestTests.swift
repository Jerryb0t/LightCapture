import Foundation
@main struct DeadlineRequestTests {
 @MainActor static func main() async throws {
  let request=DeadlineRequest<Int>();var hung:CheckedContinuation<Int,Never>?
  var events:[String]=[]
  let start=ProcessInfo.processInfo.systemUptime
  request.start(seconds:0.05,operation:{await withCheckedContinuation{hung=$0}}){result in
   if case .failure = result{events.append("timeout")}
  }
  try await Task.sleep(nanoseconds:120_000_000)
  precondition(events == ["timeout"] && !request.pending)
  precondition(ProcessInfo.processInfo.systemUptime-start < 1)
  print("PASS uncooperative pending continuation does not block timeout or interaction")
  request.start(seconds:0.5,operation:{7}){result in if case .success(7)=result{events.append("retry")}}
  try await Task.sleep(nanoseconds:30_000_000)
  hung?.resume(returning:99);hung=nil
  try await Task.sleep(nanoseconds:30_000_000)
  precondition(events == ["timeout","retry"] && !request.pending)
  print("PASS retry succeeds; stale timed-out result cannot deliver")
  var cancelled:CheckedContinuation<Int,Never>?
  request.start(seconds:0.05,operation:{await withCheckedContinuation{cancelled=$0}}){_ in events.append("bad-cancel")}
  try await Task.sleep(nanoseconds:10_000_000);request.cancel();request.cancel()
  cancelled?.resume(returning:1);cancelled=nil
  try await Task.sleep(nanoseconds:70_000_000)
  precondition(events == ["timeout","retry"])
  print("PASS explicit cancel is idempotent and rejects operation/deadline completion")
  var delivered=0
  for _ in 0..<20 {
   request.start(seconds:0.01,operation:{try? await Task.sleep(nanoseconds:10_000_000);return 3}){_ in delivered += 1}
   try await Task.sleep(nanoseconds:25_000_000)
  }
  precondition(delivered == 20 && !request.pending)
  print("PASS deadline/worker race delivers exactly once across 20 iterations")
  var replaced:CheckedContinuation<Int,Never>?
  request.start(seconds:0.5,operation:{await withCheckedContinuation{replaced=$0}}){_ in events.append("bad-replace")}
  try await Task.sleep(nanoseconds:10_000_000)
  request.start(seconds:0.5,operation:{8}){_ in events.append("replacement")}
  replaced?.resume(returning:2);replaced=nil
  try await Task.sleep(nanoseconds:30_000_000)
  precondition(events == ["timeout","retry","replacement"])
  print("PASS new session invalidates prior worker and timer")
 }
}
