import Foundation

/// 版本号，比如 0.2.0。比大小时按段比数字，段数不一样时缺的段当 0（0.2 和 0.2.0 一样）。
/// `-beta.1` 这类后缀不比：GitHub 的「最新版本」接口本来就不给预发布版。
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    /// 「v0.2.0」「0.2.0」「0.2.0-beta」都认；不是数字开头的返回 nil。
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        !(a < b) && !(b < a)
    }
}

/// GitHub 的一个 Release（`GET /repos/{owner}/{repo}/releases/latest` 的返回），只取用得到的字段。
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let downloadURL: URL
        public let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }
    }

    public let tag: String
    public let pageURL: URL
    public let notes: String?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case assets
        case tag = "tag_name"
        case pageURL = "html_url"
        case notes = "body"
    }

    public var version: AppVersion? { AppVersion(tag) }

    /// 打包好的应用：GitHub Actions 发布时传的 Mochi-<版本号>.zip。
    public var archive: Asset? {
        assets.first { $0.name.hasPrefix("Mochi-") && $0.name.hasSuffix(".zip") }
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }
}
