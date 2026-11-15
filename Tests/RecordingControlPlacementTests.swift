import Foundation
import CoreGraphics
@main struct RecordingControlPlacementTests {
 static func main(){
  let screen=CGRect(x:0,y:0,width:1440,height:900),visible=CGRect(x:0,y:40,width:1440,height:830),size=CGSize(width:250,height:82)
  var count=0
  for rect in [CGRect(x:300,y:250,width:700,height:400),CGRect(x:0,y:0,width:900,height:800),CGRect(x:300,y:0,width:1140,height:900),CGRect(x:0,y:200,width:1440,height:700)] {
   let f=RecordingControlPlacement.frame(size:size,capture:rect,visibleScreens:[visible],recordedScreenIndex:0)!
   precondition(visible.contains(f) && !rect.insetBy(dx:-12,dy:-12).intersects(f));count += 1
  }
  precondition(RecordingControlPlacement.frame(size:size,capture:screen,visibleScreens:[visible],recordedScreenIndex:0)==nil);count += 1
  let left=CGRect(x:-1920,y:-200,width:1920,height:1080)
  let other=RecordingControlPlacement.frame(size:size,capture:screen,visibleScreens:[visible,left],recordedScreenIndex:0)!
  precondition(left.contains(other) && !screen.intersects(other));count += 1
  let converted=RecordingControlPlacement.globalCapture(localTopLeft:CGRect(x:100,y:50,width:400,height:200),screen:left)
  precondition(converted == CGRect(x:-1820,y:630,width:400,height:200));count += 1
  precondition(RecordingControlPlacement.frame(size:size,capture:screen,visibleScreens:[visible,visible],recordedScreenIndex:0)==nil);count += 1 // mirrored display cannot be an escape
  precondition(RecordingControlPlacement.frame(size:CGSize(width:3000,height:100),capture:screen,visibleScreens:[visible,left],recordedScreenIndex:0)==nil);count += 1
  precondition(RecordingControlPlacement.frame(size:size,capture:screen,visibleScreens:[],recordedScreenIndex:0)==nil);count += 1
  // Deterministic grid: every returned placement stays visible and outside selection.
  for x in stride(from:0,through:1200,by:120){for y in stride(from:0,through:800,by:80){
   let rect=CGRect(x:x,y:y,width:240,height:100)
   if let f=RecordingControlPlacement.frame(size:size,capture:rect,visibleScreens:[visible],recordedScreenIndex:0){precondition(visible.contains(f) && !rect.insetBy(dx:-12,dy:-12).intersects(f))}
  }}
  print("PASS \(count) placement cases + 121 grid cases: outside region, fullscreen fallback, multi-display, negative origin, mirrored display, no fit")
 }
}
