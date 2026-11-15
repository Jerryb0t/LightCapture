import AppKit
import ScreenCaptureKit

struct SnapWindowRecord {
    let id:CGWindowID
    let frame:CGRect // Quartz global top-left coordinates, captured before overlay activation.
    let layer:Int
    let alpha:Double
    let owner:String
    let pid:pid_t?
    let onScreen:Bool
}

enum WindowSnapCandidates {
    static func records(_ windows:[SCWindow])->[SnapWindowRecord] {
        windows.map{SnapWindowRecord(id:$0.windowID,frame:$0.frame,layer:$0.windowLayer,alpha:1,
            owner:$0.owningApplication?.applicationName ?? "",pid:$0.owningApplication?.processID,onScreen:$0.isOnScreen)}
    }
    /// Quartz supplies front-to-back ordering where available. SCK is a fallback,
    /// not a fresh query after an overlay has dismissed a transient menu.
    static func make(order:[[String:Any]],fallback:[SnapWindowRecord],screen:CGRect,primaryHeight:CGFloat,ownPID:pid_t)->[(CGRect,CGWindowID)] {
        let fallbackByID=Dictionary(fallback.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        let quartz:[SnapWindowRecord]=order.compactMap{info -> SnapWindowRecord? in
            guard let id=(info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds=info[kCGWindowBounds as String] as? [String:Any],
                  let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary) else{return nil}
            let known=fallbackByID[id]
            return SnapWindowRecord(id:id,frame:frame,
                layer:(info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? known?.layer ?? 0,
                alpha:(info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                owner:info[kCGWindowOwnerName as String] as? String ?? known?.owner ?? "",
                pid:(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? known?.pid,
                onScreen:(info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true)
        }
        var seen=Set<CGWindowID>(),result:[(CGRect,CGWindowID)]=[]
        for record in quartz+fallback {
            guard seen.insert(record.id).inserted,record.onScreen else{continue}
            let raw=record.frame
            guard raw.origin.x.isFinite,raw.origin.y.isFinite,raw.width.isFinite,raw.height.isFinite else{continue}
            let global=CGRect(x:raw.minX,y:primaryHeight-raw.maxY,width:raw.width,height:raw.height)
            guard WindowSnapPolicy.permits(layer:record.layer,alpha:record.alpha,frame:global,displayBounds:screen,owner:record.owner,isOwn:record.pid==ownPID) else{continue}
            let local=global.intersection(screen).offsetBy(dx:-screen.minX,dy:-screen.minY)
            if !local.isEmpty{result.append((local,record.id))}
        }
        return result
    }
}
