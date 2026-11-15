import AppKit
import Foundation

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class CaptureStorage {
    static let shared = CaptureStorage()
    private(set) var root: URL
    private var accessed = false
    init() {
        let fallback = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("轻截")
        root = fallback
        if let data = UserDefaults.standard.data(forKey: "saveBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                root = url; accessed = url.startAccessingSecurityScopedResource()
            }
        } else {
            let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            if FileManager.default.fileExists(atPath: cloud.path) { root = cloud.appendingPathComponent("截图录屏") }
        }
    }
    func select(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if accessed { root.stopAccessingSecurityScopedResource() }
        root = url; accessed = url.startAccessingSecurityScopedResource()
        UserDefaults.standard.set(data, forKey: "saveBookmark")
    }
    static var recoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LightCapture/待保存")
    }
    static func temporaryURL(ext: String) throws -> URL {
        let folder = recoveryDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
    static func export(_ source: URL, root: URL, category: String) throws -> URL {
        let folder = root.appendingPathComponent(category)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { coordinated in
            result = Result {
                try FileManager.default.createDirectory(at: coordinated, withIntermediateDirectories: true)
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let name = category + "_" + formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(6)
                let dest = coordinated.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
                try FileManager.default.copyItem(at: source, to: dest)
                let a = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
                let b = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber
                guard a == b, (b?.int64Value ?? 0) > 0, FileManager.default.contentsEqual(atPath:source.path,andPath:dest.path) else { throw CaptureFailure.message(L("保存校验失败，原文件仍在待保存目录。")) }
                // Only the app-created, verified duplicate is removed. Never remove user originals.
                try? FileManager.default.removeItem(at: source)
                return dest
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CaptureFailure.message(L("无法访问保存文件夹。")) }
        return try result.get()
    }
    static func writePNG(_ image: CGImage) throws -> URL {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CaptureFailure.message(L("无法编码截图。")) }
        let url = try temporaryURL(ext: "png")
        try data.write(to: url, options: .atomic)
        return url
    }
}
