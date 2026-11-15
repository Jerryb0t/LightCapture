import AppKit
@main struct AuthorLinksTests {
 @MainActor static func main(){
  NSApplication.shared.setActivationPolicy(.prohibited)
  func check(_ ok:Bool,_ reason:String){if !ok{fputs("FAIL: "+reason+"\n",stderr);exit(1)}}
  let app=AppDelegate();app.buildUI();app.window.contentView!.layoutSubtreeIfNeeded()
  let links=app.authorLinks;var opened:[URL]=[];links.openURL={opened.append($0);return true}
  links.resourceRoot=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Artwork")
  check(links.popover==nil && links.qrView==nil && links.linkButtons.isEmpty,"idle must allocate no popup/image")
  for destination in AuthorLinks.Destination.allCases {
   links.prepare(.follow)
   check(links.paymentPicker==nil && links.qrView==nil && links.linkButtons.count==2,"follow contains only profile links")
   links.openLink(links.linkButtons[destination.rawValue]);check(links.popover==nil,"successful link releases panel")
  }
  check(opened.map(\.absoluteString)==["https://x.com/Jerryb0t","https://github.com/Jerryb0t"],"author URL routing")
  weak var releasedImage:NSImage?
  weak var releasedView:SupportQRView?
  autoreleasepool {
  links.prepare(.support)
  check(links.linkButtons.isEmpty && links.qrView?.image==nil,"support contains no profile buttons or default QR")
  for (index,name) in ["SupportWeChatPay","SupportAlipay","SupportOKXPay"].enumerated(){
   links.paymentPicker?.selectItem(at:index+1);links.selectPayment()
   check(links.selectedPaymentResource==name && links.qrView?.image != nil && opened.count==2,"QR choice never opens browser")
  }
  releasedImage=links.qrView?.image
  releasedView=links.qrView
  links.dismiss()
  }
  check(links.popover==nil && links.qrView==nil && releasedView==nil && releasedImage==nil,"dismiss releases QR, view and controller")
  links.prepare(.support);check(links.selectedPaymentResource==nil && links.paymentPicker?.indexOfSelectedItem==0,"reopen resets selection");links.dismiss()
  let content=app.window.contentView!
  let a=links.followButton.convert(links.followButton.bounds,to:content),b=links.button.convert(links.button.bounds,to:content)
  check(content.bounds.contains(a) && content.bounds.contains(b) && !a.intersects(b),"footer fits without overlap")
  check(!app.window.isVisible,"test must not show UI")
  print("PASS isolated follow/support, exact URL routing, lazy startup, 3 unchanged QR choices, release on dismissal, repeat-open reset, footer bounds")
 }
}
