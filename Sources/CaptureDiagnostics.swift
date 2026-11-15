import Foundation
import os

/// Privacy-safe rolling trace: fixed stage identifiers + numeric error classification only.
/// No descriptions, paths, window titles, image data or clipboard values are accepted.
enum CaptureDiagnostics {
    enum Stage:String {case windowListBegin, windowListComplete, windowListFailed, mouseDown, mouseUp, buttonConfirm, doubleClickConfirm, cancel, captureBegin, captureComplete, clipboardOK, clipboardFailed, saveBegin, saveOK, saveFailed, captureFailed}
    private static let lock=NSLock()
    private static var entries:[String]=[]
    private static let logger=Logger(subsystem:"local.lightcapture",category:"capture-stage")
    static func record(_ stage:Stage,error:Error?=nil){
        var entry=stage.rawValue
        if let error {
            let e=error as NSError
            // Domain names can be arbitrary user text; whitelist only standard domains.
            let domain=[NSCocoaErrorDomain,NSPOSIXErrorDomain,NSOSStatusErrorDomain,NSURLErrorDomain].contains(e.domain) ? e.domain : "other"
            entry += " domain=\(domain) code=\(e.code)"
        }
        lock.lock();entries.append(entry);if entries.count>64{entries.removeFirst(entries.count-64)};lock.unlock()
        logger.debug("\(entry,privacy:.public)")
    }
    static func snapshot()->String {lock.lock();defer{lock.unlock()};return entries.joined(separator:"\n")}
}
