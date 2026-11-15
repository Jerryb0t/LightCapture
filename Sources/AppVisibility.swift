import AppKit

/// Background capture may activate its keyboard-capable windows without ever
/// promoting the process back to a Dock/menu-bar application.
@MainActor final class AppVisibility {
    private(set) var background=false
    var setPolicy:(NSApplication.ActivationPolicy)->Void = {_ = NSApp.setActivationPolicy($0)}
    var deactivate:()->Void = {NSApp.deactivate()}
    func start(login:Bool){background=login;setPolicy(login ? .accessory : .regular)}
    func hide(){background=true;setPolicy(.accessory);deactivate()}
    func reopen(){background=false;setPolicy(.regular)}
    func finished(){if background{deactivate()}}
}
