import Foundation
@main struct CaptureDiagnosticsTests {
 static func main(){
  for _ in 0..<100 {CaptureDiagnostics.record(.mouseDown)}
  CaptureDiagnostics.record(.saveFailed,error:NSError(domain:"private-path-or-user-text",code:42,userInfo:[NSLocalizedDescriptionKey:"secret"] ))
  let trace=CaptureDiagnostics.snapshot()
  precondition(trace.split(separator:"\n").count == 64)
  precondition(!trace.contains("private-path") && !trace.contains("secret"))
  precondition(trace.contains("saveFailed domain=other code=42"))
  print("PASS diagnostic history bounded; arbitrary domain/description excluded")
 }
}
