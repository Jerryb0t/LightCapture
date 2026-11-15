import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Constructed only for an explicit install action. No startup network or timer.
@MainActor final class SignedUpdateInstaller:NSObject {
    var finished:((Error?)->Void)?
    private(set) var mayTerminateForInstallation=false
    private(set) var active=false
    #if canImport(Sparkle)
    private var controller:SPUStandardUpdaterController?
    #endif
    func begin() throws {
        guard !active else{return}
        #if canImport(Sparkle)
        if controller == nil {
            let value=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:self,userDriverDelegate:nil)
            value.updater.automaticallyChecksForUpdates=false
            value.updater.automaticallyDownloadsUpdates=false
            try value.updater.start()
            controller=value
        }
        active=true;controller?.checkForUpdates(nil)
        #else
        throw NSError(domain:"LightCapture.Updater",code:1,userInfo:[NSLocalizedDescriptionKey:L("此构建未包含更新组件，请从官方发布获取新版。")])
        #endif
    }
}
#if canImport(Sparkle)
extension SignedUpdateInstaller:SPUUpdaterDelegate {
    func updater(_ updater:SPUUpdater,willInstallUpdate item:SUAppcastItem){mayTerminateForInstallation=true}
    func feedURLString(for updater:SPUUpdater)->String? {
        "https://raw.githubusercontent.com/Jerryb0t/LightCapture/main/appcast.xml"
    }

    func updater(_ updater:SPUUpdater,didFinishUpdateCycleFor updateCheck:SPUUpdateCheck,error:Error?){
        active=false;mayTerminateForInstallation=false;finished?(error)
    }
}
#endif
