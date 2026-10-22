import AppKit
import MochiCore
import UniformTypeIdentifiers

extension Clip {
    /// 列表里显示的一行：起了名字就是名字；文本取第一个不是空白的行。
    var displayTitle: String {
        if let customTitle { return customTitle }
        guard kind == .text else { return title }
        let line = title.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
        guard let line else { return "（空白）" }
        return line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\t", with: " ")
    }

    var typeLabel: String {
        switch kind {
        case .text: isLink ? "链接" : "文本"
        case .image: "图片"
        case .file: "文件"
        }
    }
}

/// 终端、编辑器里复制的文本，预览用等宽字体。
enum CodeApps {
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
        "com.panic.Nova", "com.barebones.bbedit",
    ]

    static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }
}

enum Formatting {
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 「今天 21:49」「昨天 09:10」「10月16日 21:52」「2025年3月2日 08:00」。
    static func copiedAt(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let hm = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(hm)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(hm)"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = "\(parts.month ?? 0)月\(parts.day ?? 0)日 \(hm)"
        return calendar.isDate(date, equalTo: now, toGranularity: .year) ? day : "\(parts.year ?? 0)年\(day)"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// 家目录换成 `~`。
    static func path(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// 一次只解一张图。预览、列表缩略图各排一队：按住方向键翻图、滚动列表时不会同时解好几张原图，
/// 一张 4032×3024 的照片解码时要几十 MB，几张一起解内存会一下冲上去。
/// 排到时调用方已经取消（选中的换了、行滚出去了）就不解。
actor ImageQueue {
    static let previews = ImageQueue()
    static let thumbnails = ImageQueue()

    func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return Images.downsample(url, maxPixel: maxPixel)
    }

    /// 列表行的小图：读记录时存下的那张；没有（以前记的）就从原图生成一张存下。
    func thumbnail(of imageURL: URL, at thumbnailURL: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return Images.downsample(thumbnailURL, maxPixel: ClipStore.thumbnailPixels)
            ?? ClipStore.makeThumbnail(of: imageURL, at: thumbnailURL)
    }
}

/// 列表行的小图，最多留 300 张（一张不到 40 KB）。
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 300
        return cache
    }()

    static func cached(_ thumbnailURL: URL) -> CGImage? {
        cache.object(forKey: thumbnailURL as NSURL)
    }

    static func load(_ imageURL: URL, thumbnailURL: URL) async -> CGImage? {
        if let image = cached(thumbnailURL) { return image }
        guard let image = await ImageQueue.thumbnails.thumbnail(of: imageURL, at: thumbnailURL) else { return nil }
        cache.setObject(image, forKey: thumbnailURL as NSURL)
        return image
    }
}

/// 应用图标、文件图标。系统给的图标本身有缓存，这里再按 bundle id、路径记一下，省掉每次查 LaunchServices。
@MainActor
enum Icons {
    private static let apps = limitedCache()
    private static let files = limitedCache()

    private static func limitedCache() -> NSCache<NSString, NSImage> {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }

    static func app(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = apps.object(forKey: bundleID as NSString) { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        apps.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    /// 文件不在了就按扩展名给一个通用图标。
    static func file(_ url: URL) -> NSImage {
        if let icon = files.object(forKey: url.path as NSString) { return icon }
        let icon = FileManager.default.fileExists(atPath: url.path)
            ? NSWorkspace.shared.icon(forFile: url.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
        files.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}
