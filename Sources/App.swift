import AppKit
import ScreenCaptureKit
import Carbon
import AVFoundation

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    @MainActor private final class SettingsUI {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:710),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        let authorLinks=AuthorLinks()
        var buttons:[NSButton]=[]
        let status=NSTextField(wrappingLabelWithString:"")
        let pathLabel=NSTextField(wrappingLabelWithString:"")
        let detail=NSTextField(wrappingLabelWithString:L("文件保存到所选目录后，由 iCloud 自行同步。录制中间文件保留在本机。"))
        let audio=NSButton(checkboxWithTitle:L("录制系统声音"),target:nil,action:nil)
        let microphone=NSButton(checkboxWithTitle:L("录制麦克风"),target:nil,action:nil)
        let quality=NSPopUpButton()
        let frameRatePicker=NSPopUpButton()
        let automaticUpdateCheckbox=NSButton(checkboxWithTitle:L("启动时自动检查更新"),target:nil,action:nil)
        let updateCheckButton=NSButton(title:L("检查更新…"),target:nil,action:nil)
        let updateReleaseButton=NSButton(title:L("下载并安装…"),target:nil,action:nil)
        let updateStatus=NSTextField(wrappingLabelWithString:"")
        let copyOnly=NSButton(checkboxWithTitle:L("截图仅复制到剪贴板，不保存文件"),target:nil,action:nil)
        let loginCheckbox=NSButton(checkboxWithTitle:L("登录 Mac 后自动运行"),target:nil,action:nil)
        let loginHint=NSTextField(wrappingLabelWithString:"")
        let mainStopButton=NSButton(title:L("停止并保存"),target:nil,action:nil)
        let cancelPreparationButton=NSButton(title:L("取消准备 Esc"),target:nil,action:nil)
        var shortcutButton:NSButton!
        var shortcutLabel:NSTextField!
    }
    private var settings:SettingsUI?
    private var settingsFrame:NSRect?
    var window:NSWindow! { settings?.window }
    var authorLinks:AuthorLinks { settings!.authorLinks }
    var buttons:[NSButton] { settings?.buttons ?? [] }
    var audio:NSButton { settings!.audio }
    var microphone:NSButton { settings!.microphone }
    var frameRatePicker:NSPopUpButton { settings!.frameRatePicker }
    var loginCheckbox:NSButton { settings!.loginCheckbox }
    var mainStopButton:NSButton { settings!.mainStopButton }
    var automaticUpdateCheckbox:NSButton { settings!.automaticUpdateCheckbox }
    var updateCheckButton:NSButton { settings!.updateCheckButton }
    var updateReleaseButton:NSButton { settings!.updateReleaseButton }
    var updateStatus:NSTextField { settings!.updateStatus }
    private var statusMessage=L("只做截图和录屏。闲置时不捕获屏幕。") {
        didSet { settings?.status.stringValue=statusMessage }
    }
    private var updateMessage:String? {
        didSet { settings?.updateStatus.stringValue=updateMessage ?? "";settings?.updateStatus.isHidden=updateMessage == nil }
    }
    let visibility=AppVisibility()
    var storage:CaptureStorage { CaptureStorage.shared }
    let selector=SelectionController()
    let recorder=CaptureEngine()
    var updatePreferences=UserDefaults.standard
    private var updateTask:Task<Void,Never>?
    private var automaticCheckInFlight=false
    private var updateCheckInProgress=false
    private var updateCandidate:ManualUpdateCandidate?
    var checkForUpdate:(String) async throws -> ManualUpdateCandidate? = {try await ManualUpdateService().check(currentVersion:$0)}
    private var signedInstaller:SignedUpdateInstaller?
    var beginVerifiedInstall:((@escaping (Error?)->Void)throws->Void)?

    var installedVersion:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1.0"}
    var loginItem:LoginItemManaging = SystemLoginItem()
    private var changingLogin=false
    var busy = false
    var longTarget: CaptureTarget?
    var captureSourceApplication:NSRunningApplication?
    let longKeys=LongSessionKeyboard()
    let longBorder=LongCaptureBorder()
    let longSession=LongCaptureSession()
    var control: NSPanel?
    var longLabel: NSTextField?
    var lastSaved: URL?
    var recordingRoot: URL?
    var recordingFrameRate:RecordingFrameRate { RecordingFrameRate.load() }
    private var screenshotCopyOnly:Bool { UserDefaults.standard.bool(forKey:"copyOnly") }
    private var recordingTarget:CaptureTarget?
    enum RecordingControlState {case idle, starting, recording, stopping}
    private(set) var recordingControlState:RecordingControlState = .idle
    private(set) var stopMenuItems:[NSMenuItem]=[]
    var stopPending = false
    var recordStart: Date?
    var hotkeys: [EventHotKeyRef?] = []
    var hotkeyHandlerInstalled = false
    var editor: CaptureEditor?
    var shortcutMonitor: Any?
    let contentRequest=DeadlineRequest<PreparedCapture>()
    let screenshotRequest=DeadlineRequest<CGImage>()
    private var feedbackPanel:NSPanel?
    private var feedbackDismiss:DispatchWorkItem?

    override init(){
        super.init()
        selector.failure = {[weak self] error in self?.setBusy(false);self?.report(error)}
        recorder.started = { [weak self] in Task { @MainActor in self?.didStartRecording() } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let login=LoginLaunch.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
        visibility.start(login:login)
        buildMenu(); registerHotkeys()
        if !login{showWindow()}
        checkAutomaticallyIfDue()
        NotificationCenter.default.addObserver(self,selector:#selector(recordingScreensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
    }
    func buildUI() {
        guard settings == nil else{return}
        let ui=SettingsUI();settings=ui
        let window=ui.window
        window.title=L("轻截"); window.delegate=self; window.isReleasedWhenClosed=false
        if let settingsFrame {window.setFrame(settingsFrame,display:false)}else{window.center()}
        let root=NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing=10
        root.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:22)])
        let title=NSTextField(labelWithString:L("轻截")); title.font = .systemFont(ofSize:30,weight:.semibold);root.addArrangedSubview(title)
        let subtitle=NSTextField(wrappingLabelWithString:L("轻巧，只在需要时工作。闲置时不捕获屏幕。")) ;subtitle.textColor = .secondaryLabelColor;root.addArrangedSubview(subtitle);subtitle.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let captureHeading=NSTextField(labelWithString:L("截图与录屏"));captureHeading.font = .systemFont(ofSize:12,weight:.semibold);captureHeading.textColor = .secondaryLabelColor;root.addArrangedSubview(captureHeading)
        let grid=NSGridView(views:[
            [actionButton(L("区域 / 窗口截图"),symbol:"viewfinder",action:#selector(screenshot)), actionButton(L("全屏截图"),symbol:"rectangle",action:#selector(fullScreenshot))],
            [actionButton(L("区域录屏"),symbol:"rectangle.dashed",action:#selector(regionRecording)), actionButton(L("全屏录屏"),symbol:"record.circle",action:#selector(fullRecording))],
            [actionButton(L("长截图"),symbol:"rectangle.expand.vertical",action:#selector(longScreenshot)), NSView()]
        ])
        grid.rowSpacing=10;grid.columnSpacing=10;root.addArrangedSubview(grid)
        for b in buttons { b.widthAnchor.constraint(equalToConstant:223).isActive=true;b.heightAnchor.constraint(equalToConstant:48).isActive=true }
        let shortcuts=NSTextField(wrappingLabelWithString:L("同一快捷键：闲置时打开截图；录屏时停止并保存。"))
        shortcuts.font = .systemFont(ofSize:11);shortcuts.textColor = .secondaryLabelColor;root.addArrangedSubview(shortcuts);shortcuts.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        ui.shortcutLabel=NSTextField(labelWithString:L("截图快捷键：") + (UserDefaults.standard.string(forKey:"shortcutTitle") ?? "⌃ A"))
        ui.shortcutLabel.font = .systemFont(ofSize:12)
        ui.shortcutButton=NSButton(title:L("修改…"),target:self,action:#selector(changeShortcut))
        let shortcutRow=NSStackView(views:[ui.shortcutLabel,ui.shortcutButton]);shortcutRow.spacing=12;root.addArrangedSubview(shortcutRow)
        let line=NSBox();line.boxType = .separator;root.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let pathRow=NSStackView();pathRow.orientation = .horizontal;pathRow.spacing=8
        let label=NSTextField(labelWithString:L("保存位置"));label.font = .systemFont(ofSize:13,weight:.medium);pathRow.addArrangedSubview(label)
        let change=NSButton(title:L("选择文件夹…"),target:self,action:#selector(chooseFolder));pathRow.addArrangedSubview(change)
        let open=NSButton(title:L("打开"),target:self,action:#selector(openFolder));pathRow.addArrangedSubview(open)
        root.addArrangedSubview(pathRow)
        ui.pathLabel.stringValue=storage.root.path;ui.pathLabel.font = .systemFont(ofSize:11);ui.pathLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(ui.pathLabel);ui.pathLabel.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        ui.quality.addItems(withTitles:[L("标准 · 最长边 1920"), L("高清 · 最长边 3840")])
        ui.quality.selectItem(at:UserDefaults.standard.integer(forKey:"quality"));ui.quality.target=self;ui.quality.action=#selector(settingsChanged)
        ui.copyOnly.state=UserDefaults.standard.bool(forKey:"copyOnly") ? .on : .off;ui.copyOnly.target=self;ui.copyOnly.action=#selector(settingsChanged)
        for rate in RecordingFrameRate.allCases {
            ui.frameRatePicker.addItem(withTitle:"\(rate.rawValue) fps");ui.frameRatePicker.lastItem?.tag=rate.rawValue
        }
        ui.frameRatePicker.selectItem(withTag:RecordingFrameRate.load().rawValue)
        ui.frameRatePicker.setAccessibilityLabel(L("录屏帧率"));ui.frameRatePicker.target=self;ui.frameRatePicker.action=#selector(settingsChanged)
        let videoSettings=NSStackView(views:[ui.quality,NSTextField(labelWithString:L("录屏帧率")),ui.frameRatePicker]);videoSettings.spacing=10
        let audioSettings=NSStackView(views:[ui.audio,ui.microphone]);audioSettings.spacing=14
        let settings=NSStackView(views:[videoSettings,audioSettings,ui.copyOnly]);settings.orientation = .vertical;settings.alignment = .leading;settings.spacing=7
        let preferences=UserDefaults.standard
        ui.audio.state=(preferences.object(forKey:"audio") == nil || preferences.bool(forKey:"audio")) ? .on : .off;ui.audio.target=self;ui.audio.action=#selector(settingsChanged)
        ui.microphone.state=preferences.bool(forKey:"recordingMicrophone") ? .on : .off
        ui.microphone.target=self;ui.microphone.action=#selector(settingsChanged)
        ui.loginCheckbox.target=self;ui.loginCheckbox.action=#selector(toggleLoginItem)
        ui.loginHint.font = .systemFont(ofSize:11);ui.loginHint.textColor = .secondaryLabelColor
        settings.addArrangedSubview(ui.loginCheckbox);settings.addArrangedSubview(ui.loginHint);ui.loginHint.widthAnchor.constraint(lessThanOrEqualToConstant:460).isActive=true
        root.addArrangedSubview(settings);refreshLoginItem()
        ui.mainStopButton.target=self;ui.mainStopButton.action=#selector(stopRecording);ui.mainStopButton.bezelStyle = .rounded;ui.mainStopButton.setAccessibilityLabel(L("停止并保存录屏"));ui.mainStopButton.isHidden=true;ui.mainStopButton.isEnabled=false;root.addArrangedSubview(ui.mainStopButton)
        ui.cancelPreparationButton.target=self;ui.cancelPreparationButton.action=#selector(cancelPreparation);ui.cancelPreparationButton.keyEquivalent="\u{1b}";ui.cancelPreparationButton.keyEquivalentModifierMask=[];ui.cancelPreparationButton.isHidden=true;root.addArrangedSubview(ui.cancelPreparationButton)
        ui.status.font = .systemFont(ofSize:12);root.addArrangedSubview(ui.status);ui.status.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        ui.detail.font = .systemFont(ofSize:10);ui.detail.textColor = .secondaryLabelColor;root.addArrangedSubview(ui.detail);ui.detail.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let footer=NSStackView(views:[ui.authorLinks.followButton,ui.authorLinks.button]);footer.spacing=20
        root.addArrangedSubview(footer)
        ui.updateCheckButton.target=self;ui.updateCheckButton.action=#selector(checkUpdates);ui.updateCheckButton.bezelStyle = .inline
        ui.updateReleaseButton.target=self;ui.updateReleaseButton.action=#selector(viewUpdateRelease);ui.updateReleaseButton.bezelStyle = .inline;ui.updateReleaseButton.isHidden=true
        let version=NSTextField(labelWithString:L("版本 %@",installedVersion));version.font = .systemFont(ofSize:11);version.textColor = .secondaryLabelColor
        ui.automaticUpdateCheckbox.state=updatePreferences.bool(forKey:"automaticUpdateCheck") ? .on : .off
        ui.automaticUpdateCheckbox.target=self;ui.automaticUpdateCheckbox.action=#selector(toggleAutomaticUpdate)
        ui.automaticUpdateCheckbox.font = .systemFont(ofSize:11)
        let updateRow=NSStackView(views:[version,ui.updateCheckButton,ui.updateReleaseButton,ui.automaticUpdateCheckbox]);updateRow.spacing=8;root.addArrangedSubview(updateRow)
        ui.updateStatus.font = .systemFont(ofSize:11);ui.updateStatus.textColor = .secondaryLabelColor
        root.addArrangedSubview(ui.updateStatus);ui.updateStatus.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true;ui.updateStatus.isHidden=true
        ui.status.stringValue=statusMessage
        ui.updateStatus.stringValue=updateMessage ?? "";ui.updateStatus.isHidden=updateMessage == nil
        ui.updateReleaseButton.isHidden=updateCandidate == nil
        ui.cancelPreparationButton.isHidden = !contentRequest.pending && !screenshotRequest.pending
        updateRecordingControls(recordingControlState)
        refreshBusyControls()
    }
    func actionButton(_ title:String,symbol:String,action:Selector)->NSButton {
        let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.image=NSImage(systemSymbolName:symbol,accessibilityDescription:title);b.imagePosition = .imageLeading;b.font = .systemFont(ofSize:14,weight:.medium);settings?.buttons.append(b);return b
    }
    @objc func checkUpdates(){startUpdateCheck(automatic:false)}
    @objc func toggleAutomaticUpdate(){
        guard let settings else{return};let enabled=settings.automaticUpdateCheckbox.state == .on
        updatePreferences.set(enabled,forKey:"automaticUpdateCheck")
        if !enabled,automaticCheckInFlight {updateTask?.cancel()}
    }
    func checkAutomaticallyIfDue(now:Date = Date()){
        guard updatePreferences.bool(forKey:"automaticUpdateCheck"),!busy,!updateCheckInProgress else{return}
        let last=updatePreferences.object(forKey:"lastAutomaticUpdateCheck") as? Date
        if let last,last<=now,now.timeIntervalSince(last)<86_400{return}
        updatePreferences.set(now,forKey:"lastAutomaticUpdateCheck")
        startUpdateCheck(automatic:true)
    }
    private func startUpdateCheck(automatic:Bool){
        guard !busy,!updateCheckInProgress else{return}
        updateCheckInProgress=true;automaticCheckInFlight=automatic;updateCandidate=nil;settings?.updateReleaseButton.isHidden=true;refreshUpdateControls()
        updateMessage=automatic ? nil : L("正在检查 GitHub 发布版本…")
        updateTask=Task { @MainActor [weak self] in
            guard let self else{return}
            defer {self.updateTask=nil;self.automaticCheckInFlight=false;self.updateCheckInProgress=false;self.refreshUpdateControls()}
            do {
                let candidate=try await self.checkForUpdate(self.installedVersion)
                guard !Task.isCancelled else{return}
                self.updateCandidate=candidate
                if let candidate{
                    self.updateMessage=L("发现 %@。可下载并验证安装，更新会重新启动轻截。",candidate.tag)
                    self.settings?.updateReleaseButton.isHidden=false
                }else if !automatic {self.updateMessage=L("你已使用最新发布版本。")}
            }catch ManualUpdateError.noPublishedRelease {
                if !automatic && !Task.isCancelled {self.updateMessage=L("GitHub 暂未发布可安装版本。")}
            }catch {
                if !automatic && !Task.isCancelled {self.updateMessage=L("检查更新失败，请稍后重试。")}
            }
        }
    }
    @objc func viewUpdateRelease(){
        guard !busy,!updateCheckInProgress,updateCandidate != nil else{return}
        setBusy(true)
        let completion:(Error?)->Void = {[weak self] error in
            guard let self else{return};self.setBusy(false)
            if let error {self.updateMessage=error.localizedDescription}
        }
        do {
            if let beginVerifiedInstall {try beginVerifiedInstall(completion)}else{
                if signedInstaller == nil {signedInstaller=SignedUpdateInstaller()}
                signedInstaller?.finished=completion
                try signedInstaller?.begin()
            }
        }catch{completion(error)}
    }
    private func refreshUpdateControls(){
        guard let settings else{return}
        settings.automaticUpdateCheckbox.isEnabled = !busy
        settings.updateCheckButton.isEnabled = !busy && !updateCheckInProgress
        settings.updateReleaseButton.isEnabled = !busy && !updateCheckInProgress
    }
    func buildMenu() {
        let menu=NSMenu();let app=NSMenuItem();menu.addItem(app)
        let submenu=NSMenu();submenu.addItem(withTitle:L("显示轻截"),action:#selector(revealSettings),keyEquivalent:"0").target=self
        let mainStop=submenu.addItem(withTitle:L("停止并保存录屏"),action:#selector(stopRecording),keyEquivalent:"");mainStop.target=self;mainStop.isEnabled=false;stopMenuItems.append(mainStop)
        submenu.addItem(withTitle:L("退出轻截"),action:#selector(quit),keyEquivalent:"q").target=self;app.submenu=submenu;NSApp.mainMenu=menu
        submenu.insertItem(withTitle:L("待保存文件"),action:#selector(openRecovery),keyEquivalent:"",at:2).target=self
        submenu.insertItem(withTitle:L("诊断状态"),action:#selector(showDiagnostics),keyEquivalent:"",at:3).target=self
    }
    func registerHotkeys() {
        for ref in hotkeys { if let ref {UnregisterEventHotKey(ref)} };hotkeys.removeAll()
        if !hotkeyHandlerInstalled {
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,event,_ in
            var identifier=EventHotKeyID()
            guard GetEventParameter(event,UInt32(kEventParamDirectObject),UInt32(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&identifier)==noErr,
                  identifier.signature==0x4C434150 else{return OSStatus(eventNotHandledErr)}
            let command=identifier.id
            DispatchQueue.main.async {
                guard let app=NSApp.delegate as? AppDelegate else{return}
                switch command {case 1:app.handleCaptureShortcut();case 2:app.longScreenshot();case 3:app.fullRecording();case 4:app.regionRecording();default:break}
            };return noErr
        },1,&type,nil,nil)
        hotkeyHandlerInstalled = true
        }
        let firstKey = UserDefaults.standard.object(forKey:"shortcutKey") == nil ? 0 : UserDefaults.standard.integer(forKey:"shortcutKey")
        let firstMods = UserDefaults.standard.object(forKey:"shortcutMods") == nil ? UInt32(controlKey) : UInt32(UserDefaults.standard.integer(forKey:"shortcutMods"))
        let keys:[(Int,UInt32)] = [(firstKey,firstMods)]
        for (index,pair) in keys.enumerated() { var ref:EventHotKeyRef?; let id=EventHotKeyID(signature:0x4C434150,id:UInt32(index+1));let result=RegisterEventHotKey(UInt32(pair.0),pair.1,id,GetApplicationEventTarget(),0,&ref);if result == noErr {hotkeys.append(ref)} }
        if hotkeys.count != 1 {statusMessage=L("快捷键存在冲突，请修改快捷键；仍可点击按钮使用。")}
    }
    enum ShortcutAction {case capture,stop,ignore}
    var captureShortcutAction:ShortcutAction {
        if shortcutMonitor != nil{return .ignore}
        if recordingControlState == .recording && !stopPending{return .stop}
        return busy || recordingControlState != .idle ? .ignore : .capture
    }
    func handleCaptureShortcut(){switch captureShortcutAction {case .capture:screenshot();case .stop:stopRecording();case .ignore:break}}
    func refreshLoginItem(){guard let settings else{return};let value=LoginLaunch.presentation(loginItem.status);settings.loginCheckbox.allowsMixedState = value.0 == .mixed;settings.loginCheckbox.state=value.0;settings.loginHint.stringValue=value.1;settings.loginCheckbox.isEnabled = !changingLogin}
    @objc func toggleLoginItem(){
        guard !changingLogin,let settings else{return};let enable=settings.loginCheckbox.state == .on;changingLogin=true;settings.loginCheckbox.isEnabled=false
        Task{@MainActor in
            do{if enable {try loginItem.enable()}else{try await loginItem.disable()};changingLogin=false;refreshLoginItem()}
            catch{changingLogin=false;refreshLoginItem();self.settings?.loginHint.stringValue=L("设置失败：")+error.localizedDescription}
        }
    }
    func applicationDidBecomeActive(_ notification:Notification){refreshLoginItem()}
    @objc func changeShortcut(){
        guard !busy,shortcutMonitor == nil,let settings else{return}
        for ref in hotkeys {if let ref {UnregisterEventHotKey(ref)}};hotkeys.removeAll()
        settings.shortcutButton.title=L("请按组合键…");statusMessage=L("按新的截图组合键（需 ⌃ / ⌥ / ⌘），Esc 取消。若浮引占用同一快捷键，请自行调整其中一个。")
        shortcutMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            guard let self else{return event}
            if event.keyCode == 53 {self.endShortcut();return nil}
            let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control)||flags.contains(.option)||flags.contains(.command) else{return nil}
            var mods:UInt32=0;var title=""
            if flags.contains(.control){mods |= UInt32(controlKey);title+="⌃"}
            if flags.contains(.option){mods |= UInt32(optionKey);title+="⌥"}
            if flags.contains(.shift){mods |= UInt32(shiftKey);title+="⇧"}
            if flags.contains(.command){mods |= UInt32(cmdKey);title+="⌘"}
            title += " " + (event.charactersIgnoringModifiers?.uppercased() ?? L("键 %@", String(describing: event.keyCode)))
            UserDefaults.standard.set(Int(event.keyCode),forKey:"shortcutKey");UserDefaults.standard.set(Int(mods),forKey:"shortcutMods");UserDefaults.standard.set(title,forKey:"shortcutTitle")
            self.settings?.shortcutLabel.stringValue=L("截图快捷键：")+title;self.endShortcut();return nil
        }
    }
    func endShortcut(){if let monitor=shortcutMonitor{NSEvent.removeMonitor(monitor)};shortcutMonitor=nil;settings?.shortcutButton.title=L("修改…");registerHotkeys()}

    @objc func settingsChanged(){
        guard let settings else{return}
        let defaults=UserDefaults.standard
        defaults.set(settings.quality.indexOfSelectedItem,forKey:"quality")
        defaults.set(settings.audio.state == .on,forKey:"audio")
        defaults.set(settings.microphone.state == .on,forKey:"recordingMicrophone")
        (RecordingFrameRate(rawValue:settings.frameRatePicker.selectedTag()) ?? .fps30).save()
        defaults.set(settings.copyOnly.state == .on,forKey:"copyOnly")
    }
    @objc func revealSettings(){guard !longSession.active else{return};visibility.reopen();showWindow()}
    @objc func showWindow(){buildUI();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func chooseFolder(){
        guard !busy,let window else{return};let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false;panel.message=L("选择保存根文件夹，将自动分为截图、长截图和录屏。");panel.directoryURL=storage.root
        panel.beginSheetModal(for:window){ [weak self] response in
            guard response == .OK,let url=panel.url,let self else{return}
            do{try self.storage.select(url);self.settings?.pathLabel.stringValue=url.path}catch{self.report(error)}
        }
    }
    @objc func openFolder(){do{try FileManager.default.createDirectory(at:storage.root,withIntermediateDirectories:true);NSWorkspace.shared.open(storage.root)}catch{report(error)}}
    @objc func openRecovery(){do{try FileManager.default.createDirectory(at:CaptureStorage.recoveryDirectory,withIntermediateDirectories:true);NSWorkspace.shared.open(CaptureStorage.recoveryDirectory)}catch{report(error)}}
    func setBusy(_ value:Bool){busy=value;refreshBusyControls();if !value{visibility.finished()}}
    private func refreshBusyControls(){
        guard let settings else{return}
        for button in settings.buttons {button.isEnabled = !busy}
        settings.quality.isEnabled = !busy;settings.frameRatePicker.isEnabled = !busy
        settings.audio.isEnabled = !busy;settings.microphone.isEnabled = !busy
        settings.copyOnly.isEnabled = !busy;settings.shortcutButton.isEnabled = !busy
        refreshUpdateControls()
    }
    func report(_ error:Error){statusMessage=error.localizedDescription;showWindow()}
    func permission()->Bool{
        if CGPreflightScreenCaptureAccess(){return true}
        let alert=NSAlert();alert.messageText=L("需要屏幕录制权限");alert.informativeText=L("截图和录屏需要 macOS 允许轻截读取屏幕。只在你主动开始时捕获，不在后台持续抓屏。请在系统设置中自行开启，返回后再试。");alert.addButton(withTitle:L("请求权限"));alert.addButton(withTitle:L("取消"))
        if alert.runModal() == .alertFirstButtonReturn { _=CGRequestScreenCaptureAccess() }
        return false
    }
    @objc func cancelPreparation(){
        guard contentRequest.pending || screenshotRequest.pending else{return}
        contentRequest.cancel();screenshotRequest.cancel();settings?.cancelPreparationButton.isHidden=true
        CaptureDiagnostics.record(.cancel);setBusy(false);statusMessage=L("已取消准备。");showFeedback(L("已取消"))
    }
    func prepare(region:Bool,windowSnap:Bool=false,mode:CaptureMode = .screenshot,then:@escaping(CaptureTarget)->Void){
        guard !busy,shortcutMonitor == nil else{return}
        // Preserve third-party transient panels until pixels and candidates are frozen.
        let foreground=NSWorkspace.shared.frontmostApplication
        captureSourceApplication = foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : foreground
        setBusy(true);guard permission() else{setBusy(false);return}
        let restoreLaunchWindow=window?.isVisible == true
        statusMessage=L("正在读取可用窗口…（最多等待 8 秒）");settings?.cancelPreparationButton.isHidden=false
        CaptureDiagnostics.record(.windowListBegin)
        contentRequest.start(seconds:8,operation:{try await FrozenCapture.prepare(freeze:region || mode == .screenshot,liveFallback:mode != .screenshot)}){[weak self] result in
            guard let self else{return};self.settings?.cancelPreparationButton.isHidden=true
            switch result {
            case .failure(let error):
                CaptureDiagnostics.record(.windowListFailed,error:error);self.setBusy(false);self.showFeedback(L("读取窗口失败，可重试"),failure:true);self.report(error)
            case .success(let prepared):
                let content=prepared.content
                self.settings?.authorLinks.dismiss();self.feedbackDismiss?.cancel();self.feedbackDismiss=nil;self.feedbackPanel?.close();self.feedbackPanel=nil
                CaptureDiagnostics.record(.windowListComplete);self.window?.orderOut(nil)
                if region {
                    self.selector.beforeLongStart = {[weak self] in
                        guard let self else{return L("无法启动长截图，请重试。")}
                        return self.prepareLongKeys()
                    }
                    self.selector.begin(displays:content.displays,availableWindows:windowSnap ? content.windows : [],mode:mode,frames:prepared.frames,windowOrder:windowSnap ? prepared.order : [],notice:prepared.notice,allowsScreenshot:prepared.screenshotAvailable){[weak self] target in
                        guard let self else{return}
                        if let target{then(target)}else{self.longKeys.stop();self.setBusy(false);self.statusMessage=L("已取消。");if restoreLaunchWindow && !self.visibility.background{self.showWindow()}}
                    }
                }else{
                    let screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main
                    let id=(screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    guard let display=content.displays.first(where:{$0.displayID==id}) ?? content.displays.first else{self.setBusy(false);self.report(CaptureFailure.message(L("找不到可捕获的屏幕。")));return}
                    let rect=CGRect(x:0,y:0,width:screen?.frame.width ?? CGFloat(display.width),height:screen?.frame.height ?? CGFloat(display.height))
                    do{
                        let image=mode == .screenshot ? try prepared.frames[display.displayID]?.crop(rect) : nil
                        if mode == .screenshot && image == nil {throw CaptureFailure.message(L("冻结画面不可用，请保持鼠标在目标屏幕后重试。"))}
                        then(CaptureTarget(display:display,rect:rect,mode:mode,frozenImage:image))
                    }catch{self.setBusy(false);self.report(error)}
                }
            }
        }
    }
    @objc func screenshot(){prepare(region:true,windowSnap:true){[weak self] target in self?.takeScreenshot(target)}}
    @objc func fullScreenshot(){prepare(region:false){[weak self] target in self?.takeScreenshot(target)}}
    func takeScreenshot(_ target:CaptureTarget){
        var selected=target;selected.window=nil;selected.frozenImage=nil
        if target.mode == .recording {beginRecording(selected);return}
        if target.mode == .longScreenshot {selected.frozenImage=target.frozenImage;beginLong(selected);return}
        CaptureDiagnostics.record(.captureBegin)
        if let image=target.frozenImage {
            do{CaptureDiagnostics.record(.captureComplete);if target.annotationRequested{showEditor(image,category:"截图",target:selected)}else{try finalizeScreenshot(image)}}
            catch{setBusy(false);report(error)}
            return
        }
        setBusy(false);report(CaptureFailure.message(L("冻结画面不可用，请保持鼠标在目标屏幕后重试。")))
    }

    func finalizeScreenshot(_ image:CGImage) throws {
        try ScreenshotDelivery.finalize(image,copyOnly:screenshotCopyOnly,copy:{image in
            guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{CaptureDiagnostics.record(.clipboardFailed);return false}
            NSPasteboard.general.clearContents();let ok=NSPasteboard.general.setData(data,forType:.png);CaptureDiagnostics.record(ok ? .clipboardOK : .clipboardFailed);return ok
        },save:{[weak self] image in self?.saveImage(image,category:"截图")})
        if screenshotCopyOnly {setBusy(false);statusMessage=L("已复制截图，未保存文件。");showFeedback(L("已复制 · 未保存文件"))}
    }
    func showEditor(_ image:CGImage,category:String,target:CaptureTarget?=nil){
        var region=target;region?.window=nil;region?.frozenImage=nil
        let onRecord:(()->Void)? = region.map { selected in { [weak self] in self?.editor=nil;self?.beginRecording(selected) } }
        let onLong:(()->Void)? = region.map { selected in { [weak self] in
            self?.editor=nil
            var target=selected;target.mode = .longScreenshot;target.frozenImage=image
            self?.beginLong(target)
        } }
        editor=CaptureEditor(image:image,onSave:{[weak self] image in self?.editor=nil;self?.saveImage(image,category:category)},onCancel:{[weak self] in self?.editor=nil;self?.setBusy(false);self?.statusMessage=L("已结束截图。")},onRecord:onRecord,onLong:onLong,
            beforeLong:onLong == nil ? nil : {[weak self] in
                guard let self else{return L("无法启动长截图，请重试。")}
                return self.prepareLongKeys()
            },copyOnly:screenshotCopyOnly)
        editor?.show()
    }
    func saveImage(_ image:CGImage,category:String){
        let root=storage.root;statusMessage=L("正在保存…");CaptureDiagnostics.record(.saveBegin)
        DispatchQueue.global(qos:.userInitiated).async {
            let result=autoreleasepool { Result {try CaptureStorage.export(CaptureStorage.writePNG(image),root:root,category:category)} }
            DispatchQueue.main.async {self.finishSave(result)}
        }
    }
    func finishSave(_ result:Result<URL,Error>){
        setBusy(false);switch result {case .success(let url):CaptureDiagnostics.record(.saveOK);lastSaved=url;statusMessage=L("已保存：%@", String(describing: url.lastPathComponent));showFeedback(L("已完成保存"));case .failure(let error):CaptureDiagnostics.record(.saveFailed,error:error);showFeedback(L("保存失败 · 原文件已保留"),failure:true);statusMessage=L("保存失败：%@\n原文件在轻截应用菜单「待保存文件」中，未丢弃。", String(describing: error.localizedDescription));showWindow()}
    }
    @objc func showDiagnostics(){let alert=NSAlert();alert.messageText=L("捕获诊断（最多 64 条）");alert.informativeText=CaptureDiagnostics.snapshot();alert.addButton(withTitle:L("关闭"));alert.runModal()}
    func showFeedback(_ text:String,failure:Bool=false){
        feedbackDismiss?.cancel();feedbackPanel?.close()
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:260,height:54),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear;panel.ignoresMouseEvents=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        let backdrop=NSVisualEffectView(frame:panel.contentView!.bounds);backdrop.material = .hudWindow;backdrop.state = .active;backdrop.wantsLayer=true;backdrop.layer?.cornerRadius=12
        let label=NSTextField(wrappingLabelWithString:text);label.textColor=failure ? .systemOrange : .labelColor;label.font = .systemFont(ofSize:14,weight:.medium);label.alignment = .center;label.maximumNumberOfLines=2
        let textHeight=min(CGFloat(42),label.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:244,height:42)).height ?? 22)
        label.frame=NSRect(x:8,y:(54-textHeight)/2,width:244,height:textHeight);backdrop.addSubview(label);panel.contentView=backdrop
        let screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main
        if let frame=screen?.visibleFrame {panel.setFrameOrigin(NSPoint(x:frame.midX-130,y:frame.minY+48))}
        panel.orderFrontRegardless();feedbackPanel=panel
        let dismiss=DispatchWorkItem{[weak self,weak panel] in panel?.close();if self?.feedbackPanel === panel{self?.feedbackPanel=nil;self?.feedbackDismiss=nil}}
        feedbackDismiss=dismiss;DispatchQueue.main.asyncAfter(deadline:.now()+(failure ? 5:2),execute:dismiss)
    }
    @objc func longScreenshot(){prepare(region:true,windowSnap:true,mode:.longScreenshot){[weak self] target in self?.takeScreenshot(target)}}
    func prepareLongKeys()->String? {
        guard !longSession.active,!longSession.draining else{return L("上次屏幕请求尚未结束，请退出后重开轻截。")}
        longKeys.action={[weak self] finish in if finish{self?.finishLong()}else{self?.cancelLong()}}
        if longKeys.active{return nil}
        guard longKeys.start() else {
            CaptureDiagnostics.record(.longShortcutUnavailable)
            return L("Enter 或 Esc 已被占用，未开始长截图。请换用普通截图或取消。")
        }
        CaptureDiagnostics.record(.longShortcutReady)
        return nil
    }
    func beginLong(_ selected:CaptureTarget){
        if let error=prepareLongKeys(){setBusy(false);report(CaptureFailure.message(error));return}
        var target=selected;target.window=nil;target.mode = .longScreenshot;target.frozenImage=nil
        longTarget=target
        let configuration=CaptureEngine.configuration(target:target,recording:false)
        let seed=selected.frozenImage.flatMap{
            $0.width==configuration.width && $0.height==configuration.height ? $0 : nil
        }
        selector.cancel(notify:false)
        window?.orderOut(nil);NSApp.deactivate()
        let snappedSource=selected.sourcePID.flatMap{NSRunningApplication(processIdentifier:$0)}
        if let source=snappedSource ?? captureSourceApplication,source.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            source.activate(options:[])
        }
        showLongBorder()
        longSession.start(seed:seed,allowFixedWindowBands:selected.snapWindowID != nil,prepare:{
            try await CaptureEngine.prepareLongFrameSource(target:target)
        }){[weak self] result,partial in
            guard let self else{return}
            self.longKeys.stop();self.dismissControls();self.longTarget=nil
            switch result {
            case .success(let image):self.saveImage(image,category:"长截图")
            case .failure(let error):
                if let partial {
                    self.showEditor(partial,category:"长截图")
                    self.showFeedback(L("最后画面未确认收录，请检查并保存已有部分。"),failure:true)
                }else{
                    self.setBusy(false)
                    self.statusMessage=error.localizedDescription
                    let hint=error is StitchError
                        ? L("没找到重叠画面。请重试，滚动时保留部分上一屏。")
                        : error.localizedDescription
                    self.showFeedback(hint,failure:true)
                }
            }
        }
    }
    func showLongBorder(){
        guard let target=longTarget,let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==target.display.displayID}) else{return}
        let rect=RecordingControlPlacement.globalCapture(localTopLeft:target.rect,screen:screen.frame)
        longBorder.show(capture:rect,screen:screen.frame)
    }
    func dismissControls(){
        longBorder.close()
        control?.orderOut(nil);control?.contentView=nil;control?.close();control=nil;longLabel=nil
    }
    @objc func cancelLong(){
        longSession.cancel();longKeys.stop();longTarget=nil;dismissControls();setBusy(false)
        statusMessage=L("已取消长截图，未保存。")
    }
    @objc func finishLong(){longSession.finish()}
    @objc func fullRecording(){prepare(region:false,mode:.recording){[weak self] target in self?.beginRecording(target)}}
    @objc func regionRecording(){prepare(region:true,mode:.recording){[weak self] target in self?.takeScreenshot(target)}}
    func beginRecording(_ target:CaptureTarget){
        recordingRoot=storage.root;recordingTarget=target;stopPending=false;updateRecordingControls(.starting)
        statusMessage=L("准备录屏…")
        let defaults=UserDefaults.standard
        let includeMic=defaults.bool(forKey:"recordingMicrophone"),includeSystemAudio=defaults.object(forKey:"audio") == nil || defaults.bool(forKey:"audio"),highQuality=defaults.integer(forKey:"quality")==1,frameRate=recordingFrameRate
        Task { @MainActor [self] in
            do{
                if includeMic {
                    let allowed:Bool
                    switch AVCaptureDevice.authorizationStatus(for:.audio) {
                    case .authorized: allowed=true
                    case .notDetermined: allowed=await AVCaptureDevice.requestAccess(for:.audio)
                    default: allowed=false
                    }
                    guard allowed else {throw CaptureFailure.message(L("麦克风权限未开启。请在系统设置允许轻截使用麦克风，或关闭麦克风录制后重试。"))}
                }
                try await Task.sleep(nanoseconds:300_000_000)
                try await recorder.start(target:target,systemAudio:includeSystemAudio,microphone:includeMic,highQuality:highQuality,frameRate:frameRate){[weak self] result in Task { @MainActor in self?.recordingFinished(result) }}
            }catch{resetRecording();setBusy(false);report(error)}
        }
    }
    func didStartRecording(){
        updateRecordingControls(.recording)
        recordStart=Date();statusMessage=recordingStopHint
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:250,height:60),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false);panel.title=L("轻截 · 正在录屏");panel.level = .floating;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isReleasedWhenClosed=false
        let stop=NSButton(title:L("■ 停止并保存"),target:self,action:#selector(stopRecording));stop.frame=NSRect(x:30,y:12,width:190,height:32);stop.setAccessibilityLabel(L("停止并保存录屏"));panel.contentView!.addSubview(stop)
        // Use the actual titled window size, including its titlebar. Do not place
        // controls over a full-screen recording even when exclusion is supported.
        let screens=NSScreen.screens
        if let target=recordingTarget,let index=screens.firstIndex(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.display.displayID}),
           let frame=RecordingControlPlacement.frame(size:panel.frame.size,capture:RecordingControlPlacement.globalCapture(localTopLeft:target.rect,screen:screens[index].frame),visibleScreens:screens.map(\.visibleFrame),recordedScreenIndex:index) {
            panel.setFrame(frame,display:false);panel.orderFrontRegardless();control=panel
        }else{
            panel.close();statusMessage=recordingStopHint
        }

    }
    var recordingStopHint:String {L("正在录屏。按 %@ 停止并保存；也可双击轻截应用图标打开停止按钮。", String(describing: UserDefaults.standard.string(forKey:"shortcutTitle") ?? "⌃ A"))}
    @objc func recordingScreensChanged(){
        // A removed display can make AppKit relocate windows over the capture.
        // Hide rather than risk placing controls into a changed screen layout.
        if recordingControlState == .recording {control?.orderOut(nil)}
        if longSession.active {
            longSession.fail(CaptureFailure.message(L("屏幕布局已变化，请重新截图。")))
        }
    }
    @objc func stopRecording(){
        guard recorder.active,!stopPending else{return};stopPending=true;updateRecordingControls(.stopping);statusMessage=L("保存中…");control?.orderOut(nil)
        Task { @MainActor in do {try await recorder.stop()}catch{stopPending=false;if recorder.active && recordStart != nil {updateRecordingControls(.recording)}else{resetRecording()};report(error)} }
    }
    func updateRecordingControls(_ state:RecordingControlState){
        recordingControlState=state
        settings?.mainStopButton.isHidden = state == .idle
        settings?.mainStopButton.isEnabled = state == .recording
        settings?.mainStopButton.title = state == .starting ? L("正在准备录屏…") : state == .stopping ? L("正在停止并保存…") : L("停止并保存")
        for item in stopMenuItems {item.isEnabled = state == .recording}
    }
    func validateMenuItem(_ menuItem:NSMenuItem)->Bool {
        if menuItem.action == #selector(stopRecording){return recordingControlState == .recording && !stopPending}
        return true
    }
    func resetRecording(){recordingTarget=nil;updateRecordingControls(.idle);recordStart=nil;dismissControls();stopPending=false}
    func recordingFinished(_ result:Result<URL,Error>){
        resetRecording()
        let destination=recordingRoot ?? storage.root;recordingRoot=nil
        switch result{
        case .success(let source):let root=destination;DispatchQueue.global(qos:.userInitiated).async{let saved=Result{try CaptureStorage.export(source,root:root,category:"录屏")};DispatchQueue.main.async{self.finishSave(saved)}}
        case .failure(let error):setBusy(false);statusMessage=L("录屏出错：%@。如有可恢复文件，可在「待保存文件」查看。", String(describing: error.localizedDescription));showWindow()
        }
    }
    @objc func quit(){NSApp.terminate(nil)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        if busy && signedInstaller?.mayTerminateForInstallation != true {let a=NSAlert();a.messageText=L("请先结束当前任务");a.informativeText=L("录屏请先停止并保存；长截图请保存或取消，避免丢失。");a.runModal();return .terminateCancel};updateTask?.cancel();return .terminateNow
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard sender === window else{return true}
        if shortcutMonitor != nil{endShortcut()}
        settings?.authorLinks.dismiss()
        settingsFrame=sender.frame
        settings=nil
        sender.delegate=nil;sender.orderOut(nil);sender.contentView=nil;sender.close()
        visibility.hide()
        return false
    }
    func windowWillClose(_ notification:Notification){if shortcutMonitor != nil {endShortcut()}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{
        guard !longSession.active else{return true}
        revealSettings();checkAutomaticallyIfDue();return true
    }
}
