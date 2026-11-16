import AppKit
@main struct LongSelectionFlowTests {
 @MainActor static func main(){
  NSApplication.shared.setActivationPolicy(.prohibited)
  func check(_ value:Bool,_ message:String){if !value{fputs("FAIL: "+message+"\n",stderr);exit(1)}}
  func event(_ type:NSEvent.EventType,_ point:CGPoint,_ window:NSWindow)->NSEvent{NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
  let w=SelectionWindow(contentRect:CGRect(x:0,y:0,width:900,height:700),styleMask:.borderless,backing:.buffered,defer:true);w.isReleasedWhenClosed=false;defer{w.close()}
  let view=SelectionView(frame:CGRect(x:0,y:0,width:900,height:700));w.contentView=view
  view.setMode(.longScreenshot)
  var starts=0;var rect:CGRect?
  view.finished={selected,_,_ in starts += 1;rect=selected;w.orderOut(nil)}
  view.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100),w));view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:600,y:550),w));view.mouseUp(with:event(.leftMouseUp,CGPoint(x:600,y:550),w))
  check(starts==1 && rect==CGRect(x:100,y:100,width:500,height:450),"long mode begins immediately on completed drag")
  view.confirmSelection();check(starts==1,"auto-begin is one-shot")
  let second=SelectionView(frame:view.frame);w.contentView=second;var switched=0
  second.finished={_,_,_ in switched += 1}
  second.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100),w));second.mouseUp(with:event(.leftMouseUp,CGPoint(x:600,y:550),w));check(switched==0,"screenshot retains confirmation")
  second.setMode(.longScreenshot);check(switched==1,"switching locked viewport to long capture removes extra confirmation stage")
  let blocked=SelectionView(frame:view.frame);w.contentView=blocked;blocked.setMode(.longScreenshot)
  var blockedStarts=0;blocked.beforeLongStart={"Keys unavailable"};blocked.finished={_,_,_ in blockedStarts += 1}
  blocked.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100),w));blocked.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:600,y:550),w));blocked.mouseUp(with:event(.leftMouseUp,CGPoint(x:600,y:550),w))
  check(blockedStarts==0 && blocked.pendingRect != nil && blocked.notice=="Keys unavailable","key registration failure preserves selection")
  blocked.beforeLongStart={nil};blocked.confirmSelection();check(blockedStarts==1,"retry after key availability completes once")
  let border=LongCaptureBorder();border.close();check(border.panel==nil,"inactive border owns no window")
  check(LongCaptureBorder.frame(capture:CGRect(x:100,y:100,width:300,height:200),screen:CGRect(x:0,y:0,width:900,height:700))==CGRect(x:98,y:98,width:304,height:204),"border grows outside capture")
  check(LongCaptureBorder.frame(capture:CGRect(x:0,y:0,width:900,height:700),screen:CGRect(x:0,y:0,width:900,height:700))==CGRect(x:0,y:0,width:900,height:700),"full screen border clamps")
  let borderSource=try! String(contentsOfFile:"Sources/LongCaptureBorder.swift",encoding:.utf8)
  check(borderSource.contains("ignoresMouseEvents=true") && borderSource.contains(".nonactivatingPanel") && !borderSource.contains("makeKey"),"marker is pointer transparent and nonactivating")
  let source=try! String(contentsOfFile:"Sources/App.swift",encoding:.utf8)
  check(source.contains("selector.cancel(notify:false)") && source.contains("captureSourceApplication?.activate(options:[])"),"long capture teardown restores source focus")
  let start=source.range(of:"    func showLongControls(){")!.lowerBound;let end=source.range(of:"    func dismissControls(){")!.lowerBound
  check(!source[start..<end].contains("NSPanel") && !source[start..<end].contains("NSButton"),"no live control panel")
  let scroll=NSScrollView(frame:CGRect(x:0,y:0,width:500,height:450));let page=NSView(frame:CGRect(x:0,y:0,width:500,height:3000));scroll.documentView=page
  scroll.contentView.scroll(to:CGPoint(x:0,y:250));check(scroll.contentView.bounds.origin.y==250,"source scroll view remains independently scrollable after selection completed")
  check(!w.isVisible,"offscreen only")
  print("PASS long drag/switch enters live session without second overlay confirmation; screenshot unaffected; source scroll view moves; no global keys/screen capture/permissions")
 }
}
