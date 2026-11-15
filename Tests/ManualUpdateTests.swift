import Foundation
@main struct ManualUpdateTests {
    private static func validate(_ condition:@autoclosure ()->Bool,_ message:String="assertion failed"){
        if !condition(){fputs("FAIL: "+message+"\n",stderr);exit(1)}
    }
    static func main() throws {
        let hash = String(repeating: "a", count: 64)
        func payload(tag: String = "v0.2.0", url: String? = nil, size: Int = 12345, digest: String? = nil, duplicate: Bool = false, draft: Bool = false) throws -> Data {
            let asset: [String: Any] = ["name": ManualUpdateParser.assetName, "size": size, "state": "uploaded", "content_type": "application/zip", "digest": digest ?? "sha256:" + hash, "browser_download_url": url ?? "https://github.com/Jerryb0t/LightCapture/releases/download/\(tag)/\(ManualUpdateParser.assetName)"]
            return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": false, "html_url": "https://github.com/Jerryb0t/LightCapture/releases/tag/\(tag)", "assets": duplicate ? [asset,asset] : [asset]])
        }
        func rejects(_ data: Data) { do { _ = try ManualUpdateParser.parse(data,currentVersion:"0.1.0"); validate(false,"accepted invalid metadata") } catch {} }
        let good = try payload()
        let candidate = try ManualUpdateParser.parse(good,currentVersion:"0.1.0")!
        validate(candidate.sha256 == hash && candidate.archiveSize == 12345)
        let same = try ManualUpdateParser.parse(good,currentVersion:"0.2.0")
        let older = try ManualUpdateParser.parse(good,currentVersion:"1.0.0")
        validate(same == nil && older == nil)
        for bad in ["1.2", "1.2.3-beta", "01.2.3", "1.2.3/evil", "1.2.-3", "1.2.３", "1.2.999999999999", "1.2.3+build"] { rejects(try payload(tag:bad)) }
        for bad in ["http://github.com/x", "https://github.com.evil.test/x", "https://github.com/Jerryb0t/Other/releases/download/v0.2.0/x.zip", "https://user@github.com/x", "https://github.com/x?secret=1"] { rejects(try payload(url:bad)) }
        rejects(try payload(size:0)); rejects(try payload(size:ManualUpdateParser.maxArchiveBytes+1))
        rejects(try payload(digest:"sha256:bad")); rejects(try payload(duplicate:true)); rejects(try payload(draft:true))
        rejects(Data(repeating:32,count:ManualUpdateParser.maxMetadataBytes+1)); rejects(Data("{}".utf8))
        do { try candidate.requireInstallTrust(); validate(false,"install authorized without trust") }
        catch { validate(error as? ManualUpdateError == .publisherTrustNotConfigured) }
        print("PASS strict versions, downgrade rejection, fixed repo/host/path, size/digest/schema validation and fail-closed install trust; no network, GUI, extraction, installation or keys")
    }
}
