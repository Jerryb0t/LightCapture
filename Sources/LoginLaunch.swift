import AppKit
import ServiceManagement
import Carbon

@MainActor protocol LoginItemManaging {
    var status:SMAppService.Status {get}
    func enable() throws
    func disable() async throws
}
@MainActor struct SystemLoginItem:LoginItemManaging {
    var status:SMAppService.Status {SMAppService.mainApp.status}
    func enable() throws {try SMAppService.mainApp.register()}
    func disable() async throws {try await SMAppService.mainApp.unregister()}
}
enum LoginLaunch {
    static func isLoginEvent(_ event:NSAppleEventDescriptor?)->Bool {
        event?.eventClass == AEEventClass(kCoreEventClass) && event?.eventID == AEEventID(kAEOpenApplication) && event?.paramDescriptor(forKeyword:AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
    static func presentation(_ status:SMAppService.Status)->(NSControl.StateValue,String) {
        switch status {
        case .enabled:return (.on,"已开启，下次登录时后台运行。")
        case .requiresApproval:return (.mixed,"等待系统批准，请在系统设置 → 通用 → 登录项中允许。")
        case .notFound:return (.off,"系统未找到此应用的登录项，建议先固定安装位置。")
        case .notRegistered:return (.off,"未开启；仅勾选后才会注册登录项。")
        @unknown default:return (.off,"无法确认登录项状态。")
        }
    }
}
