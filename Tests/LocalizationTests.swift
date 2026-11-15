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
  for language in ["en","zh-Hans"] {
   let url=root.appendingPathComponent(language+".lproj/Localizable.strings")
   let dict=NSDictionary(contentsOf:url) as! [String:String]
   precondition(dict.count==161)
   for (key,value) in dict {precondition(key.components(separatedBy:"%@").count==value.components(separatedBy:"%@").count)}
  }
  let app=AppDelegate();app.buildUI();app.window.contentView!.layoutSubtreeIfNeeded()
  precondition(app.authorLinks.button.title=="☕ "+expected)
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
  }
  precondition(!app.window.isVisible && app.authorLinks.popover?.isShown != true)
  precondition(L("已保存：%@","sample.png").contains("sample.png"))
  print("PASS "+expected+": 161 resource keys/format counts, injected resource-bundle lookup, injected filename, settings/actions/footer fit, no visible UI")
 }
}
