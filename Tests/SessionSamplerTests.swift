import Foundation
@main struct SessionSamplerTests {
 @MainActor static func main() async throws {
  let sampler=SessionSampler<Int>(interval:0.05)
  var operations=0,active=0,peak=0,received=0
  func begin() {
   sampler.start(operation:{
    operations += 1;active += 1;peak=max(peak,active)
    try await Task.sleep(nanoseconds:150_000_000)
    active -= 1;return operations
   },receive:{_ in received += 1},failure:{_ in fatalError("unexpected error")})
  }
  precondition(!sampler.active && !sampler.inFlight)
  begin();sampler.sample()
  for _ in 0..<30 {sampler.sample()}
  try await Task.sleep(nanoseconds:20_000_000)
  precondition(operations == 1 && peak == 1)
  sampler.stop() // preview/cancel invalidate pending completion
  try await Task.sleep(nanoseconds:190_000_000)
  precondition(received == 0 && !sampler.inFlight && !sampler.active)
  let stoppedCount=operations
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(operations == stoppedCount)
  print("PASS one in-flight, repeated click coalescing, stop rejects late frame, idle no sampling")
  begin();sampler.sample()
  try await Task.sleep(nanoseconds:20_000_000)
  sampler.stop();begin();sampler.sample()
  try await Task.sleep(nanoseconds:360_000_000)
  sampler.stop()
  precondition(peak == 1 && received >= 1)
  print("PASS restart cannot overlap old capture; new session receives valid frame")
  while sampler.inFlight {try await Task.sleep(nanoseconds:10_000_000)}
  let drain=SessionSampler<Int>(interval:0.05);var applied=0
  drain.start(operation:{try await Task.sleep(nanoseconds:100_000_000);return 1},receive:{applied += $0},failure:{_ in exit(1)})
  drain.sample();drain.pause();try await Task.sleep(nanoseconds:180_000_000)
  guard applied==1 && !drain.inFlight else{print("FAIL pause discarded in-flight frame");exit(1)}
  try await Task.sleep(nanoseconds:100_000_000);guard applied==1 else{exit(1)};drain.stop()
  print("PASS finish pause drains current frame once without scheduling another")
  let hung=SessionSampler<Int>(interval:0.05);var timeouts=0,late=0
  hung.start(operation:{try await Task.sleep(nanoseconds:9_000_000_000);return 1},receive:{_ in late += 1},failure:{_ in timeouts += 1;hung.stop()})
  hung.sample();try await Task.sleep(nanoseconds:8_200_000_000)
  guard timeouts==1 && !hung.active && hung.inFlight else{print("FAIL timeout/barrier");exit(1)}
  for _ in 0..<100 { if !hung.inFlight {break};try await Task.sleep(nanoseconds:50_000_000) }
  guard !hung.inFlight && late==0 else{print("FAIL stale timeout result");exit(1)}
  print("PASS bounded timeout cancels session, keeps physical in-flight barrier, rejects late result")
 }
}
