import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 列表里的一条。不带全文和格式，那些点开预览、粘贴时再按 id 去取，免得列表把整个历史读进内存。
public struct Clip: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let kind: ClipKind
    /// 列表里显示的一行：文本的开头、文件名、图片尺寸。
    public let title: String
    public let fileURLs: [URL]
    public let imageURL: URL?
    /// 图片条目在列表行里用的小图，记录时和原图一起存下（`ClipStore.thumbnailPixels`）。以前记的可能没有，用时补。
    public let thumbnailURL: URL?
    public let imageWidth: Int?
    public let imageHeight: Int?
    /// 文本的 UTF-8 字节数、图片文件的大小；文件条目是 0。
    public let byteSize: Int
    /// 文本的字符数。
    public let characterCount: Int?
    public let sourceBundleID: String?
    public let sourceName: String?
    public let isPinned: Bool
    public let firstCopiedAt: Date
    public let lastCopiedAt: Date
    /// 用户起的名字（改名），没起是 nil。
    public let customTitle: String?
    /// 文本条目是不是一个网址、邮箱、颜色；别的条目是 .plain。
    public let category: TextCategory
}

extension Clip {
    /// 整段只是一个网址的文本条目。
    public var isLink: Bool {
        kind == .text && category == .link
    }
}

public enum RecordResult: Sendable, Equatable {
    case inserted(Int64)
    /// 同样的内容已经有了，挪到最前。
    case bumped(Int64)
    case skipped(SkipReason)
}

/// 剪切板历史：一个 SQLite 文件加一个图片目录。
public actor ClipStore {
    private let db: Database
    private let imagesDirectory: URL

    /// 列表行里文本最多存多少个字符；全文另存。
    static let titleLength = 300
    /// 搜索只搜文本的前这么多个字符，太长的文本用 LIKE 扫起来慢。
    static let searchLength = 20_000
    /// 列表行的小图长边多少像素。行里画 22 点见方、按短边裁，二倍屏要短边 44 像素；长边留到 96，16:9 的图也够。
    /// 记录时就存一张，列表滚动时只解这张小图，不用每次把原图（截图几 MB、照片十几 MB）整张解一遍。
    public static let thumbnailPixels = 96

    public init(directory: URL) throws {
        imagesDirectory = directory.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        db = try Database(path: directory.appending(path: "mochi.sqlite").path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try Self.migrate(db)
    }

    private static func migrate(_ db: Database) throws {
        let version = try db.prepare("PRAGMA user_version")
        let current = try version.step() ? version.int(0) : 0
        if current < 1 {
            try createTables(db)
        }
        if current < 2 {
            // 改名：用户起的名字，列表里代替标题显示，搜索也搜它。
            try db.execute("ALTER TABLE clips ADD COLUMN custom_title TEXT; PRAGMA user_version = 2;")
        }
        if current < 3 {
            // 链接、邮箱、颜色单独分类：已有的文本条目按全文补上。
            try db.transaction {
                try db.execute("ALTER TABLE clips ADD COLUMN category INTEGER NOT NULL DEFAULT 0")
                let select = try db.prepare("SELECT id, text FROM clips WHERE kind = ?1 AND length(text) <= 2048")
                    .bind(.int(Int64(ClipKind.text.rawValue)))
                var categories: [(Int64, TextCategory)] = []
                while try select.step() {
                    let category = TextCategory(text: select.text(1) ?? "")
                    if category != .plain { categories.append((select.int(0), category)) }
                }
                let update = try db.prepare("UPDATE clips SET category = ?1 WHERE id = ?2")
                for (id, category) in categories {
                    try update.bind(.int(Int64(category.rawValue)), .int(id)).run()
                }
                try db.execute("PRAGMA user_version = 3")
            }
        }
    }

    private static func createTables(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE clips (
              id INTEGER PRIMARY KEY,
              kind INTEGER NOT NULL,
              hash TEXT NOT NULL UNIQUE,
              title TEXT NOT NULL,
              search_text TEXT NOT NULL,
              text TEXT,
              file_paths TEXT,
              image_file TEXT,
              image_width INTEGER,
              image_height INTEGER,
              byte_size INTEGER NOT NULL,
              char_count INTEGER,
              source_bundle_id TEXT,
              source_name TEXT,
              pinned_at REAL,
              first_copied_at REAL NOT NULL,
              last_copied_at REAL NOT NULL
            );
            CREATE INDEX clips_last_copied ON clips(last_copied_at DESC);
            CREATE TABLE formats (
              clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
              type TEXT NOT NULL,
              data BLOB NOT NULL,
              PRIMARY KEY (clip_id, type)
            ) WITHOUT ROWID;
            PRAGMA user_version = 1;
            """)
    }

    // MARK: - 记录

    /// 认类型并入库。同样的内容已经有了就挪到最前，更新时间、来源和格式。
    @discardableResult
    public func record(_ snapshot: PasteboardSnapshot) throws -> RecordResult {
        switch Classifier.classify(snapshot) {
        case .skip(let reason): .skipped(reason)
        case .capture(let capture): try add(capture)
        }
    }

    @discardableResult
    public func add(_ capture: Capture) throws -> RecordResult {
        let hash = capture.contentHash
        if let id = try existingID(hash: hash) {
            try db.transaction {
                try db.prepare("UPDATE clips SET last_copied_at = ?1, source_bundle_id = ?2, source_name = ?3 WHERE id = ?4")
                    .bind(.double(capture.date.timeIntervalSince1970), optional(capture.sourceBundleID),
                          optional(capture.sourceName), .int(id))
                    .run()
                try replaceFormats(of: id, with: capture.formats)
            }
            return .bumped(id)
        }

        var image: SavedImage?
        if capture.kind == .image, let data = capture.imageData {
            image = try saveImage(data, type: capture.imageType, name: hash)
        }
        do {
            let id = try db.transaction {
                try insert(capture, hash: hash, image: image)
                let id = db.lastInsertRowID
                try replaceFormats(of: id, with: capture.formats)
                return id
            }
            return .inserted(id)
        } catch {
            if let image {
                try? FileManager.default.removeItem(at: imagesDirectory.appending(path: image.file))
                try? FileManager.default.removeItem(at: imagesDirectory.appending(path: Self.thumbnailFile(for: image.file)))
            }
            throw error
        }
    }

    private func existingID(hash: String) throws -> Int64? {
        let statement = try db.prepare("SELECT id FROM clips WHERE hash = ?1").bind(.text(hash))
        return try statement.step() ? statement.int(0) : nil
    }

    private func insert(_ capture: Capture, hash: String, image: SavedImage?) throws {
        let title: String
        let search: String
        var filePaths: SQLValue = .null
        var byteSize = 0
        var characterCount: SQLValue = .null
        var category = TextCategory.plain
        switch capture.kind {
        case .text:
            let text = capture.text ?? ""
            category = TextCategory(text: text)
            title = String(text.prefix(Self.titleLength))
            search = String(text.prefix(Self.searchLength)).lowercased()
            byteSize = text.utf8.count
            characterCount = .int(Int64(text.count))
        case .image:
            title = image.map { "图片 \($0.width)×\($0.height)" } ?? "图片"
            search = ""
            byteSize = image?.byteSize ?? capture.imageData?.count ?? 0
        case .file:
            let names = capture.fileURLs.map(\.lastPathComponent)
            title = names.joined(separator: "、")
            search = (names + capture.fileURLs.map(\.path)).joined(separator: "\n").lowercased()
            let data = try JSONEncoder().encode(capture.fileURLs.map(\.path))
            filePaths = .text(String(decoding: data, as: UTF8.self))
        }
        let date = capture.date.timeIntervalSince1970
        try db.prepare("""
            INSERT INTO clips (kind, hash, title, search_text, text, file_paths, image_file, image_width, image_height,
                               byte_size, char_count, source_bundle_id, source_name, first_copied_at, last_copied_at, category)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14, ?15)
            """)
            .bind(.int(Int64(capture.kind.rawValue)), .text(hash), .text(title), .text(search),
                  capture.kind == .text ? optional(capture.text) : .null, filePaths,
                  optional(image?.file), image.map { .int(Int64($0.width)) } ?? .null,
                  image.map { .int(Int64($0.height)) } ?? .null, .int(Int64(byteSize)), characterCount,
                  optional(capture.sourceBundleID), optional(capture.sourceName), .double(date), .int(Int64(category.rawValue)))
            .run()
    }

    private func replaceFormats(of id: Int64, with formats: [String: Data]) throws {
        try db.prepare("DELETE FROM formats WHERE clip_id = ?1").bind(.int(id)).run()
        let insert = try db.prepare("INSERT INTO formats (clip_id, type, data) VALUES (?1, ?2, ?3)")
        for (type, data) in formats.sorted(by: { $0.key < $1.key }) {
            try insert.bind(.int(id), .text(type), .blob(data)).run()
        }
    }

    private struct SavedImage {
        let file: String
        let width: Int
        let height: Int
        let byteSize: Int
    }

    /// 图片存成 PNG 文件（截图常见的 TIFF 能小好几倍），数据库里只记文件名。转不了的原样存。
    private func saveImage(_ data: Data, type: String?, name: String) throws -> SavedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DatabaseError(message: "图片数据读不出来")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        var output = data
        var ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "img"
        if type != PasteboardTypes.png {
            let png = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImageFromSource(destination, source, 0, nil)
                if CGImageDestinationFinalize(destination) {
                    output = png as Data
                    ext = "png"
                }
            }
        }
        let file = "\(name.prefix(32)).\(ext)"
        try output.write(to: imagesDirectory.appending(path: file), options: .atomic)
        // 小图存不下来不要紧，列表显示时会再生成。
        if let thumbnail = Images.downsample(data, maxPixel: Self.thumbnailPixels) {
            Images.writePNG(thumbnail, to: imagesDirectory.appending(path: Self.thumbnailFile(for: file)))
        }
        return SavedImage(file: file, width: width, height: height, byteSize: output.count)
    }

    static func thumbnailFile(for imageFile: String) -> String {
        (imageFile as NSString).deletingPathExtension + ".thumb.png"
    }

    /// 从原图生成列表行的小图并存下，给记录时还没存小图的老条目用。条目在生成期间被删了就不留。
    public static func makeThumbnail(of imageURL: URL, at thumbnailURL: URL) -> CGImage? {
        guard let thumbnail = Images.downsample(imageURL, maxPixel: thumbnailPixels) else { return nil }
        Images.writePNG(thumbnail, to: thumbnailURL)
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        return thumbnail
    }

    // MARK: - 读

    /// 一页列表：置顶的在前（后置顶的在上），其余按最近复制的时间。
    /// `query` 不区分大小写地匹配文本内容、文件名和起的名字；`filter` 为 nil 表示全部类型。
    public func list(matching query: String = "", filter: ClipFilter? = nil, limit: Int = 100, offset: Int = 0) throws -> [Clip] {
        let pattern = query.isEmpty ? "" : "%" + escapeLike(query.lowercased()) + "%"
        let statement = try db.prepare("""
            SELECT id, kind, title, file_paths, image_file, image_width, image_height, byte_size, char_count,
                   source_bundle_id, source_name, pinned_at, first_copied_at, last_copied_at, custom_title, category
            FROM clips
            WHERE (\(filter?.condition ?? "1"))
              AND (?1 = '' OR search_text LIKE ?1 ESCAPE '\\' OR lower(custom_title) LIKE ?1 ESCAPE '\\')
            ORDER BY pinned_at IS NULL, pinned_at DESC, last_copied_at DESC
            LIMIT ?2 OFFSET ?3
            """)
            .bind(.text(pattern), .int(Int64(limit)), .int(Int64(offset)))
        var clips: [Clip] = []
        while try statement.step() {
            let paths = statement.text(3).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            clips.append(Clip(
                id: statement.int(0),
                kind: ClipKind(rawValue: Int(statement.int(1))) ?? .text,
                title: statement.text(2) ?? "",
                fileURLs: paths.map { URL(filePath: $0) },
                imageURL: statement.text(4).map { imagesDirectory.appending(path: $0) },
                thumbnailURL: statement.text(4).map { imagesDirectory.appending(path: Self.thumbnailFile(for: $0)) },
                imageWidth: statement.isNull(5) ? nil : Int(statement.int(5)),
                imageHeight: statement.isNull(6) ? nil : Int(statement.int(6)),
                byteSize: Int(statement.int(7)),
                characterCount: statement.isNull(8) ? nil : Int(statement.int(8)),
                sourceBundleID: statement.text(9),
                sourceName: statement.text(10),
                isPinned: !statement.isNull(11),
                firstCopiedAt: Date(timeIntervalSince1970: statement.double(12)),
                lastCopiedAt: Date(timeIntervalSince1970: statement.double(13)),
                customTitle: statement.text(14),
                category: TextCategory(rawValue: Int(statement.int(15))) ?? .plain))
        }
        return clips
    }

    /// 文本条目的全文。
    public func text(of id: Int64) throws -> String? {
        let statement = try db.prepare("SELECT text FROM clips WHERE id = ?1").bind(.int(id))
        return try statement.step() ? statement.text(0) : nil
    }

    /// 文本条目存下的格式（RTF、HTML、URL）。
    public func formats(of id: Int64) throws -> [String: Data] {
        let statement = try db.prepare("SELECT type, data FROM formats WHERE clip_id = ?1").bind(.int(id))
        var formats: [String: Data] = [:]
        while try statement.step() {
            if let type = statement.text(0) { formats[type] = statement.blob(1) ?? Data() }
        }
        return formats
    }

    /// 文本条目除了纯文本还存了哪些格式（类型名），「选格式粘贴」列出来用，不读数据。
    public func formatTypes(of id: Int64) throws -> [String] {
        let statement = try db.prepare("SELECT type FROM formats WHERE clip_id = ?1 ORDER BY type").bind(.int(id))
        var types: [String] = []
        while try statement.step() {
            if let type = statement.text(0) { types.append(type) }
        }
        return types
    }

    public func count() throws -> Int {
        let statement = try db.prepare("SELECT count(*) FROM clips")
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    /// 清空会删掉的条数：不置顶的，`filter` 不为 nil 时只算这一类。
    public func unpinnedCount(filter: ClipFilter? = nil) throws -> Int {
        let statement = try db.prepare("SELECT count(*) FROM clips WHERE pinned_at IS NULL AND (\(filter?.condition ?? "1"))")
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    /// `purge(before:)` 会删掉的条数：保留时长改短之前先告诉用户。
    public func expiredCount(before date: Date) throws -> Int {
        let statement = try db.prepare("SELECT count(*) FROM clips WHERE pinned_at IS NULL AND last_copied_at < ?1")
            .bind(.double(date.timeIntervalSince1970))
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    // MARK: - 改

    /// 从面板里粘贴、复制过的挪到最前，和再复制一遍一样；来源应用不变。
    public func touch(id: Int64, at date: Date = .now) throws {
        try db.prepare("UPDATE clips SET last_copied_at = ?1 WHERE id = ?2")
            .bind(.double(date.timeIntervalSince1970), .int(id))
            .run()
    }

    /// 起名字；nil 或者全是空白就去掉名字，恢复原来的标题。
    public func rename(id: Int64, to title: String?) throws {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try db.prepare("UPDATE clips SET custom_title = ?1 WHERE id = ?2")
            .bind(title.isEmpty ? .null : .text(title), .int(id))
            .run()
    }

    /// 改文本条目的内容。格式（RTF、HTML）和改过的文字对不上了，删掉，只留纯文本；标题、搜索用的字、字数跟着改。
    /// 改完和另一条内容一样时删掉那一条，这条的置顶、名字、时间留着。
    public func editText(id: Int64, to text: String) throws {
        let hash = Capture(kind: .text, text: text, date: .now).contentHash
        try db.transaction {
            if let other = try existingID(hash: hash), other != id {
                try db.prepare("DELETE FROM clips WHERE id = ?1").bind(.int(other)).run()
            }
            try db.prepare("""
                UPDATE clips SET hash = ?1, title = ?2, search_text = ?3, text = ?4, byte_size = ?5, char_count = ?6, category = ?9
                WHERE id = ?7 AND kind = ?8
                """)
                .bind(.text(hash), .text(String(text.prefix(Self.titleLength))), .text(String(text.prefix(Self.searchLength)).lowercased()),
                      .text(text), .int(Int64(text.utf8.count)), .int(Int64(text.count)), .int(id), .int(Int64(ClipKind.text.rawValue)),
                      .int(Int64(TextCategory(text: text).rawValue)))
                .run()
            try db.prepare("DELETE FROM formats WHERE clip_id = ?1").bind(.int(id)).run()
        }
    }

    public func setPinned(_ pinned: Bool, id: Int64) throws {
        try db.prepare("UPDATE clips SET pinned_at = ?1 WHERE id = ?2")
            .bind(pinned ? .double(Date.now.timeIntervalSince1970) : .null, .int(id))
            .run()
    }

    public func delete(id: Int64) throws {
        try deleteClips(where: "id = ?1", .int(id))
    }

    /// 清空，置顶的留着；`filter` 不为 nil 时只清这一类。
    @discardableResult
    public func deleteAllUnpinned(filter: ClipFilter? = nil) throws -> Int {
        try deleteClips(where: "pinned_at IS NULL AND (\(filter?.condition ?? "1"))")
    }

    /// 删掉 `date` 以后复制的（「删除最近 5 分钟的」），置顶的不删。
    @discardableResult
    public func deleteCopied(since date: Date) throws -> Int {
        try deleteClips(where: "pinned_at IS NULL AND last_copied_at >= ?1", .double(date.timeIntervalSince1970))
    }

    /// 在置顶的里面往上（`up`）或往下挪一位：和相邻那条对调置顶时间（置顶的按置顶时间从新到旧排）。
    /// 已经在头上、底下，或者没置顶，返回 false。
    @discardableResult
    public func movePinned(id: Int64, up: Bool) throws -> Bool {
        try db.transaction {
            let current = try db.prepare("SELECT pinned_at FROM clips WHERE id = ?1 AND pinned_at IS NOT NULL").bind(.int(id))
            guard try current.step() else { return false }
            let pinnedAt = current.double(0)
            let neighbor = try db.prepare(up
                ? "SELECT id, pinned_at FROM clips WHERE pinned_at > ?1 ORDER BY pinned_at ASC LIMIT 1"
                : "SELECT id, pinned_at FROM clips WHERE pinned_at < ?1 ORDER BY pinned_at DESC LIMIT 1")
                .bind(.double(pinnedAt))
            guard try neighbor.step() else { return false }
            let (otherID, otherPinnedAt) = (neighbor.int(0), neighbor.double(1))
            let update = try db.prepare("UPDATE clips SET pinned_at = ?1 WHERE id = ?2")
            try update.bind(.double(otherPinnedAt), .int(id)).run()
            try update.bind(.double(pinnedAt), .int(otherID)).run()
            return true
        }
    }

    /// 删掉最后一次复制早于 `date` 的，置顶的不过期。
    @discardableResult
    public func purge(before date: Date) throws -> Int {
        try deleteClips(where: "pinned_at IS NULL AND last_copied_at < ?1", .double(date.timeIntervalSince1970))
    }

    /// 删行，连同它们的图片文件。格式跟着外键一起删。
    @discardableResult
    private func deleteClips(where condition: String, _ values: SQLValue...) throws -> Int {
        let (files, deleted) = try db.transaction {
            let select = try db.prepare("SELECT image_file FROM clips WHERE (\(condition)) AND image_file IS NOT NULL")
                .bind(values)
            var files: [String] = []
            while try select.step() {
                if let file = select.text(0) { files.append(file) }
            }
            try db.prepare("DELETE FROM clips WHERE \(condition)").bind(values).run()
            return (files, db.changes)
        }
        for file in files {
            try? FileManager.default.removeItem(at: imagesDirectory.appending(path: file))
            try? FileManager.default.removeItem(at: imagesDirectory.appending(path: Self.thumbnailFile(for: file)))
        }
        return deleted
    }
}

private func optional(_ value: String?) -> SQLValue {
    value.map { .text($0) } ?? .null
}

/// LIKE 里的 `%`、`_` 和转义符本身要转义。
private func escapeLike(_ string: String) -> String {
    var result = ""
    for character in string {
        if character == "%" || character == "_" || character == "\\" { result.append("\\") }
        result.append(character)
    }
    return result
}
