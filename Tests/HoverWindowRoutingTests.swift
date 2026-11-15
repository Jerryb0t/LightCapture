import AppKit
@main struct HoverWindowRoutingTests {
 @MainActor static func main(){
  NSApplication.shared.setActivationPolicy(.prohibited)
  func check(_ condition:Bool,_ message:String){if !condition{fputs("FAIL: "+message+"\n",stderr);exit(1)}}
  let screen=CGRect(x:0,y:0,width:1000,height:700)
  func info(_ id:UInt32,_ frame:CGRect,_ layer:Int)->[String:Any]{[kCGWindowNumber as String:id,kCGWindowBounds as String:frame.dictionaryRepresentation,kCGWindowLayer as String:layer,kCGWindowOwnerPID as String:42,kCGWindowOwnerName as String:"Synthetic System UI"]}
  let popup=CGRect(x:700,y:40,width:220,height:180)
  let normal=CGRect(x:100,y:150,width:600,height:450)
  let records=[SnapWindowRecord(id:3,frame:normal,layer:0,alpha:1,owner:"Synthetic Editor",pid:43,onScreen:true)]
  let candidates=WindowSnapCandidates.make(order:[info(1,popup,25),info(2,screen,25)],fallback:records,screen:screen,primaryHeight:700,ownPID:99)
  let fallbackCarrier=SnapWindowRecord(id:4,frame:screen,layer:25,alpha:1,owner:"Synthetic Carrier",pid:44,onScreen:true)
  let fallbackOnly=WindowSnapCandidates.make(order:[],fallback:[fallbackCarrier]+records,screen:screen,primaryHeight:700,ownPID:99)
  check(fallbackOnly.map{$0.1}==[3],"fallback preserves actual elevated layer and rejects carrier while retaining ordinary window")
  check(candidates.map{$0.1}==[1,3],"screen carrier removed while sparse-Quartz normal fallback retained")
  check(WindowSnapPolicy.permits(layer:0,alpha:1,frame:screen,displayBounds:screen,owner:"Editor",isOwn:false),"ordinary fullscreen app still eligible")
  let w=SelectionWindow(contentRect:screen,styleMask:.borderless,backing:.buffered,defer:true)
  w.isReleasedWhenClosed=false;defer{w.close()}
  let v=SelectionView(frame:screen);w.contentView=v
  v.candidates=candidates.map{($0.0,nil)}
  // Deliberately do not activate/order the window or build tracking areas.
  // Exercise real window-local dispatch, not direct assignment to hovered.
  func move(_ p:CGPoint){
   guard let e=NSEvent.mouseEvent(with:.mouseMoved,location:p,modifierFlags:[],timestamp:0,windowNumber:w.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0) else{exit(1)}
   w.sendEvent(e)
  }
  move(CGPoint(x:780,y:570));check(v.hovered?.0==candidates[0].0,"pointer identifies popup")
  move(CGPoint(x:780,y:570));check(v.hovered?.0==candidates[0].0,"duplicate window forwarding preserves same hover target")
  move(CGPoint(x:300,y:300));check(v.hovered?.0==candidates[1].0,"pointer leaving popup identifies ordinary window")
  move(CGPoint(x:980,y:50));check(v.hovered==nil,"empty area clears stale popup")
  move(CGPoint(x:780,y:570));check(v.hovered?.0==candidates[0].0,"pointer reentering popup identifies it again")
  func click(_ type:NSEvent.EventType,_ p:CGPoint){let e=NSEvent.mouseEvent(with:type,location:p,modifierFlags:[],timestamp:0,windowNumber:w.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!;if type == .leftMouseDown{v.mouseDown(with:e)}else{v.mouseUp(with:e)}}
  move(CGPoint(x:300,y:300));click(.leftMouseDown,CGPoint(x:300,y:300));click(.leftMouseUp,CGPoint(x:300,y:300))
  check(v.pendingRect==candidates[1].0,"ordinary window click locks its full rect")
  move(CGPoint(x:780,y:570));check(v.pendingRect==candidates[1].0,"hover cannot replace locked selection")
  v.cancelSelection();check(!w.isVisible,"no GUI shown")
  print("PASS window-local mouse dispatch popup→ordinary→empty→popup, full-screen carrier exclusion, ordinary click-lock and locked-selection stability; no activation/global input/screen read")
 }
}
