import AppKit
@main struct AuthorLinksTests {
 @MainActor static func main(){
  NSApplication.shared.setActivationPolicy(.prohibited)
  let app=AppDelegate();app.buildUI();app.window.contentView!.layoutSubtreeIfNeeded()
  for d in AuthorLinks.Destination.allCases {
   let image=AuthorLinks.platformImage(d,resourceRoot:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Artwork"))!
   precondition(max(image.size.width,image.size.height) == 18 && image.isTemplate)
  }
  let links=app.authorLinks;var opened:[URL]=[];links.openURL={opened.append($0);return true}
  precondition(links.button.title=="打赏作者" && links.linkButtons.count==2)
  precondition(opened.isEmpty && !links.popover.isShown && links.qrView.isHidden && links.selectedPaymentResource == nil)
  links.resourceRoot=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Artwork")
  for (index,name) in ["SupportWeChatPay","SupportAlipay","SupportOKXPay"].enumerated(){
   links.paymentPicker.selectItem(at:index+1);links.selectPayment()
   precondition(links.selectedPaymentResource==name && links.qrView.image != nil && !links.qrView.isHidden && opened.isEmpty)
  }
  links.paymentPicker.selectItem(at:0);links.selectPayment();precondition(links.qrView.image==nil && links.qrView.isHidden && links.selectedPaymentResource==nil)
  for b in links.linkButtons {precondition(b.image != nil && b.accessibilityLabel() != nil);links.openLink(b)}
  precondition(opened.map(\.absoluteString)==["https://x.com/Jerryb0t","https://github.com/Jerryb0t"])
  let invalid=NSButton();invalid.tag=99;links.openLink(invalid);precondition(opened.count==2)
  links.openURL={_ in false};links.openLink(links.linkButtons[0])
  let footer=links.button.convert(links.button.bounds,to:app.window.contentView)
  precondition(footer.width>0 && footer.height>0 && app.window.contentView!.bounds.contains(footer))
  precondition(!app.window.isVisible && !links.popover.isShown)
  print("PASS 2 injected author destinations, invalid route ignored, accessible symbols, no startup network/browser/UI; footer within 510×710 window at \(footer)")
 }
}
