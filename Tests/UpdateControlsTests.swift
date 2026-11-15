import AppKit
@main struct UpdateControlsTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func check(_ condition:Bool,_ message:String){
            if !condition{fputs("FAIL: "+message+"\n",stderr);exit(1)}
        }
        let app=AppDelegate()
        let suite="local.lightcapture.update-test."+UUID().uuidString
        guard let preferences=UserDefaults(suiteName:suite) else{exit(1)}
        defer{preferences.removePersistentDomain(forName:suite)}
        app.updatePreferences=preferences
        var requests=[String](),installs=0
        var completeInstall:((Error?)->Void)?
        let page=URL(string:"https://github.com/Jerryb0t/LightCapture/releases/tag/v0.2.1")!
        let candidate=ManualUpdateCandidate(version:try UpdateVersion("v0.2.1"),tag:"v0.2.1",releaseURL:page,archiveURL:URL(string:"https://github.com/Jerryb0t/LightCapture/releases/download/v0.2.1/LightCapture-macos-arm64.zip")!,archiveSize:100,sha256:String(repeating:"a",count:64))
        app.checkForUpdate={ version in requests.append(version);return candidate }
        app.beginVerifiedInstall={done in installs += 1;completeInstall=done}
        app.buildUI()
        app.checkAutomaticallyIfDue(now:Date(timeIntervalSince1970:100_000))
        check(requests.isEmpty && app.automaticUpdateCheckbox.state == .off,"default OFF never creates network work")
        app.setBusy(true);app.checkUpdates()
        check(requests.isEmpty && !app.updateCheckButton.isEnabled,"no update check while busy")
        app.setBusy(false);app.checkUpdates();app.checkUpdates()
        for _ in 0..<50 where app.updateReleaseButton.isHidden {try await Task.sleep(nanoseconds:2_000_000)}
        check(requests==[app.installedVersion] && !app.updateReleaseButton.isHidden,"one check, candidate found")
        check(installs==0,"check does not install")
        app.viewUpdateRelease()
        check(installs==1 && !app.updateCheckButton.isEnabled,"explicit install gates capture and duplicate actions")
        app.viewUpdateRelease();check(installs==1,"duplicate install blocked")
        completeInstall?(nil)
        check(app.updateCheckButton.isEnabled,"cancel/completion restores controls")
        app.checkForUpdate={ _ in throw ManualUpdateError.noPublishedRelease }
        app.checkUpdates()
        for _ in 0..<50 where !app.updateCheckButton.isEnabled {try await Task.sleep(nanoseconds:2_000_000)}
        check(app.updateReleaseButton.isHidden && app.updateStatus.stringValue==L("GitHub 暂未发布可安装版本。"),"clear no-release status and stale candidate")
        let old=Date(timeIntervalSince1970:100_000)
        var automaticRequests=0
        app.checkForUpdate={ _ in automaticRequests += 1;return nil }
        app.automaticUpdateCheckbox.state = .on; app.toggleAutomaticUpdate()
        app.checkAutomaticallyIfDue(now:old);app.checkAutomaticallyIfDue(now:old)
        for _ in 0..<50 where !app.updateCheckButton.isEnabled {try await Task.sleep(nanoseconds:2_000_000)}
        app.checkAutomaticallyIfDue(now:old.addingTimeInterval(86_399))
        check(automaticRequests==1 && app.updateReleaseButton.isHidden,"opt-in startup, no duplicate before 24h")
        app.checkAutomaticallyIfDue(now:old.addingTimeInterval(86_400))
        for _ in 0..<50 where !app.updateCheckButton.isEnabled {try await Task.sleep(nanoseconds:2_000_000)}
        check(automaticRequests==2,"next eligible launch or reopen checks")
        app.automaticUpdateCheckbox.state = .off;app.toggleAutomaticUpdate()
        app.checkAutomaticallyIfDue(now:old.addingTimeInterval(200_000))
        check(automaticRequests==2 && !preferences.bool(forKey:"automaticUpdateCheck"),"turning OFF disables subsequent checks")
        print("PASS default OFF, explicit startup opt-in, 24h throttle, manual check, busy/duplicate block, valid release and no-package states, no actual network or browser")
    }
}
