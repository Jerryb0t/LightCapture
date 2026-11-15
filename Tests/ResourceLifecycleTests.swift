import AppKit
@main struct ResourceLifecycleTests {
 @MainActor static func main() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let delegate=AppDelegate();delegate.buildUI()
  precondition(delegate.buttons.contains{$0.title == "全屏截图" && $0.action == #selector(AppDelegate.fullScreenshot)})
  precondition(delegate.buttons.contains{$0.title == "区域 / 窗口截图"})
  precondition(delegate.buttons.count == 5)
  print("PASS five focused capture actions include full screenshot")
  weak var releasedContent:NSView?
  autoreleasepool {
   let panel=NSPanel(contentRect:.zero,styleMask:[],backing:.buffered,defer:true)
   panel.isReleasedWhenClosed=false
   let content=NSView();releasedContent=content;panel.contentView=content
   delegate.control=panel;delegate.longLabel=NSTextField(labelWithString:"test")
   delegate.dismissControls()
   precondition(panel.contentView == nil && delegate.control == nil && delegate.longLabel == nil)
  }
  precondition(releasedContent == nil)
  print("PASS control content and label released on dismissal")
  let selector=SelectionController();selector.cancel();selector.cancel()
  precondition(!delegate.recorder.active && delegate.composite == nil && !delegate.longSampler.active && !delegate.longSampler.inFlight)
  print("PASS inactive capture has no stream, composite, or sampling task; cancel idempotent")
 }
}
