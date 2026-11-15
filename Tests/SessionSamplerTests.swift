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
 }
}
