import AppKit
import Carbon

/// Registers only Enter/Escape for the lifetime of an explicit long capture.
/// No event tap, Accessibility permission, global monitor or synthetic scrolling.
@MainActor final class LongSessionKeyboard {
    private var keys:[EventHotKeyRef]=[]
    private var handler:EventHandlerRef?
    private var generation:UInt32=0
    var action:((Bool)->Void)? // true = finish, false = cancel
    var active:Bool{keys.count==2}
    func start()->Bool {
        stop()
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let status=InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
            guard let context else{return OSStatus(eventNotHandledErr)}
            var id=EventHotKeyID();GetEventParameter(event,UInt32(kEventParamDirectObject),UInt32(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            guard id.signature==0x4C434C47 else{return OSStatus(eventNotHandledErr)}
            let owner=Unmanaged<LongSessionKeyboard>.fromOpaque(context).takeUnretainedValue()
            let keyID=id.id
            DispatchQueue.main.async{[weak owner] in owner?.receive(keyID)}
            return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard status==noErr else{stop();return false}
        for (code,id) in [(UInt32(36),generation+1),(UInt32(53),generation+2)] {
            var ref:EventHotKeyRef?
            guard RegisterEventHotKey(code,0,EventHotKeyID(signature:0x4C434C47,id:id),GetApplicationEventTarget(),0,&ref)==noErr,let ref else{stop();return false}
            keys.append(ref)
        }
        return true
    }
    private func receive(_ id:UInt32){guard active else{return};if id==generation+1{action?(true)}else if id==generation+2{action?(false)}}
    func stop(){generation &+= 2;for key in keys{UnregisterEventHotKey(key)};keys.removeAll();if let handler{RemoveEventHandler(handler)};handler=nil}
    deinit{for key in keys{UnregisterEventHotKey(key)};if let handler{RemoveEventHandler(handler)}}
}
