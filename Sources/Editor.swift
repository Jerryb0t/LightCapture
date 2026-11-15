import AppKit
import CoreGraphics
import CoreText

struct CaptureAnnotation {
    enum Kind { case pen, arrow, rectangle, text }
    var kind: Kind
    var points: [CGPoint]
    var text: String = ""
    var color: CGColor = CGColor(red: 0.96, green: 0.22, blue: 0.19, alpha: 1)
    var width: CGFloat = 4
    var fontSize: CGFloat = 30
}

/// Annotation coordinates are original-image pixels with a top-left origin.
enum CaptureEditorRenderer {
    static func draw(_ mark: CaptureAnnotation, in context: CGContext) {
        guard let first = mark.points.first else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(mark.color)
        context.setFillColor(mark.color)
        context.setLineWidth(mark.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch mark.kind {
        case .pen:
            if mark.points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x-mark.width/2, y: first.y-mark.width/2, width: mark.width, height: mark.width))
            } else {
                context.beginPath(); context.move(to: first)
                for point in mark.points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
        case .rectangle:
            guard let last = mark.points.last else { return }
            context.stroke(CGRect(x: min(first.x,last.x), y: min(first.y,last.y), width: abs(last.x-first.x), height: abs(last.y-first.y)))
        case .arrow:
            guard let last = mark.points.last else { return }
            let dx = last.x-first.x, dy = last.y-first.y, length = hypot(dx,dy)
            guard length > 1 else { return }
            let head = min(max(14, mark.width*4), length * 0.45), angle = atan2(dy,dx)
            context.beginPath(); context.move(to: first); context.addLine(to: last)
            context.move(to: CGPoint(x: last.x-head*cos(angle-0.5), y: last.y-head*sin(angle-0.5)))
            context.addLine(to: last)
            context.addLine(to: CGPoint(x: last.x-head*cos(angle+0.5), y: last.y-head*sin(angle+0.5)))
            context.strokePath()
        case .text:
            guard !mark.text.isEmpty else { return }
            let font = CTFontCreateWithName("Helvetica" as CFString, mark.fontSize, nil)
            let string = NSAttributedString(string: mark.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): mark.color
            ])
            let line = CTLineCreateWithAttributedString(string)
            context.translateBy(x: first.x, y: first.y + mark.fontSize)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
        }
    }

    static func render(image: CGImage, annotations: [CaptureAnnotation]) -> CGImage? {
        // CGImage is immutable: an unannotated capture can reuse its pixels.
        guard !annotations.isEmpty else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        for annotation in annotations { draw(annotation, in: context) }
        return context.makeImage()
    }
}

@MainActor private final class CaptureEditorCanvas: NSView {
    let image: CGImage
    var annotations: [CaptureAnnotation] = []
    var draft: CaptureAnnotation?
    var kind: CaptureAnnotation.Kind = .pen
    var ink = CGColor(red: 0.96, green: 0.22, blue: 0.19, alpha: 1)
    var onChange: (() -> Void)?
    var onText: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var imageRect: CGRect {
        let available = bounds.insetBy(dx: 16, dy: 16)
        let ratio = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width)*ratio, height: CGFloat(image.height)*ratio)
        return CGRect(x: bounds.midX-size.width/2, y: bounds.midY-size.height/2, width: size.width, height: size.height)
    }
    func imagePoint(_ event: NSEvent, mustBeInside: Bool) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard rect.width > 0, !mustBeInside || rect.contains(point) else { return nil }
        return CGPoint(x: min(CGFloat(image.width-1), max(0, (point.x-rect.minX)*CGFloat(image.width)/rect.width)),
                       y: min(CGFloat(image.height-1), max(0, (point.y-rect.minY)*CGFloat(image.height)/rect.height)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let rect = imageRect
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width/CGFloat(image.width), y: rect.height/CGFloat(image.height))
        for annotation in annotations { CaptureEditorRenderer.draw(annotation, in: context) }
        if let draft { CaptureEditorRenderer.draw(draft, in: context) }
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        guard let point = imagePoint(event, mustBeInside: true) else { return }
        window?.makeFirstResponder(self)
        if kind == .text { onText?(point); return }
        let ratio = CGFloat(image.width)/max(1,imageRect.width)
        draft = CaptureAnnotation(kind: kind, points: [point], color: ink, width: 2.5*ratio, fontSize: 22*ratio)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(event, mustBeInside: false), draft != nil else { return }
        if kind == .pen { draft?.points.append(point) }
        else if let first = draft?.points.first { draft?.points = [first,point] }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let draft else { return }
        annotations.append(draft); self.draft = nil; needsDisplay = true; onChange?()
    }
    func undoLast() { draft = nil; if !annotations.isEmpty { annotations.removeLast() }; needsDisplay = true; onChange?() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { undoLast() }
        else { super.keyDown(with: event) }
    }
}

@MainActor final class CaptureEditor: NSObject, NSWindowDelegate {
    private let image: CGImage
    private let onSave: (CGImage) -> Void
    private let onCancel: () -> Void
    private let onRecord: (() -> Void)?
    private let onLong: (() -> Void)?
    private let copyOnly: Bool
    private let pasteboard: NSPasteboard
    private var modes: NSSegmentedControl!
    private let canvas: CaptureEditorCanvas
    private var window: NSWindow!
    private var finished = false
    private let message = NSTextField(labelWithString: L("原图保持不变 · 标注后保存或复制"))
    private var undoButton: NSButton!
    init(image: CGImage, onSave: @escaping(CGImage)->Void, onCancel: @escaping()->Void,
         onRecord: (() -> Void)? = nil, onLong: (() -> Void)? = nil, copyOnly: Bool = false,
         pasteboard: NSPasteboard = .general) {
        self.image = image; self.onSave = onSave; self.onCancel = onCancel
        self.onRecord = onRecord; self.onLong = onLong; self.copyOnly = copyOnly; self.pasteboard = pasteboard
        canvas = CaptureEditorCanvas(image: image)
        super.init()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = L("截图编辑"); window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false; window.delegate = self
        let root = NSView(); window.contentView = root
        modes = NSSegmentedControl(labels: [L("截图"), L("录屏"), L("长截图")], trackingMode: .selectOne, target: self, action: #selector(changeMode(_:)))
        modes.selectedSegment = 0; modes.segmentStyle = .rounded
        modes.setEnabled(onRecord != nil, forSegment: 1); modes.setEnabled(onLong != nil, forSegment: 2)
        modes.controlSize = .large; modes.font = .systemFont(ofSize: 14, weight: .semibold)
        modes.wantsLayer = true; modes.layer?.cornerRadius = 7
        let guide = NSTextField(labelWithString: copyOnly ? L("按 Enter 复制截图") : L("按 Enter 复制并保存截图"))
        guide.textColor = .secondaryLabelColor; guide.font = .systemFont(ofSize: 12)
        let modeBar = NSStackView(views: [modes, guide]); modeBar.spacing = 16
        let tools = NSSegmentedControl(labels: [L("画笔"), L("箭头"), L("矩形"), L("文字")], trackingMode: .selectOne, target: self, action: #selector(changeTool(_:)))
        tools.selectedSegment = 0
        let color = NSPopUpButton(); color.addItems(withTitles: [L("红色"),L("黄色"),L("蓝色"),L("黑色"),L("白色")])
        color.target = self; color.action = #selector(changeColor(_:))
        undoButton = button(L("撤销"), #selector(undo)); undoButton.isEnabled = false
        let copy = button(L("复制"), #selector(copyImage)); copy.keyEquivalent = "c"
        let save = button(copyOnly ? L("仅复制") : L("复制并保存"), #selector(saveImage))
        save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = []
        window.defaultButtonCell = save.cell as? NSButtonCell
        let cancel = button(L("取消"), #selector(cancelEditing)); cancel.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [tools,color,undoButton,copy,save,cancel]); bar.spacing = 10
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize: 12)
        message.stringValue = copyOnly ? L("按 Enter 完成 · 仅复制，不写入文件") : L("按 Enter 完成 · 原图不变，复制并保存标注后的截图")
        for view in [modeBar,bar,canvas,message] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            modeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 16),
            modeBar.topAnchor.constraint(equalTo: root.topAnchor,constant: 14),
            modeBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,constant: -16),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 16), bar.topAnchor.constraint(equalTo: modeBar.bottomAnchor,constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,constant: -16),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor,constant: 10), canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor), canvas.bottomAnchor.constraint(equalTo: message.topAnchor,constant: -4),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 16), message.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -12),
            message.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,constant: -16)
        ])
        canvas.onChange = { [weak self] in self?.undoButton.isEnabled = !(self?.canvas.annotations.isEmpty ?? true) }
        canvas.onText = { [weak self] point in self?.insertText(at: point) }
    }
    func show() {
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (step, alpha) in [0.40, 0.0, 0.40, 0.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.35) { [weak self] in
                guard let self, !self.finished, self.window.isVisible else { return }
                self.modes.layer?.borderWidth = alpha > 0 ? 2 : 0
                self.modes.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
            }
        }
    }
    @objc private func changeMode(_ sender: NSSegmentedControl) {
        guard !finished, window.attachedSheet == nil else { return }
        let action: (() -> Void)?
        switch sender.selectedSegment {
        case 1: action = onRecord
        case 2: action = onLong
        default: return
        }
        guard let action else { sender.selectedSegment = 0; return }
        finished = true; window.close(); action()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func changeTool(_ sender: NSSegmentedControl) {
        canvas.kind = [.pen,.arrow,.rectangle,.text][max(0,min(3,sender.selectedSegment))]
    }
    @objc private func changeColor(_ sender: NSPopUpButton) {
        let colors: [NSColor] = [.systemRed,.systemYellow,.systemBlue,.black,.white]
        canvas.ink = colors[max(0,min(4,sender.indexOfSelectedItem))].cgColor
    }
    @objc private func undo() { canvas.undoLast() }
    private func insertText(at point: CGPoint) {
        let alert = NSAlert(); alert.messageText = L("添加文字"); alert.informativeText = L("输入要放在截图上的文字。")
        alert.addButton(withTitle: L("添加")); alert.addButton(withTitle: L("取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26)); alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            guard !text.isEmpty else { return }
            let ratio = CGFloat(self.image.width)/max(1,self.canvas.imageRect.width)
            self.canvas.annotations.append(CaptureAnnotation(kind: .text, points: [point], text: text, color: self.canvas.ink, fontSize: 22*ratio))
            self.canvas.needsDisplay = true; self.canvas.onChange?()
        }
    }
    private func output() -> CGImage? {
        let result = CaptureEditorRenderer.render(image: image, annotations: canvas.annotations)
        if result == nil { message.stringValue = L("图片渲染失败，请尝试撤销或取消。") }
        return result
    }
    private func copyToPasteboard(_ image: CGImage) -> Bool {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            message.stringValue = L("无法生成 PNG，请重试"); return false
        }
        pasteboard.clearContents()
        let copied = pasteboard.setData(data, forType: .png)
        message.stringValue = copied ? L("已复制 PNG，可粘贴到聊天或文档中") : L("复制失败，请重试")
        return copied
    }
    @objc private func copyImage() {
        guard !finished, window.attachedSheet == nil, let output = output() else { return }
        _ = copyToPasteboard(output)
    }
    @objc private func saveImage() {
        guard !finished, window.attachedSheet == nil, let output = output(), copyToPasteboard(output) else { return }
        finished = true; window.close()
        if copyOnly { onCancel() } else { onSave(output) }
    }
    @objc private func cancelEditing() {
        guard !finished else { return }
        finished = true; window.close(); onCancel()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !finished { finished = true; onCancel() }
        return true
    }
}
