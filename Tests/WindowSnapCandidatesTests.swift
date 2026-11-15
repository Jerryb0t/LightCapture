import AppKit
@main struct WindowSnapCandidatesTests {
 static func main(){
  func check(_ value:Bool,_ message:String){if !value{fputs("FAIL: "+message+"\n",stderr);exit(1)}}
  let screen=CGRect(x:0,y:0,width:1440,height:900)
  func record(_ id:UInt32,_ frame:CGRect,_ owner:String="Fixture",_ pid:pid_t=42,_ visible:Bool=true)->SnapWindowRecord{SnapWindowRecord(id:id,frame:frame,layer:0,alpha:1,owner:owner,pid:pid,onScreen:visible)}
  let main=record(1,CGRect(x:100,y:80,width:800,height:600)),popup=record(2,CGRect(x:700,y:40,width:240,height:200))
  func info(_ record:SnapWindowRecord,_ layer:Int=0)->[String:Any]{[kCGWindowNumber as String:record.id,kCGWindowBounds as String:record.frame.dictionaryRepresentation,kCGWindowLayer as String:layer,kCGWindowOwnerPID as String:record.pid!,kCGWindowOwnerName as String:record.owner]}
  let fallback=WindowSnapCandidates.make(order:[],fallback:[main],screen:screen,primaryHeight:900,ownPID:9)
  check(fallback.count==1 && fallback[0].0==CGRect(x:100,y:220,width:800,height:600),"SCK restores hover when Quartz metadata absent; flipped coordinates")
  let full=WindowSnapCandidates.make(order:[info(popup,25),info(main)],fallback:[main,popup],screen:screen,primaryHeight:900,ownPID:9)
  check(full.map{$0.1}==[2,1],"popup front order preserved and duplicates removed")
  check(full.first(where:{$0.0.contains(CGPoint(x:720,y:750))})?.1==2,"hover picks popup ahead of underlying window")
  let partial=WindowSnapCandidates.make(order:[[kCGWindowNumber as String:1]],fallback:[main],screen:screen,primaryHeight:900,ownPID:9)
  check(partial.count==1,"sparse Quartz entry falls back safely")
  let excluded=WindowSnapCandidates.make(order:[],fallback:[record(3,main.frame,"Fixture",9),record(4,main.frame,"Dock"),record(5,main.frame,"Window Server"),record(6,main.frame,"Fixture",42,false)],screen:screen,primaryHeight:900,ownPID:9)
  check(excluded.isEmpty,"own/system/offscreen excluded")
  let menu=record(7,CGRect(x:0,y:0,width:1440,height:25))
  check(WindowSnapCandidates.make(order:[info(menu,24)],fallback:[menu],screen:screen,primaryHeight:900,ownPID:9).isEmpty,"rejected Quartz menu cannot return via fallback")
  let left=CGRect(x:-1000,y:200,width:1000,height:700)
  let multi=WindowSnapCandidates.make(order:[],fallback:[record(8,CGRect(x:-950,y:100,width:400,height:300))],screen:left,primaryHeight:900,ownPID:9)
  check(multi.count==1 && multi[0].0==CGRect(x:50,y:300,width:400,height:300),"secondary-display conversion")
  print("PASS missing/sparse Quartz fallback, frontmost popup, dedup, own/system/offscreen exclusion and secondary-display coordinates; no screen reads")
 }
}
