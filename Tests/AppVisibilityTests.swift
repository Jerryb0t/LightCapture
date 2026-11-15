import AppKit
@main struct AppVisibilityTests {
 @MainActor static func main(){
  let visibility=AppVisibility();var policies:[NSApplication.ActivationPolicy]=[];var deactivations=0
  visibility.setPolicy={policies.append($0)};visibility.deactivate={deactivations += 1}
  visibility.start(login:false);precondition(!visibility.background && policies == [.regular])
  visibility.hide();precondition(visibility.background && policies.last == .accessory && deactivations==1)
  visibility.finished();precondition(policies == [.regular,.accessory] && deactivations==2)
  visibility.reopen();visibility.reopen();precondition(!visibility.background && policies.suffix(2)==[.regular,.regular])
  visibility.finished();precondition(deactivations==2)
  visibility.start(login:true);precondition(visibility.background && policies.last == .accessory)
  visibility.finished();precondition(deactivations==3)
  print("PASS manual launch regular; close accessory/deactivate; capture completion never promotes; repeated reopen regular; login accessory")
  NSApplication.shared.setActivationPolicy(.prohibited)
  let delegate=AppDelegate();delegate.visibility.setPolicy={policies.append($0)};delegate.visibility.deactivate={deactivations += 1};delegate.buildUI()
  precondition(!delegate.windowShouldClose(delegate.window) && !delegate.window.isVisible && delegate.visibility.background)
  delegate.setBusy(true);delegate.setBusy(false);precondition(delegate.visibility.background && policies.last == .accessory)
  delegate.updateRecordingControls(.recording);precondition(delegate.captureShortcutAction == .stop)
  print("PASS main red close hides while preserving recording-stop routing; finish stays hidden; no OS policy changes in test doubles")
 }
}
