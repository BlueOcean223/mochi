import CryptoKit
import Foundation

/// 一次复制时从剪切板读下来的东西，还没认类型。和 NSPasteboard 分开，测试里可以直接造。
public struct PasteboardSnapshot: Sendable {
    public struct Item: Sendable {
        /// 这一项带的全部类型，不管读没读数据。
        public var types: [String]
        /// 只有 `PasteboardTypes.captured` 里的类型读了数据。
        public var data: [String: Data]

        public init(types: [String], data: [String: Data] = [:]) {
            self.types = types
            self.data = data
        }
    }

    public var items: [Item]
    /// 发现变化时在前台的应用。剪切板不记来源，这是最接近的：轮询间隔是 0.5 秒，复制完马上切走的话会记成切过去的那个应用。
    public var sourceBundleID: String?
    public var sourceName: String?
    public var date: Date

    public init(items: [Item], sourceBundleID: String? = nil, sourceName: String? = nil, date: Date = .now) {
        self.items = items
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.date = date
    }
}

public enum ClipKind: Int, Sendable, CaseIterable {
    case text = 0
    case image = 1
    case file = 2
}

/// 认好类型、准备入库的一条。
public struct Capture: Sendable {
    public var kind: ClipKind
    /// 文本条目的纯文本。
    public var text: String?
    /// 文件条目的文件，按剪切板上的顺序。
    public var fileURLs: [URL] = []
    /// 图片条目的原始数据和它的类型。
    public var imageData: Data?
    public var imageType: String?
    /// 文本条目的格式（`PasteboardTypes.textFormats`），粘贴时原样写回。
    public var formats: [String: Data] = [:]
    public var sourceBundleID: String?
    public var sourceName: String?
    public var date: Date

    /// 去重用：同样的内容再复制一遍，算出来一样。文本只看纯文本，格式不同也算同一条。
    public var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data([UInt8(kind.rawValue)]))
        switch kind {
        case .text: hasher.update(data: Data((text ?? "").utf8))
        case .image: hasher.update(data: imageData ?? Data())
        case .file: hasher.update(data: Data(fileURLs.map(\.path).joined(separator: "\n").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum SkipReason: Sendable, Equatable {
    /// 带了 `PasteboardTypes.skipMarkers` 里的类型，比如密码。
    case marked(String)
    /// 没有认得的内容，或者文本全是空白。
    case empty
    /// 太大，不记。
    case tooLarge
}

public enum Classification: Sendable {
    case capture(Capture)
    case skip(SkipReason)
}

public enum Classifier {
    public static let maxTextBytes = 5 << 20
    public static let maxImageBytes = 50 << 20

    /// 认类型：文件 > 图片 > 文本。
    ///
    /// 文本和图片都有时按文本算，除非文本只是一个网址：Word、Excel、Keynote 复制文字时会顺带一张选区的图，
    /// 要的是文字；Safari 拷贝图片时带的文本是图片的网址，要的是图片。
    /// 只有 RTF、HTML 没有纯文本的不记：会写 RTF 的应用都会同时写纯文本，没必要为它去解析 RTF。
    public static func classify(_ snapshot: PasteboardSnapshot) -> Classification {
        let types = Set(snapshot.items.flatMap(\.types))
        if let marker = types.intersection(PasteboardTypes.skipMarkers).sorted().first {
            return .skip(.marked(marker))
        }

        let files = snapshot.items.compactMap { $0.data[PasteboardTypes.fileURL].flatMap(fileURL) }
        if !files.isEmpty {
            return .capture(Capture(kind: .file, fileURLs: files, sourceBundleID: snapshot.sourceBundleID,
                                    sourceName: snapshot.sourceName, date: snapshot.date))
        }

        guard let item = snapshot.items.first else { return .skip(.empty) }
        let text = item.data[PasteboardTypes.plainText].flatMap { String(data: $0, encoding: .utf8) }
        let image = PasteboardTypes.images.lazy
            .compactMap { type in item.data[type].map { (type, $0) } }
            .first { !$0.1.isEmpty }

        if let (type, data) = image, text.map(isLink) ?? true {
            guard data.count <= maxImageBytes else { return .skip(.tooLarge) }
            return .capture(Capture(kind: .image, imageData: data, imageType: type, sourceBundleID: snapshot.sourceBundleID,
                                    sourceName: snapshot.sourceName, date: snapshot.date))
        }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skip(.empty) }
        guard text.utf8.count <= maxTextBytes else { return .skip(.tooLarge) }
        let formats = item.data.filter { PasteboardTypes.textFormats.contains($0.key) && $0.value.count <= maxTextBytes }
        return .capture(Capture(kind: .text, text: text, formats: formats, sourceBundleID: snapshot.sourceBundleID,
                                sourceName: snapshot.sourceName, date: snapshot.date))
    }

    private static func fileURL(_ data: Data) -> URL? {
        guard let string = String(data: data, encoding: .utf8), let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }

    /// 整段只是一个 http(s) 网址。
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
}
