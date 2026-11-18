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
  let delegate=AppDelegate()
  delegate.visibility.setPolicy={policies.append($0)};delegate.visibility.deactivate={deactivations += 1}
  delegate.visibility.start(login:true)
  delegate.buildMenu()
  precondition(delegate.window == nil && delegate.buttons.isEmpty && delegate.captureShortcutAction == .capture)
  delegate.updateRecordingControls(.recording)
  precondition(delegate.window == nil && delegate.captureShortcutAction == .stop && delegate.stopMenuItems.first?.isEnabled == true)
  weak var originalWindow:NSWindow?
  weak var originalContent:NSView?
  autoreleasepool {
   delegate.buildUI()
   precondition(delegate.mainStopButton.isEnabled && !delegate.mainStopButton.isHidden)
   originalWindow=delegate.window;originalContent=delegate.window.contentView
   precondition(!delegate.windowShouldClose(delegate.window) && delegate.window == nil && delegate.visibility.background)
  }
  precondition(originalWindow == nil && originalContent == nil)
  precondition(delegate.stopMenuItems.first?.isEnabled == true && delegate.captureShortcutAction == .stop)
  delegate.setBusy(true);delegate.setBusy(false)
  precondition(delegate.window == nil && delegate.visibility.background && policies.last == .accessory)
  delegate.updateRecordingControls(.idle)
  delegate.buildUI();delegate.buildUI()
  precondition(delegate.buttons.count == 5 && delegate.mainStopButton.isHidden && delegate.captureShortcutAction == .capture)
  print("PASS no settings window during background launch and recording; red close releases window/content, preserves stop shortcut/menu, rebuilds controls once")
 }
}
