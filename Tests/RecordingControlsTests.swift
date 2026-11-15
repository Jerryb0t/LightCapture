import AppKit
@main struct RecordingControlsTests {
 @MainActor static func main(){
  NSApplication.shared.setActivationPolicy(.prohibited)
  let delegate=AppDelegate();delegate.buildUI()
  let menuItem=NSMenuItem(title:"停止并保存录屏",action:#selector(AppDelegate.stopRecording),keyEquivalent:"");menuItem.target=delegate
  precondition(delegate.mainStopButton.action == #selector(AppDelegate.stopRecording))
  precondition(delegate.mainStopButton.accessibilityLabel() == "停止并保存录屏")
  precondition(delegate.mainStopButton.isHidden && !delegate.mainStopButton.isEnabled && !delegate.validateMenuItem(menuItem))
  print("PASS accessible main-window stop action; hidden/disabled idle, menu disabled")
  delegate.updateRecordingControls(.starting)
  precondition(!delegate.mainStopButton.isHidden && !delegate.mainStopButton.isEnabled && !delegate.validateMenuItem(menuItem))
  delegate.updateRecordingControls(.recording)
  precondition(!delegate.mainStopButton.isHidden && delegate.mainStopButton.isEnabled && delegate.validateMenuItem(menuItem))
  print("PASS preparation disabled; active recording exposes enabled main-window and menu stop")
  delegate.stopPending=true;delegate.updateRecordingControls(.stopping)
  precondition(!delegate.mainStopButton.isHidden && !delegate.mainStopButton.isEnabled && !delegate.validateMenuItem(menuItem))
  print("PASS stopping blocks repeated main-window/menu requests")
  delegate.stopPending=false;delegate.updateRecordingControls(.recording)
  precondition(delegate.mainStopButton.isEnabled && delegate.validateMenuItem(menuItem))
  delegate.updateRecordingControls(.idle)
  precondition(delegate.mainStopButton.isHidden && !delegate.mainStopButton.isEnabled)
  delegate.updateRecordingControls(.starting);delegate.updateRecordingControls(.recording)
  precondition(delegate.mainStopButton.isEnabled)
  print("PASS retry after stop failure, idle completion, next recording reset state")
  precondition(!delegate.window.isVisible)
  print("PASS control updates never reveal settings window or launch recording")
 }
}
