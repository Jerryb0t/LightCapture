import AppKit
import ServiceManagement
import Carbon
@MainActor final class FakeLogin:LoginItemManaging {
 var status:SMAppService.Status = .notRegistered
 var enables=0;var disables=0
 func enable() throws{enables += 1;status = .enabled}
 func disable() async throws{disables += 1;status = .notRegistered}
}
@main struct LoginBackgroundTests {
 @MainActor static func main() {
  setbuf(stdout,nil)
  NSApplication.shared.setActivationPolicy(.prohibited)
  let app=AppDelegate(),fake=FakeLogin();app.loginItem=fake;app.visibility.setPolicy={_ in};app.visibility.deactivate={};app.buildUI()
  precondition(fake.enables==0 && fake.disables==0 && app.loginCheckbox.state == .off)
  for status:SMAppService.Status in [.enabled,.requiresApproval,.notRegistered,.notFound]{fake.status=status;app.refreshLoginItem();precondition(app.loginCheckbox.state == LoginLaunch.presentation(status).0)}
  print("PASS login state rendering, no registration on launch/refresh (injected service)")
  app.loginCheckbox.state = .on;app.toggleLoginItem();RunLoop.current.run(until:Date().addingTimeInterval(0.05));precondition(fake.enables==1 && app.loginCheckbox.state == .on)
  app.loginCheckbox.state = .off;app.toggleLoginItem();RunLoop.current.run(until:Date().addingTimeInterval(0.05));precondition(fake.disables==1 && app.loginCheckbox.state == .off)
  print("PASS enable/disable via injected fake only; no actual OS login-item changes")
  precondition(app.windowShouldClose(app.window)==false && app.window == nil)
  precondition(!app.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
  print("PASS red close hides, no last-window termination")
  precondition(app.captureShortcutAction == .capture)
  app.busy=true;app.updateRecordingControls(.starting);precondition(app.captureShortcutAction == .ignore)
  app.updateRecordingControls(.recording);precondition(app.captureShortcutAction == .stop)
  app.stopPending=true;precondition(app.captureShortcutAction == .ignore)
  app.stopPending=false;app.updateRecordingControls(.stopping);precondition(app.captureShortcutAction == .ignore)
  app.updateRecordingControls(.idle);app.busy=false;precondition(app.captureShortcutAction == .capture)
  print("PASS hotkey routes idle capture / active stop / starting and stopping ignore")
  precondition(!LoginLaunch.isLoginEvent(nil))
  let event=NSAppleEventDescriptor(eventClass:AEEventClass(kCoreEventClass),eventID:AEEventID(kAEOpenApplication),targetDescriptor:nil,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
  precondition(!LoginLaunch.isLoginEvent(event));event.setParam(NSAppleEventDescriptor(boolean:true),forKeyword:AEKeyword(keyAELaunchedAsLogInItem));precondition(LoginLaunch.isLoginEvent(event))
  print("PASS only actual login launch event suppresses startup window; manual open unaffected")
 }
}
