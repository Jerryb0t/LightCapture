import AppKit
@main struct SelectionInteractionTests {
 @MainActor static func main() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  var passed=0
  func check(_ condition:Bool,_ name:String){precondition(condition,name);passed += 1;print("PASS \(name)")}
  func mouse(_ type:NSEvent.EventType,_ p:CGPoint,_ window:NSWindow)->NSEvent {
   NSEvent.mouseEvent(with:type,location:p,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  }
  func key(_ code:UInt16,_ window:NSWindow)->NSEvent {
   NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
  }
  func setup()->(SelectionWindow,SelectionView) {
   let w=SelectionWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:.borderless,backing:.buffered,defer:true)
   w.isReleasedWhenClosed=false
   let v=SelectionView(frame:NSRect(x:0,y:0,width:900,height:650));w.contentView=v
   return(w,v)
  }
  func controls(_ v:NSView)->[NSButton]{v.subviews.flatMap{ child in (child as? NSButton).map{[$0]} ?? controls(child)}}
  let (w,v)=setup();defer{w.close()}
  var completions=0;var output:CGRect?
  v.finished={rect,_,_ in completions += 1;output=rect}
  let buttons=controls(v)
  let confirm=buttons.first{$0.title == "确认 ↩"}!,cancel=buttons.first{$0.title == "取消 Esc"}!
  check(!confirm.isEnabled && cancel.isEnabled && !cancel.isHidden && v.bounds.contains(cancel.frame),"cancel visible before selection, confirm disabled")
  check(v.acceptsFirstMouse(for:nil) && w.canBecomeKey && w.makeFirstResponder(v),"first click accepted and selection can receive keyboard")
  v.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:70,y:80),w));v.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:350,y:280),w));v.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:350,y:280),w))
  check(completions == 0 && confirm.isEnabled && v.pendingRect == CGRect(x:70,y:80,width:280,height:200),"release freezes selection and exposes confirmation, no premature capture")
  v.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:100,y:100),w));v.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:100,y:100),w))
  check(v.pendingRect == CGRect(x:70,y:80,width:280,height:200),"single click does not erase frozen selection")
  v.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:100,y:100),w));v.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:400,y:400),w));v.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:400,y:400),w))
  check(v.pendingRect == CGRect(x:100,y:100,width:300,height:300),"second drag replaces selection")
  _=w.makeFirstResponder(cancel)
  check(w.performKeyEquivalent(with:key(36,w)) && completions == 1 && output == v.pendingRect,"Enter confirms with toolbar focus")
  v.confirmSelection();v.cancelSelection()
  check(completions == 1,"completion is one-shot")
  let (w2,v2)=setup();defer{w2.close()};var cancelled=0
  v2.finished={rect,_,_ in if rect == nil{cancelled += 1}}
  _=w2.makeFirstResponder(v2.subviews.last)
  check(w2.performKeyEquivalent(with:key(53,w2)) && cancelled == 1,"Escape cancels from toolbar before selection")
  v2.cancelSelection();check(cancelled == 1,"repeat cancel remains one-shot")
  let (w3,v3)=setup();defer{w3.close()};var clicked=0
  v3.finished={rect,_,_ in if rect == nil{clicked += 1}}
  let cancel3=controls(v3).first{$0.title == "取消 Esc"}!
  _=NSApplication.shared.sendAction(cancel3.action!,to:cancel3.target,from:cancel3)
  check(clicked == 1,"visible cancel button action works")
  let (w4,v4)=setup();defer{w4.close()};var confirmedClick=0
  v4.finished={rect,_,_ in if rect != nil{confirmedClick += 1}}
  v4.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:30,y:50),w4));v4.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:230,y:250),w4))
  let confirm4=controls(v4).first{$0.title == "确认 ↩"}!
  _=NSApplication.shared.sendAction(confirm4.action!,to:confirm4.target,from:confirm4)
  check(confirmedClick == 1 && v4.bounds.contains(confirm4.frame),"clickable confirm action and initial frame work")
  let (w5,v5)=setup();defer{w5.close()};var cancelAfterDrag=0
  v5.finished={rect,_,_ in if rect == nil{cancelAfterDrag += 1}}
  v5.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:30,y:50),w5));v5.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:230,y:250),w5))
  v5.keyDown(with:key(53,w5));check(cancelAfterDrag == 1,"Escape cancels frozen selection")
  let (w6,v6)=setup();defer{w6.close()};var annotate=false
  v6.finished={rect,_,edit in annotate=rect != nil && edit}
  v6.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:20,y:5),w6));v6.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:300,y:180),w6))
  let annotate6=controls(v6).first{$0.title == "标注…"}!
  let toolbar=annotate6.superview!
  check(v6.bounds.contains(toolbar.frame) && toolbar.frame.minY >= v6.pendingRect!.maxY,"toolbar flips above low selection and stays on screen")
  _=NSApplication.shared.sendAction(annotate6.action!,to:annotate6.target,from:annotate6)
  check(annotate,"explicit annotation route distinct from confirm")
  let (w7,v7)=setup();defer{w7.close()}
  v7.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:400,y:300),w7));v7.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:800,y:500),w7))
  let locked=v7.pendingRect
  v7.setMode(.recording);check(v7.pendingRect == locked && v7.selectedMode == .recording,"mode switch preserves selection")
  let bar7=controls(v7).first{$0.title == "确认 ↩"}!.superview!
  check(v7.bounds.contains(bar7.frame) && bar7.frame.maxY < locked!.minY,"toolbar anchored below selection")
  let cancel7=controls(v7).first{$0.title == "取消 Esc"}!
  let hitPoint=v7.convert(CGPoint(x:cancel7.bounds.midX,y:cancel7.bounds.midY),from:cancel7)
  check(v7.hitTest(hitPoint) === cancel7,"toolbar hit testing reaches actual cancel button")
  let (w8,v8)=setup();defer{w8.close()};var doubleConfirmed=0
  v8.finished={rect,_,_ in if rect != nil{doubleConfirmed += 1}}
  v8.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:40,y:60),w8));v8.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:300,y:300),w8))
  let double=NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:100,y:100),modifierFlags:[],timestamp:0,windowNumber:w8.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:1)!
  v8.mouseDown(with:double);v8.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:100,y:100),w8))
  check(doubleConfirmed == 1,"double-click fixed region confirms once")
  print("\(passed) selection tests passed; no posted input or screen capture")
 }
}
