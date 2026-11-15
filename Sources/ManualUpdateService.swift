import Foundation

/// Metadata checking only. A GitHub digest is not publisher authentication.
/// No timers, automatic checks, archive extraction, installation or credential storage.
struct UpdateVersion: Comparable, Equatable {
    let components: [UInt32]
    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) && ($0.count == 1 || $0.first != "0") }),
              parts.allSatisfy({ UInt32($0) != nil }) else { throw ManualUpdateError.invalidVersion }
        components = parts.map { UInt32($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

enum ManualUpdateError: Error, Equatable {
    case invalidVersion, invalidMetadata, invalidAsset, responseTooLarge, invalidResponse
    case noPublishedRelease, publisherTrustNotConfigured
}

struct ManualUpdateCandidate: Equatable {
    let version: UpdateVersion
    let tag: String
    let releaseURL: URL
    let archiveURL: URL
    let archiveSize: Int
    let sha256: String
    /// Fail closed: same-origin digest and HTTPS do not establish independent publisher trust.
    func requireInstallTrust() throws { throw ManualUpdateError.publisherTrustNotConfigured }
}

enum ManualUpdateParser {
    static let endpoint = URL(string: "https://api.github.com/repos/Jerryb0t/LightCapture/releases/latest")!
    static let assetName = "LightCapture-macos-arm64.zip"
    static let maxMetadataBytes = 1_048_576
    static let maxArchiveBytes = 100 * 1024 * 1024
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let size: Int
        let content_type: String
        let state: String
        let browser_download_url: String
        let digest: String?
    }
    static func parse(_ data: Data, currentVersion: String) throws -> ManualUpdateCandidate? {
        guard data.count <= maxMetadataBytes else { throw ManualUpdateError.responseTooLarge }
        let current = try UpdateVersion(currentVersion)
        guard let release = try? JSONDecoder().decode(Release.self, from: data), !release.draft, !release.prerelease else { throw ManualUpdateError.invalidMetadata }
        let version = try UpdateVersion(release.tag_name)
        // Only ASCII numeric version tags are accepted; never use arbitrary tags as paths.
        let expectedPage = "https://github.com/Jerryb0t/LightCapture/releases/tag/" + release.tag_name
        guard release.html_url == expectedPage, let page = URL(string: expectedPage) else { throw ManualUpdateError.invalidMetadata }
        guard version > current else { return nil }
        let matches = release.assets.filter { $0.name == assetName }
        guard matches.count == 1, let asset = matches.first,
              asset.size > 0, asset.size <= maxArchiveBytes, asset.state == "uploaded",
              ["application/zip", "application/octet-stream", "application/x-zip-compressed"].contains(asset.content_type),
              let digest = asset.digest, digest.hasPrefix("sha256:") else { throw ManualUpdateError.invalidAsset }
        let hash = String(digest.dropFirst(7))
        guard hash.count == 64, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { throw ManualUpdateError.invalidAsset }
        let expectedArchive = "https://github.com/Jerryb0t/LightCapture/releases/download/" + release.tag_name + "/" + assetName
        guard asset.browser_download_url == expectedArchive, let archive = URL(string: expectedArchive) else { throw ManualUpdateError.invalidAsset }
        return ManualUpdateCandidate(version: version, tag: release.tag_name, releaseURL: page, archiveURL: archive, archiveSize: asset.size, sha256: hash)
    }
}

/// Reject redirects: this endpoint must not forward requests, credentials or checks to another origin.
private final class ManualUpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ManualUpdateService {
    /// Call only from an explicit user action. No network work occurs on construction.
    func check(currentVersion: String) async throws -> ManualUpdateCandidate? {
        _ = try UpdateVersion(currentVersion)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let policy = ManualUpdateRedirectPolicy()
        let session = URLSession(configuration: config, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: ManualUpdateParser.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LightCapture-ManualUpdate", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == ManualUpdateParser.endpoint else { throw ManualUpdateError.invalidResponse }
        if http.statusCode == 404 { throw ManualUpdateError.noPublishedRelease }
        guard http.statusCode == 200, http.mimeType == "application/json" else { throw ManualUpdateError.invalidResponse }
        guard http.expectedContentLength <= Int64(ManualUpdateParser.maxMetadataBytes) else { throw ManualUpdateError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ManualUpdateParser.maxMetadataBytes else { throw ManualUpdateError.responseTooLarge }
            data.append(byte)
        }
        return try ManualUpdateParser.parse(data, currentVersion: currentVersion)
    }
}
