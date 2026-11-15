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
@MainActor final class AuthorLinks:NSObject,NSPopoverDelegate {
    enum Destination:Int,CaseIterable {
        case x,github
        var url:URL{URL(string:self == .x ? "https://x.com/Jerryb0t" : "https://github.com/Jerryb0t")!}
        var title:String{self == .x ? "X · Jerryb0t" : "GitHub · Jerryb0t"}
        var symbol:String{self == .x ? "xmark" : "chevron.left.forwardslash.chevron.right"}
    }
    enum PanelKind {case follow,support}
    let followButton=NSButton(title:"👋 "+L("关注作者"),target:nil,action:nil)
    let button=NSButton(title:"☕ "+L("打赏作者"),target:nil,action:nil)
    private(set) var popover:NSPopover?
    private(set) var kind:PanelKind?
    private(set) var linkButtons:[NSButton]=[]
    private(set) var paymentPicker:NSPopUpButton?
    private(set) var qrView:SupportQRView?
    private var note:NSTextField?
    private var errorLabel:NSTextField?
    private(set) var selectedPaymentResource:String?
    var resourceRoot:URL? = Bundle.main.resourceURL
    var openURL:(URL)->Bool = {NSWorkspace.shared.open($0)}
    override init(){
        super.init()
        for b in [followButton,button]{b.target=self;b.bezelStyle = .inline;b.font = .systemFont(ofSize:12);b.contentTintColor = .secondaryLabelColor}
        followButton.action=#selector(showFollow);button.action=#selector(showSupport)
        followButton.setAccessibilityLabel(L("关注作者"));button.setAccessibilityLabel(L("打赏作者"))
    }
    /// No view, brand bitmap or QR exists until an entry is explicitly chosen.
    func prepare(_ requested:PanelKind){
        dismiss()
        kind=requested
        let pop=NSPopover();let controller=NSViewController();controller.view=NSView(frame:NSRect(x:0,y:0,width:310,height:requested == .follow ? 166 : 138))
        pop.contentViewController=controller;pop.behavior = .transient;pop.delegate=self;popover=pop
        let intro=NSTextField(wrappingLabelWithString:requested == .follow ? L("喜欢轻截？可以关注作者，或在项目页点个 Star。") : L("谢谢你的支持。选择一种方式查看收款码。"))
        intro.font = .systemFont(ofSize:12);intro.frame=NSRect(x:16,y:controller.view.bounds.height-56,width:278,height:44);controller.view.addSubview(intro)
        let error=NSTextField(wrappingLabelWithString:"");error.font = .systemFont(ofSize:10);error.textColor = .secondaryLabelColor;error.frame=NSRect(x:16,y:6,width:278,height:24);controller.view.addSubview(error);errorLabel=error
        if requested == .follow {
            for destination in Destination.allCases {
                let link=NSButton(title:destination.title,target:self,action:#selector(openLink(_:)));link.tag=destination.rawValue;link.bezelStyle = .rounded;link.alignment = .left
                link.image=Self.platformImage(destination,resourceRoot:resourceRoot);link.imagePosition = .imageLeading
                link.setAccessibilityLabel(L("在浏览器打开作者的 %@ 主页",destination == .x ? "X" : "GitHub"))
                link.frame=NSRect(x:16,y:74-CGFloat(destination.rawValue)*36,width:278,height:30);controller.view.addSubview(link);linkButtons.append(link)
            }
        }else{
            let picker=NSPopUpButton();picker.addItems(withTitles:[L("自愿打赏：选择收款码…"),"微信支付 / WeChat Pay","支付宝 / Alipay","OKX Pay"])
            picker.target=self;picker.action=#selector(selectPayment);picker.frame=NSRect(x:16,y:38,width:278,height:30);picker.setAccessibilityLabel(L("选择自愿打赏收款码"));controller.view.addSubview(picker);paymentPicker=picker
            let qr=SupportQRView();qr.setAccessibilityElement(true);qr.setAccessibilityRole(.image);qr.isHidden=true;controller.view.addSubview(qr);qrView=qr
            let explanation=NSTextField(wrappingLabelWithString:L("打赏完全自愿。请用对应支付应用扫码，并在付款前核对收款人。轻截不会发起付款或确认到账。"));explanation.font = .systemFont(ofSize:11);explanation.isHidden=true;controller.view.addSubview(explanation);note=explanation
        }
        pop.contentSize=controller.view.bounds.size
    }
    @objc func showFollow(){show(.follow,anchor:followButton)}
    @objc func showSupport(){show(.support,anchor:button)}
    private func show(_ requested:PanelKind,anchor:NSView){
        if kind == requested,popover?.isShown == true{dismiss();return}
        prepare(requested);popover?.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxY)
    }
    func dismiss(){
        let old=popover;popover=nil;old?.delegate=nil;old?.performClose(nil);old?.contentViewController=nil
        kind=nil;linkButtons=[];paymentPicker=nil;qrView?.image=nil;qrView=nil;note=nil;errorLabel=nil;selectedPaymentResource=nil
    }
    func popoverDidClose(_ notification:Notification){dismiss()}
    @objc func selectPayment(){
        guard kind == .support,let picker=paymentPicker,let qr=qrView,let panel=popover?.contentViewController?.view else{return}
        let names=["SupportWeChatPay","SupportAlipay","SupportOKXPay"],index=picker.indexOfSelectedItem-1
        let name=names.indices.contains(index) ? names[index] : nil
        let image=name.flatMap{resourceRoot?.appendingPathComponent("SupportQR/"+$0+".png")}.flatMap{NSImage(contentsOf:$0)}
        selectedPaymentResource=image == nil ? nil : name;qr.image=image;qr.isHidden=image == nil;note?.isHidden=image == nil
        errorLabel?.stringValue=name != nil && image == nil ? L("收款码暂不可用，请稍后重试。") : ""
        let height:CGFloat=image == nil ? 138 : 448
        panel.setFrameSize(NSSize(width:310,height:height));popover?.contentSize=panel.bounds.size
        panel.subviews.first?.frame=NSRect(x:16,y:height-56,width:278,height:44)
        picker.frame=NSRect(x:16,y:height-100,width:278,height:30)
        qr.frame=NSRect(x:35,y:height-346,width:240,height:240)
        note?.frame=NSRect(x:16,y:32,width:278,height:62)
        qr.setAccessibilityLabel((picker.titleOfSelectedItem ?? "")+" "+L("收款二维码；请在支付应用核对收款人"))
    }
    static func platformImage(_ destination:Destination,resourceRoot:URL? = Bundle.main.resourceURL)->NSImage? {
        let name=destination == .x ? "X" : "GitHub"
        if let url=resourceRoot?.appendingPathComponent("AuthorLinks/"+name+".png"),let image=NSImage(contentsOf:url){let scale=18/max(image.size.width,image.size.height);image.size=NSSize(width:image.size.width*scale,height:image.size.height*scale);image.isTemplate=true;return image}
        return NSImage(systemSymbolName:destination.symbol,accessibilityDescription:nil)
    }
    @objc func openLink(_ sender:NSButton){
        guard kind == .follow,let destination=Destination(rawValue:sender.tag) else{return}
        if openURL(destination.url){dismiss()}else{errorLabel?.stringValue=L("未能打开浏览器，请稍后重试。")}
    }
}
