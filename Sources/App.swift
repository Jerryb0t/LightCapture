import AppKit
import ScreenCaptureKit
import Carbon

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let visibility=AppVisibility()
    let authorLinks=AuthorLinks()
    let storage = CaptureStorage.shared
    let selector = SelectionController()
    let recorder = CaptureEngine()
    var buttons: [NSButton] = []
    let status = NSTextField(wrappingLabelWithString: L("只做截图和录屏。闲置时不捕获屏幕。"))
    let pathLabel = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: L("文件保存到所选目录后，由 iCloud 自行同步。录制中间文件保留在本机。"))
    let audio = NSButton(checkboxWithTitle: L("录制系统声音（不使用麦克风）"), target:nil, action:nil)
    let quality = NSPopUpButton()
    let copyOnly = NSButton(checkboxWithTitle:L("截图仅复制到剪贴板，不保存文件"),target:nil,action:nil)
    var loginItem:LoginItemManaging = SystemLoginItem()
    let loginCheckbox=NSButton(checkboxWithTitle:L("登录 Mac 后自动运行"),target:nil,action:nil)
    let loginHint=NSTextField(wrappingLabelWithString:"")
    private var changingLogin=false
    var busy = false
    var longTarget: CaptureTarget?
    var composite: CGImage?
    var control: NSPanel?
    var longLabel: NSTextField?
    var lastSaved: URL?
    var recordingRoot: URL?
    private var recordingTarget:CaptureTarget?
    enum RecordingControlState {case idle, starting, recording, stopping}
    private(set) var recordingControlState:RecordingControlState = .idle
    let mainStopButton=NSButton(title:L("停止并保存"),target:nil,action:nil)
    private(set) var stopMenuItems:[NSMenuItem]=[]
    var stopPending = false
    var recordStart: Date?
    var hotkeys: [EventHotKeyRef?] = []
    var hotkeyHandlerInstalled = false
    var editor: CaptureEditor?
    var shortcutMonitor: Any?
    var shortcutButton: NSButton!
    var shortcutLabel: NSTextField!
    let contentRequest=DeadlineRequest<PreparedCapture>()
    let screenshotRequest=DeadlineRequest<CGImage>()
    private let cancelPreparationButton=NSButton(title:L("取消准备 Esc"),target:nil,action:nil)
    private var feedbackPanel:NSPanel?
    private var feedbackDismiss:DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let login=LoginLaunch.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
        visibility.start(login:login)
        buildUI(); buildMenu(); registerHotkeys()
        if !login{showWindow()}
        NotificationCenter.default.addObserver(self,selector:#selector(recordingScreensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
    }
    func buildUI() {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:710),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title=L("轻截"); window.center(); window.delegate=self; window.isReleasedWhenClosed=false
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
        shortcutLabel=NSTextField(labelWithString:L("截图快捷键：") + (UserDefaults.standard.string(forKey:"shortcutTitle") ?? "⌃ A"))
        shortcutLabel.font = .systemFont(ofSize:12)
        shortcutButton=NSButton(title:L("修改…"),target:self,action:#selector(changeShortcut))
        let shortcutRow=NSStackView(views:[shortcutLabel,shortcutButton]);shortcutRow.spacing=12;root.addArrangedSubview(shortcutRow)
        let line=NSBox();line.boxType = .separator;root.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let pathRow=NSStackView();pathRow.orientation = .horizontal;pathRow.spacing=8
        let label=NSTextField(labelWithString:L("保存位置"));label.font = .systemFont(ofSize:13,weight:.medium);pathRow.addArrangedSubview(label)
        let change=NSButton(title:L("选择文件夹…"),target:self,action:#selector(chooseFolder));pathRow.addArrangedSubview(change)
        let open=NSButton(title:L("打开"),target:self,action:#selector(openFolder));pathRow.addArrangedSubview(open)
        root.addArrangedSubview(pathRow)
        pathLabel.stringValue=storage.root.path;pathLabel.font = .systemFont(ofSize:11);pathLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(pathLabel);pathLabel.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        quality.addItems(withTitles:[L("标准 · 30 fps / 最长边 1920"), L("高清 · 30 fps / 最长边 3840")])
        quality.selectItem(at:UserDefaults.standard.integer(forKey:"quality"));quality.target=self;quality.action=#selector(settingsChanged)
        copyOnly.state=UserDefaults.standard.bool(forKey:"copyOnly") ? .on : .off;copyOnly.target=self;copyOnly.action=#selector(settingsChanged)
        let settings=NSStackView(views:[quality,audio,copyOnly]);settings.orientation = .vertical;settings.alignment = .leading;settings.spacing=7
        audio.state=UserDefaults.standard.bool(forKey:"audio") ? .on : .off;audio.target=self;audio.action=#selector(settingsChanged)
        loginCheckbox.target=self;loginCheckbox.action=#selector(toggleLoginItem)
        loginHint.font = .systemFont(ofSize:11);loginHint.textColor = .secondaryLabelColor
        settings.addArrangedSubview(loginCheckbox);settings.addArrangedSubview(loginHint);loginHint.widthAnchor.constraint(lessThanOrEqualToConstant:460).isActive=true
        root.addArrangedSubview(settings);refreshLoginItem()
        mainStopButton.target=self;mainStopButton.action=#selector(stopRecording);mainStopButton.bezelStyle = .rounded;mainStopButton.setAccessibilityLabel(L("停止并保存录屏"));mainStopButton.isHidden=true;mainStopButton.isEnabled=false;root.addArrangedSubview(mainStopButton)
        cancelPreparationButton.target=self;cancelPreparationButton.action=#selector(cancelPreparation);cancelPreparationButton.keyEquivalent="\u{1b}";cancelPreparationButton.keyEquivalentModifierMask=[];cancelPreparationButton.isHidden=true;root.addArrangedSubview(cancelPreparationButton)
        status.font = .systemFont(ofSize:12);root.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        detail.font = .systemFont(ofSize:10);detail.textColor = .secondaryLabelColor;root.addArrangedSubview(detail);detail.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let footer=NSStackView(views:[authorLinks.followButton,authorLinks.button]);footer.spacing=20
        root.addArrangedSubview(footer)
        selector.failure = {[weak self] error in self?.setBusy(false);self?.report(error)}
        recorder.started = { [weak self] in Task { @MainActor in self?.didStartRecording() } }
    }
    func actionButton(_ title:String,symbol:String,action:Selector)->NSButton {
        let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.image=NSImage(systemSymbolName:symbol,accessibilityDescription:title);b.imagePosition = .imageLeading;b.font = .systemFont(ofSize:14,weight:.medium);buttons.append(b);return b
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
            var identifier=EventHotKeyID();GetEventParameter(event,UInt32(kEventParamDirectObject),UInt32(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&identifier)
            DispatchQueue.main.async {
                guard let app=NSApp.delegate as? AppDelegate else{return}
                switch identifier.id {case 1:app.handleCaptureShortcut();case 2:app.longScreenshot();case 3:app.fullRecording();case 4:app.regionRecording();default:break}
            };return noErr
        },1,&type,nil,nil)
        hotkeyHandlerInstalled = true
        }
        let firstKey = UserDefaults.standard.object(forKey:"shortcutKey") == nil ? 0 : UserDefaults.standard.integer(forKey:"shortcutKey")
        let firstMods = UserDefaults.standard.object(forKey:"shortcutMods") == nil ? UInt32(controlKey) : UInt32(UserDefaults.standard.integer(forKey:"shortcutMods"))
        let keys:[(Int,UInt32)] = [(firstKey,firstMods)]
        for (index,pair) in keys.enumerated() { var ref:EventHotKeyRef?; let id=EventHotKeyID(signature:0x4C434150,id:UInt32(index+1));let result=RegisterEventHotKey(UInt32(pair.0),pair.1,id,GetApplicationEventTarget(),0,&ref);if result == noErr {hotkeys.append(ref)} }
        if hotkeys.count != 1 {status.stringValue=L("快捷键存在冲突，请修改快捷键；仍可点击按钮使用。")}
    }
    enum ShortcutAction {case capture,stop,ignore}
    var captureShortcutAction:ShortcutAction {
        if shortcutMonitor != nil{return .ignore}
        if recordingControlState == .recording && !stopPending{return .stop}
        return busy || recordingControlState != .idle ? .ignore : .capture
    }
    func handleCaptureShortcut(){switch captureShortcutAction {case .capture:screenshot();case .stop:stopRecording();case .ignore:break}}
    func refreshLoginItem(){let value=LoginLaunch.presentation(loginItem.status);loginCheckbox.allowsMixedState = value.0 == .mixed;loginCheckbox.state=value.0;loginHint.stringValue=value.1;loginCheckbox.isEnabled = !changingLogin}
    @objc func toggleLoginItem(){
        guard !changingLogin else{return};let enable=loginCheckbox.state == .on;changingLogin=true;loginCheckbox.isEnabled=false
        Task{@MainActor in
            do{if enable {try loginItem.enable()}else{try await loginItem.disable()};changingLogin=false;refreshLoginItem()}
            catch{changingLogin=false;refreshLoginItem();loginHint.stringValue=L("设置失败：")+error.localizedDescription}
        }
    }
    func applicationDidBecomeActive(_ notification:Notification){if window != nil{refreshLoginItem()}}
    @objc func changeShortcut(){
        guard !busy,shortcutMonitor == nil else{return}
        for ref in hotkeys {if let ref {UnregisterEventHotKey(ref)}};hotkeys.removeAll()
        shortcutButton.title=L("请按组合键…");status.stringValue=L("按新的截图组合键（需 ⌃ / ⌥ / ⌘），Esc 取消。若浮引占用同一快捷键，请自行调整其中一个。")
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
            self.shortcutLabel.stringValue=L("截图快捷键：")+title;self.endShortcut();return nil
        }
    }
    func endShortcut(){if let monitor=shortcutMonitor{NSEvent.removeMonitor(monitor)};shortcutMonitor=nil;shortcutButton.title=L("修改…");registerHotkeys()}

    @objc func settingsChanged(){UserDefaults.standard.set(quality.indexOfSelectedItem,forKey:"quality");UserDefaults.standard.set(audio.state == .on,forKey:"audio");UserDefaults.standard.set(copyOnly.state == .on,forKey:"copyOnly")}
    @objc func revealSettings(){visibility.reopen();showWindow()}
    @objc func showWindow(){window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func chooseFolder(){
        guard !busy else{return};let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false;panel.message=L("选择保存根文件夹，将自动分为截图、长截图和录屏。");panel.directoryURL=storage.root
        panel.beginSheetModal(for:window){ [weak self] response in
            guard response == .OK,let url=panel.url,let self else{return}
            do{try self.storage.select(url);self.pathLabel.stringValue=url.path}catch{self.report(error)}
        }
    }
    @objc func openFolder(){do{try FileManager.default.createDirectory(at:storage.root,withIntermediateDirectories:true);NSWorkspace.shared.open(storage.root)}catch{report(error)}}
    @objc func openRecovery(){do{try FileManager.default.createDirectory(at:CaptureStorage.recoveryDirectory,withIntermediateDirectories:true);NSWorkspace.shared.open(CaptureStorage.recoveryDirectory)}catch{report(error)}}
    func setBusy(_ value:Bool){busy=value;for b in buttons{b.isEnabled = !value};quality.isEnabled = !value;audio.isEnabled = !value;copyOnly.isEnabled = !value;shortcutButton.isEnabled = !value;if !value{visibility.finished()}}
    func report(_ error:Error){status.stringValue=error.localizedDescription;showWindow()}
    func permission()->Bool{
        if CGPreflightScreenCaptureAccess(){return true}
        let alert=NSAlert();alert.messageText=L("需要屏幕录制权限");alert.informativeText=L("截图和录屏需要 macOS 允许轻截读取屏幕。只在你主动开始时捕获，不在后台持续抓屏。请在系统设置中自行开启，返回后再试。");alert.addButton(withTitle:L("请求权限"));alert.addButton(withTitle:L("取消"))
        if alert.runModal() == .alertFirstButtonReturn { _=CGRequestScreenCaptureAccess() }
        return false
    }
    @objc func cancelPreparation(){
        guard contentRequest.pending || screenshotRequest.pending else{return}
        contentRequest.cancel();screenshotRequest.cancel();cancelPreparationButton.isHidden=true
        CaptureDiagnostics.record(.cancel);setBusy(false);status.stringValue=L("已取消准备。");showFeedback(L("已取消"))
    }
    func prepare(region:Bool,windowSnap:Bool=false,mode:CaptureMode = .screenshot,then:@escaping(CaptureTarget)->Void){
        guard !busy,shortcutMonitor == nil else{return}
        // Preserve third-party transient panels until pixels and candidates are frozen.
        setBusy(true);guard permission() else{setBusy(false);return}
        let restoreLaunchWindow=window.isVisible
        status.stringValue=L("正在读取可用窗口…（最多等待 8 秒）");cancelPreparationButton.isHidden=false
        CaptureDiagnostics.record(.windowListBegin)
        contentRequest.start(seconds:8,operation:{try await FrozenCapture.prepare(freeze:region || mode == .screenshot,liveFallback:mode != .screenshot)}){[weak self] result in
            guard let self else{return};self.cancelPreparationButton.isHidden=true
            switch result {
            case .failure(let error):
                CaptureDiagnostics.record(.windowListFailed,error:error);self.setBusy(false);self.showFeedback(L("读取窗口失败，可重试"),failure:true);self.report(error)
            case .success(let prepared):
                let content=prepared.content
                self.authorLinks.dismiss();self.feedbackDismiss?.cancel();self.feedbackDismiss=nil;self.feedbackPanel?.close();self.feedbackPanel=nil
                CaptureDiagnostics.record(.windowListComplete);self.window.orderOut(nil)
                if region {
                    self.selector.begin(displays:content.displays,availableWindows:windowSnap ? content.windows : [],mode:mode,frames:prepared.frames,windowOrder:windowSnap ? prepared.order : [],notice:prepared.notice,allowsScreenshot:prepared.screenshotAvailable){[weak self] target in
                        guard let self else{return}
                        if let target{then(target)}else{self.setBusy(false);self.status.stringValue=L("已取消。");if restoreLaunchWindow && !self.visibility.background{self.showWindow()}}
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
        if target.mode == .longScreenshot {beginLong(selected);return}
        CaptureDiagnostics.record(.captureBegin)
        if let image=target.frozenImage {
            do{CaptureDiagnostics.record(.captureComplete);if target.annotationRequested{showEditor(image,category:"截图",target:selected)}else{try finalizeScreenshot(image)}}
            catch{setBusy(false);report(error)}
            return
        }
        setBusy(false);report(CaptureFailure.message(L("冻结画面不可用，请保持鼠标在目标屏幕后重试。")))
    }

    func finalizeScreenshot(_ image:CGImage) throws {
        try ScreenshotDelivery.finalize(image,copyOnly:copyOnly.state == .on,copy:{image in
            guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{CaptureDiagnostics.record(.clipboardFailed);return false}
            NSPasteboard.general.clearContents();let ok=NSPasteboard.general.setData(data,forType:.png);CaptureDiagnostics.record(ok ? .clipboardOK : .clipboardFailed);return ok
        },save:{[weak self] image in self?.saveImage(image,category:"截图")})
        if copyOnly.state == .on {setBusy(false);status.stringValue=L("已复制截图，未保存文件。");showFeedback(L("已复制 · 未保存文件"))}
    }
    func showEditor(_ image:CGImage,category:String,target:CaptureTarget?=nil){
        var region=target;region?.window=nil;region?.frozenImage=nil
        let onRecord:(()->Void)? = region.map { selected in { [weak self] in self?.editor=nil;self?.beginRecording(selected) } }
        let onLong:(()->Void)? = region.map { selected in { [weak self] in self?.editor=nil;self?.beginLong(selected) } }
        editor=CaptureEditor(image:image,onSave:{[weak self] image in self?.editor=nil;self?.saveImage(image,category:category)},onCancel:{[weak self] in self?.editor=nil;self?.setBusy(false);self?.status.stringValue=L("已结束截图。")},onRecord:onRecord,onLong:onLong,copyOnly:copyOnly.state == .on)
        editor?.show()
    }
    func saveImage(_ image:CGImage,category:String){
        let root=storage.root;status.stringValue=L("正在保存…");CaptureDiagnostics.record(.saveBegin)
        DispatchQueue.global(qos:.userInitiated).async {
            let result=autoreleasepool { Result {try CaptureStorage.export(CaptureStorage.writePNG(image),root:root,category:category)} }
            DispatchQueue.main.async {self.finishSave(result)}
        }
    }
    func finishSave(_ result:Result<URL,Error>){
        setBusy(false);switch result {case .success(let url):CaptureDiagnostics.record(.saveOK);lastSaved=url;status.stringValue=L("已保存：%@", String(describing: url.lastPathComponent));showFeedback(L("已完成保存"));case .failure(let error):CaptureDiagnostics.record(.saveFailed,error:error);showFeedback(L("保存失败 · 原文件已保留"),failure:true);status.stringValue=L("保存失败：%@\n原文件在轻截应用菜单「待保存文件」中，未丢弃。", String(describing: error.localizedDescription));showWindow()}
    }
    @objc func showDiagnostics(){let alert=NSAlert();alert.messageText=L("捕获诊断（最多 64 条）");alert.informativeText=CaptureDiagnostics.snapshot();alert.addButton(withTitle:L("关闭"));alert.runModal()}
    func showFeedback(_ text:String,failure:Bool=false){
        feedbackDismiss?.cancel();feedbackPanel?.close()
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:260,height:54),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear;panel.ignoresMouseEvents=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        let backdrop=NSVisualEffectView(frame:panel.contentView!.bounds);backdrop.material = .hudWindow;backdrop.state = .active;backdrop.wantsLayer=true;backdrop.layer?.cornerRadius=12
        let label=NSTextField(labelWithString:text);label.textColor=failure ? .systemOrange : .labelColor;label.font = .systemFont(ofSize:14,weight:.medium);label.alignment = .center;label.frame=NSRect(x:8,y:17,width:244,height:22);backdrop.addSubview(label);panel.contentView=backdrop
        let screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main
        if let frame=screen?.visibleFrame {panel.setFrameOrigin(NSPoint(x:frame.midX-130,y:frame.minY+48))}
        panel.orderFrontRegardless();feedbackPanel=panel
        let dismiss=DispatchWorkItem{[weak self,weak panel] in panel?.close();if self?.feedbackPanel === panel{self?.feedbackPanel=nil;self?.feedbackDismiss=nil}}
        feedbackDismiss=dismiss;DispatchQueue.main.asyncAfter(deadline:.now()+(failure ? 5:2),execute:dismiss)
    }
    @objc func longScreenshot(){prepare(region:true,mode:.longScreenshot){[weak self] target in self?.takeScreenshot(target)}}
    func beginLong(_ target:CaptureTarget){
        longTarget=target
        Task { @MainActor in
            do{try await Task.sleep(nanoseconds:200_000_000);composite=try await CaptureEngine.screenshot(target:target);lastLongSignature=try composite.map {try LongFrameProcessor.signature($0)};showLongControls()}
            catch{longTarget=nil;setBusy(false);report(error)}
        }
    }
    func showLongControls(){
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:440,height:154),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false);panel.title=L("长截图 · 滚动自动拼接");panel.level = .floating;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.frame=NSRect(x:16,y:12,width:408,height:124)
        let label=NSTextField(wrappingLabelWithString:L("缓慢向下滚动，停稳后自动拼接。\n避开固定页头、动画和滚动条；可手动接下一屏。"));label.font = .systemFont(ofSize:12);stack.addArrangedSubview(label);longLabel=label
        let row=NSStackView(views:[NSButton(title:L("接下一屏"),target:self,action:#selector(appendLong)),NSButton(title:L("预览并保存"),target:self,action:#selector(previewLong)),NSButton(title:L("取消"),target:self,action:#selector(cancelLong))]);row.spacing=8;stack.addArrangedSubview(row)
        panel.contentView!.addSubview(stack);panel.center();panel.orderFrontRegardless();control=panel
        startLongSampling()
    }
    func dismissControls(){
        control?.orderOut(nil);control?.contentView=nil;control?.close();control=nil;longLabel=nil
    }
    let longSampler = SessionSampler<LongFrameResult>()
    var lastLongSignature:Data?
    func startLongSampling(){
        longSampler.start(operation:{ [weak self] in
            guard let self,let target=self.longTarget,let previous=self.composite else {throw CancellationError()}
            let image=try await CaptureEngine.screenshot(target:target)
            let signature=self.lastLongSignature
            return try await Task.detached(priority:.utility){try LongFrameProcessor.process(previous:previous,next:image,lastSignature:signature)}.value
        },receive:{[weak self] frame in
            guard let self else{return}
            self.lastLongSignature=frame.signature
            let result=frame.stitch
            // Unchanged frames do not replace the composite or grow the image.
            if result.addedRows > 0 {
                self.composite=result.image
                self.longLabel?.stringValue=L("已自动拼接 · %@ × %@ 像素\n缓慢向下滚动，停稳后自动接图。", String(describing: result.image.width), String(describing: result.image.height))
            }
        },failure:{[weak self] error in
            self?.longLabel?.stringValue=L("%@\n请慢一点滚动并保持重叠；也可点「接下一屏」。", String(describing: error.localizedDescription))
            if let stitch=error as? StitchError {
                if case .imageTooLarge=stitch {self?.longSampler.stop()}
            } else {self?.longSampler.stop()}
        })
    }
    @objc func appendLong(){longSampler.sample()}
    @objc func cancelLong(){longSampler.stop();lastLongSignature=nil;composite=nil;longTarget=nil;dismissControls();setBusy(false);status.stringValue=L("已取消长截图，未保存。");if !visibility.background{showWindow()}}
    @objc func previewLong(){
        guard let image=composite else{return};longSampler.stop();dismissControls()
        let preview=NSPanel(contentRect:NSRect(x:0,y:0,width:650,height:650),styleMask:[.titled],backing:.buffered,defer:false);preview.title=L("检查长截图后保存");preview.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:NSRect(x:16,y:58,width:618,height:575));scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;scroll.borderType = .bezelBorder
        let ratio=min(1,600.0/CGFloat(image.width));let size=NSSize(width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio)
        let view=NSImageView(frame:NSRect(origin:.zero,size:size));view.image=NSImage(cgImage:image,size:size);view.imageScaling = .scaleProportionallyUpOrDown;scroll.documentView=view
        preview.contentView!.addSubview(scroll)
        let row=NSStackView(views:[NSButton(title:L("保存 PNG"),target:self,action:#selector(saveLong)),NSButton(title:L("返回继续拼接"),target:self,action:#selector(resumeLong)),NSButton(title:L("取消"),target:self,action:#selector(cancelLong))]);row.frame=NSRect(x:16,y:14,width:618,height:30);row.spacing=12;preview.contentView!.addSubview(row)
        preview.center();preview.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);control=preview
    }
    @objc func resumeLong(){dismissControls();showLongControls()}
    @objc func saveLong(){guard let image=composite else{return};longSampler.stop();dismissControls();composite=nil;lastLongSignature=nil;longTarget=nil;showEditor(image,category:"长截图")}
    @objc func fullRecording(){prepare(region:false,mode:.recording){[weak self] target in self?.beginRecording(target)}}
    @objc func regionRecording(){prepare(region:true,mode:.recording){[weak self] target in self?.takeScreenshot(target)}}
    func beginRecording(_ target:CaptureTarget){
        recordingRoot=storage.root;recordingTarget=target;stopPending=false;updateRecordingControls(.starting)
        status.stringValue=L("准备录屏…")
        Task { @MainActor [self] in
            do{
                try await Task.sleep(nanoseconds:300_000_000)
                try await recorder.start(target:target,systemAudio:audio.state == .on,highQuality:quality.indexOfSelectedItem==1){[weak self] result in Task { @MainActor in self?.recordingFinished(result) }}
            }catch{resetRecording();setBusy(false);report(error)}
        }
    }
    func didStartRecording(){
        updateRecordingControls(.recording)
        recordStart=Date();status.stringValue=recordingStopHint
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:250,height:60),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false);panel.title=L("轻截 · 正在录屏");panel.level = .floating;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isReleasedWhenClosed=false
        let stop=NSButton(title:L("■ 停止并保存"),target:self,action:#selector(stopRecording));stop.frame=NSRect(x:30,y:12,width:190,height:32);stop.setAccessibilityLabel(L("停止并保存录屏"));panel.contentView!.addSubview(stop)
        // Use the actual titled window size, including its titlebar. Do not place
        // controls over a full-screen recording even when exclusion is supported.
        let screens=NSScreen.screens
        if let target=recordingTarget,let index=screens.firstIndex(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.display.displayID}),
           let frame=RecordingControlPlacement.frame(size:panel.frame.size,capture:RecordingControlPlacement.globalCapture(localTopLeft:target.rect,screen:screens[index].frame),visibleScreens:screens.map(\.visibleFrame),recordedScreenIndex:index) {
            panel.setFrame(frame,display:false);panel.orderFrontRegardless();control=panel
        }else{
            panel.close();status.stringValue=recordingStopHint
        }

    }
    var recordingStopHint:String {L("正在录屏。按 %@ 停止并保存；也可双击轻截应用图标打开停止按钮。", String(describing: UserDefaults.standard.string(forKey:"shortcutTitle") ?? "⌃ A"))}
    @objc func recordingScreensChanged(){
        // A removed display can make AppKit relocate windows over the capture.
        // Hide rather than risk placing controls into a changed screen layout.
        if recordingControlState == .recording {control?.orderOut(nil)}
    }
    @objc func stopRecording(){
        guard recorder.active,!stopPending else{return};stopPending=true;updateRecordingControls(.stopping);status.stringValue=L("保存中…");control?.orderOut(nil)
        Task { @MainActor in do {try await recorder.stop()}catch{stopPending=false;if recorder.active && recordStart != nil {updateRecordingControls(.recording)}else{resetRecording()};report(error)} }
    }
    func updateRecordingControls(_ state:RecordingControlState){
        recordingControlState=state
        mainStopButton.isHidden = state == .idle
        mainStopButton.isEnabled = state == .recording
        mainStopButton.title = state == .starting ? L("正在准备录屏…") : state == .stopping ? L("正在停止并保存…") : L("停止并保存")
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
        case .failure(let error):setBusy(false);status.stringValue=L("录屏出错：%@。如有可恢复文件，可在「待保存文件」查看。", String(describing: error.localizedDescription));showWindow()
        }
    }
    @objc func quit(){NSApp.terminate(nil)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        if busy {let a=NSAlert();a.messageText=L("请先结束当前任务");a.informativeText=L("录屏请先停止并保存；长截图请保存或取消，避免丢失。");a.runModal();return .terminateCancel};return .terminateNow
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard sender === window else{return true}
        if shortcutMonitor != nil{endShortcut()};authorLinks.dismiss();sender.orderOut(nil);visibility.hide();return false
    }
    func windowWillClose(_ notification:Notification){if shortcutMonitor != nil {endShortcut()}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{revealSettings();return true}
}
