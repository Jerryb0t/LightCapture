import AppKit
private func precondition(_ condition:@autoclosure ()->Bool,_ message:@autoclosure ()->String="check failed") {
    if !condition(){fputs("FAIL: "+message()+"\n",stderr);exit(1)}
}
@main struct LocalizationTests {
 @MainActor static func main(){
  setbuf(stdout,nil)
  let resourcePath=CommandLine.arguments[1];let language=CommandLine.arguments[2]
  let resources=Bundle(path:resourcePath)!
  Localization.bundle=Bundle(path:resourcePath+"/Contents/Resources/"+language+".lproj")!
  NSApplication.shared.setActivationPolicy(.prohibited)
  let expected=language == "en" ? "Support the Author" : "打赏作者"
  precondition(L("打赏作者")==expected,"wrong language: "+L("打赏作者"))
  let root=resources.resourceURL!
  var resourceKeys:Set<String>?
  for language in ["en","zh-Hans"] {
   let url=root.appendingPathComponent(language+".lproj/Localizable.strings")
   let dict=NSDictionary(contentsOf:url) as! [String:String]
   precondition(dict.count >= 161)
   if let expected=resourceKeys {precondition(expected == Set(dict.keys),"missing translations")}
   resourceKeys=Set(dict.keys)
   for (key,value) in dict {precondition(key.components(separatedBy:"%@").count==value.components(separatedBy:"%@").count)}
  }
  let app=AppDelegate();app.buildUI();app.window.contentView!.layoutSubtreeIfNeeded()
  precondition(app.authorLinks.button.title=="☕ "+expected)
  precondition(app.frameRatePicker.itemArray.map(\.tag)==[24,30,60])
  precondition(!app.updateCheckButton.isHidden && app.updateReleaseButton.isHidden)
  precondition(app.audio.title == L("录制系统声音") && app.microphone.title == L("录制麦克风"))
  precondition(app.updateCheckButton.title==L("检查更新…"))
  precondition(app.automaticUpdateCheckbox.title==L("启动时自动检查更新"))
  let content=app.window.contentView!,stack=content.subviews.compactMap{$0 as? NSStackView}.first!
  precondition(stack.frame.width<=content.bounds.width && stack.frame.minY>=0,"settings overflow")
  for b in app.buttons {precondition(b.intrinsicContentSize.width<=b.frame.width+2,"button text too wide: "+b.title)}
  let footer=app.authorLinks.button.convert(app.authorLinks.button.bounds,to:content)
  precondition(content.bounds.contains(footer))
  app.authorLinks.resourceRoot=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Artwork")
  app.authorLinks.prepare(.support)
  for index in 1...3 {
   app.authorLinks.paymentPicker!.selectItem(at:index);app.authorLinks.selectPayment()
   let panel=app.authorLinks.popover!.contentViewController!.view
   for view in panel.subviews where !view.isHidden {
    precondition(panel.bounds.contains(view.frame),"support content outside panel")
    if let label=view as? NSTextField {precondition((label.cell?.cellSize(forBounds:label.bounds).height ?? 0)<=label.bounds.height+2,"support text clipped")}
   }
   precondition(app.authorLinks.qrView!.frame.maxY<app.authorLinks.paymentPicker!.frame.minY)
  }
  app.authorLinks.dismiss()
  app.authorLinks.prepare(.follow)
  precondition(app.authorLinks.paymentPicker == nil && app.authorLinks.qrView == nil)
  app.authorLinks.dismiss()
  for state:AppDelegate.RecordingControlState in [.starting,.recording,.stopping,.idle] {
   app.updateRecordingControls(state);app.window.contentView!.layoutSubtreeIfNeeded()
   let footer=app.authorLinks.button.convert(app.authorLinks.button.bounds,to:content)
   precondition(content.bounds.contains(footer),"busy state pushes footer out of window")
   precondition(content.bounds.contains(app.updateCheckButton.convert(app.updateCheckButton.bounds,to:content)))
  }
  app.updateStatus.stringValue=L("发现 %@。自动安装尚未启用，可查看官方发布。","v0.2.1")
  app.updateStatus.isHidden=false;app.updateReleaseButton.isHidden=false;content.layoutSubtreeIfNeeded()
  precondition(content.bounds.contains(app.updateStatus.convert(app.updateStatus.bounds,to:content)),"update status outside window")
  precondition(content.bounds.contains(app.automaticUpdateCheckbox.convert(app.automaticUpdateCheckbox.bounds,to:content)),"auto-check switch outside window")
  precondition(!app.window.isVisible && app.authorLinks.popover?.isShown != true)
  precondition(L("已保存：%@","sample.png").contains("sample.png"))
  print("PASS "+expected+": \(resourceKeys?.count ?? 0) resource keys/format counts, injected resource-bundle lookup, injected filename, settings/actions/footer fit, no visible UI")
 }
}
