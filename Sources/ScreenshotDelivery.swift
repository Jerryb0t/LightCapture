import CoreGraphics
import Foundation
/// Effects injected so routing can be tested without touching a real pasteboard or disk.
enum ScreenshotDelivery {
    enum Failure:LocalizedError {
        case clipboard
        var errorDescription:String? {"截图未能复制到剪贴板，未自动保存。请重新截图或进入「标注」后重试。"}
    }
    static func finalize(_ image:CGImage,copyOnly:Bool,copy:(CGImage)->Bool,save:(CGImage)->Void) throws {
        guard copy(image) else {throw Failure.clipboard}
        if !copyOnly {save(image)}
    }
}
