import AppKit

@MainActor final class SupportQRView:NSView {
    var image:NSImage? {didSet{needsDisplay=true}}
    override func draw(_ dirtyRect:NSRect){
        NSColor.white.setFill();bounds.fill()
        guard let image else{return}
        NSGraphicsContext.current?.imageInterpolation = .none
        let scale=min(bounds.width/image.size.width,bounds.height/image.size.height)
        let size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
        image.draw(in:NSRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height))
    }
}
@MainActor final class AuthorLinks:NSObject {
    enum Destination: Int, CaseIterable {
        case x, github
        var url:URL {URL(string:self == .x ? "https://x.com/Jerryb0t" : "https://github.com/Jerryb0t")!}
        var title:String {self == .x ? "X · Jerryb0t" : "GitHub · Jerryb0t"}
        var symbol:String {self == .x ? "xmark" : "chevron.left.forwardslash.chevron.right"}
    }
    let button=NSButton(title:L("打赏作者"),target:nil,action:nil)
    let popover=NSPopover()
    private(set) var linkButtons:[NSButton]=[]
    let paymentPicker=NSPopUpButton()
    let qrView=SupportQRView()
    var resourceRoot:URL? = Bundle.main.resourceURL
    var openURL:(URL)->Bool = {NSWorkspace.shared.open($0)}
    private let intro=NSTextField(wrappingLabelWithString:L("喜欢轻截？可以关注作者，或在项目页点个 Star。"))
    private let paymentNote=NSTextField(wrappingLabelWithString:L("打赏完全自愿。请用对应支付应用扫码，并在付款前核对收款人。轻截不会发起付款或确认到账。"))
    private let errorLabel=NSTextField(wrappingLabelWithString:"")
    private(set) var selectedPaymentResource:String?
    override init(){
        super.init()
        button.target=self;button.action=#selector(show);button.bezelStyle = .inline
        button.font = .systemFont(ofSize:12);button.image=NSImage(systemSymbolName:"heart",accessibilityDescription:nil);button.imagePosition = .imageLeading
        button.setAccessibilityLabel(L("打赏作者，查看作者链接及自愿打赏收款码"))
        let controller=NSViewController();controller.view=NSView(frame:NSRect(x:0,y:0,width:310,height:206))
        intro.font = .systemFont(ofSize:12);controller.view.addSubview(intro)
        for destination in Destination.allCases {
            let link=NSButton(title:destination.title,target:self,action:#selector(openLink(_:)))
            link.tag=destination.rawValue;link.bezelStyle = .rounded;link.alignment = .left
            link.image=Self.platformImage(destination);link.imagePosition = .imageLeading
            link.setAccessibilityLabel(L("在浏览器打开作者的 %@ 主页", String(describing: destination == .x ? "X" : "GitHub")))
            controller.view.addSubview(link);linkButtons.append(link)
        }
        paymentPicker.addItems(withTitles:[L("自愿打赏：选择收款码…"),"微信支付 / WeChat Pay","支付宝 / Alipay","OKX Pay"])
        paymentPicker.target=self;paymentPicker.action=#selector(selectPayment)
        paymentPicker.setAccessibilityLabel(L("选择自愿打赏收款码"));controller.view.addSubview(paymentPicker)
        qrView.setAccessibilityElement(true);qrView.setAccessibilityRole(.image);qrView.isHidden=true;controller.view.addSubview(qrView)
        paymentNote.font = .systemFont(ofSize:11);paymentNote.isHidden=true;controller.view.addSubview(paymentNote)
        errorLabel.font = .systemFont(ofSize:10);errorLabel.textColor = .secondaryLabelColor;controller.view.addSubview(errorLabel)
        popover.contentViewController=controller;popover.behavior = .transient;layout(expanded:false)
    }
    private func layout(expanded:Bool){
        let height:CGFloat=expanded ? 510 : 206
        popover.contentViewController?.view.setFrameSize(NSSize(width:310,height:height))
        intro.frame=NSRect(x:16,y:height-56,width:278,height:44)
        for (index,link) in linkButtons.enumerated(){link.frame=NSRect(x:16,y:height-92-CGFloat(index)*36,width:278,height:30)}
        paymentPicker.frame=NSRect(x:16,y:height-164,width:278,height:30)
        qrView.frame=NSRect(x:35,y:height-410,width:240,height:240)
        paymentNote.frame=NSRect(x:16,y:32,width:278,height:62)
        errorLabel.frame=NSRect(x:16,y:6,width:278,height:24)
        popover.contentSize=NSSize(width:310,height:height)
    }
    @objc func selectPayment(){
        let names=["SupportWeChatPay","SupportAlipay","SupportOKXPay"]
        let index=paymentPicker.indexOfSelectedItem-1
        guard names.indices.contains(index) else{selectedPaymentResource=nil;qrView.image=nil;qrView.isHidden=true;paymentNote.isHidden=true;errorLabel.stringValue="";layout(expanded:false);return}
        selectedPaymentResource=names[index]
        guard let url=resourceRoot?.appendingPathComponent("SupportQR/"+names[index]+".png"),let image=NSImage(contentsOf:url) else{
            selectedPaymentResource=nil;qrView.image=nil;qrView.isHidden=true;paymentNote.isHidden=true;errorLabel.stringValue=L("收款码暂不可用，请稍后重试。");layout(expanded:false);return
        }
        qrView.image=image;qrView.isHidden=false;paymentNote.isHidden=false;errorLabel.stringValue=""
        qrView.setAccessibilityLabel((paymentPicker.titleOfSelectedItem ?? "")+" "+L("收款二维码；请在支付应用核对收款人"));layout(expanded:true)
    }
    static func platformImage(_ destination:Destination,resourceRoot:URL? = Bundle.main.resourceURL)->NSImage? {
        let name=destination == .x ? "X" : "GitHub"
        if let url=resourceRoot?.appendingPathComponent("AuthorLinks/"+name+".png"),let image=NSImage(contentsOf:url){
            let scale=18/max(image.size.width,image.size.height);image.size=NSSize(width:image.size.width*scale,height:image.size.height*scale);image.isTemplate=true;return image
        }
        return NSImage(systemSymbolName:destination.symbol,accessibilityDescription:nil)
    }
    @objc func show(){
        if popover.isShown{popover.performClose(nil);return}
        paymentPicker.selectItem(at:0);selectPayment()
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.maxY)
    }
    @objc func openLink(_ sender:NSButton){
        guard let destination=Destination(rawValue:sender.tag) else{return}
        if openURL(destination.url){popover.performClose(nil)}else{errorLabel.stringValue=L("未能打开浏览器，请稍后重试。")}
    }
}
