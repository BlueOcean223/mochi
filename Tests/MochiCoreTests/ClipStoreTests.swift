import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MochiCore

private typealias T = PasteboardTypes

/// 每个测试一个临时目录，测完删掉。
private final class TempStore {
    let directory: URL
    let store: ClipStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "mochi-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try ClipStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var imageFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "images").path)) ?? []
    }
}

private func text(_ string: String, at date: Date = .now, from app: String? = nil) -> PasteboardSnapshot {
    PasteboardSnapshot(items: [.init(types: [T.plainText], data: [T.plainText: Data(string.utf8)])],
                       sourceBundleID: app, sourceName: app, date: date)
}

/// 一张纯色的 TIFF，宽 w 高 h。
private func tiff(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.8, green: 0.4, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func recordsAndListsNewestFirst() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    try await t.store.record(text("first", at: base))
    try await t.store.record(text("second", at: base + 10, from: "com.apple.Safari"))
    let clips = try await t.store.list()
    #expect(clips.map(\.title) == ["second", "first"])
    #expect(clips[0].sourceBundleID == "com.apple.Safari")
    #expect(clips[0].characterCount == 6)
    #expect(clips[0].kind == .text)
}

@Test func sameContentIsBumpedNotDuplicated() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    let first = try await t.store.record(text("same", at: base, from: "a"))
    try await t.store.record(text("other", at: base + 5))
    let again = try await t.store.record(text("same", at: base + 10, from: "b"))
    guard case .inserted(let id) = first else { Issue.record("第一次应该是新增"); return }
    #expect(again == .bumped(id))
    let clips = try await t.store.list()
    #expect(clips.map(\.title) == ["same", "other"])
    #expect(clips[0].firstCopiedAt == base)
    #expect(clips[0].lastCopiedAt == base + 10)
    #expect(clips[0].sourceBundleID == "b")
    #expect(try await t.store.count() == 2)
}

@Test func bumpReplacesFormats() async throws {
    let t = try TempStore()
    let html = PasteboardSnapshot(items: [.init(types: [T.plainText, T.html],
                                                data: [T.plainText: Data("x".utf8), T.html: Data("<b>x</b>".utf8)])])
    guard case .inserted(let id) = try await t.store.record(html) else { Issue.record("应该是新增"); return }
    #expect(try await t.store.formats(of: id) == [T.html: Data("<b>x</b>".utf8)])
    try await t.store.record(text("x"))
    #expect(try await t.store.formats(of: id).isEmpty)
}

@Test func skippedSnapshotsAreNotStored() async throws {
    let t = try TempStore()
    let secret = PasteboardSnapshot(items: [.init(types: [T.plainText, "org.nspasteboard.ConcealedType"],
                                                  data: [T.plainText: Data("hunter2".utf8)])])
    #expect(try await t.store.record(secret) == .skipped(.marked("org.nspasteboard.ConcealedType")))
    #expect(try await t.store.count() == 0)
}

@Test func pinnedComeFirstAndSurvivePurgeAndClear() async throws {
    let t = try TempStore()
    let old = Date(timeIntervalSince1970: 1_000_000)
    guard case .inserted(let pinnedID) = try await t.store.record(text("pinned old", at: old)) else { Issue.record("应该是新增"); return }
    try await t.store.record(text("old", at: old + 1))
    try await t.store.record(text("new", at: .now))
    try await t.store.setPinned(true, id: pinnedID)
    #expect(try await t.store.list().map(\.title) == ["pinned old", "new", "old"])

    #expect(try await t.store.expiredCount(before: old + 100) == 1)
    #expect(try await t.store.purge(before: old + 100) == 1)
    #expect(try await t.store.list().map(\.title) == ["pinned old", "new"])

    #expect(try await t.store.deleteAllUnpinned() == 1)
    #expect(try await t.store.list().map(\.title) == ["pinned old"])

    try await t.store.setPinned(false, id: pinnedID)
    #expect(try await t.store.list()[0].isPinned == false)
}

@Test func searchIsCaseInsensitiveAndFindsChinese() async throws {
    let t = try TempStore()
    try await t.store.record(text("Hello World"))
    try await t.store.record(text("今天天气不错"))
    try await t.store.record(text("100% sure_thing"))
    #expect(try await t.store.list(matching: "hello").map(\.title) == ["Hello World"])
    #expect(try await t.store.list(matching: "天气").map(\.title) == ["今天天气不错"])
    // % 和 _ 按字面匹配，不当通配符
    #expect(try await t.store.list(matching: "0%").map(\.title) == ["100% sure_thing"])
    #expect(try await t.store.list(matching: "e_t").map(\.title) == ["100% sure_thing"])
    #expect(try await t.store.list(matching: "_").count == 1)
}

@Test func filterByKindAndPage() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<5 { try await t.store.record(text("t\(i)", at: base + Double(i))) }
    let file = PasteboardSnapshot(items: [.init(types: [T.fileURL], data: [T.fileURL: Data("file:///tmp/report.pdf".utf8)])],
                                  date: base + 10)
    try await t.store.record(file)

    let files = try await t.store.list(filter: .file)
    #expect(files.map(\.title) == ["report.pdf"])
    #expect(files[0].fileURLs == [URL(filePath: "/tmp/report.pdf")])
    #expect(try await t.store.list(matching: "report").count == 1)

    #expect(try await t.store.list(filter: .text, limit: 2).map(\.title) == ["t4", "t3"])
    #expect(try await t.store.list(filter: .text, limit: 2, offset: 2).map(\.title) == ["t2", "t1"])
}

@Test func imagesAreStoredAsPNGFilesAndDeletedWithTheClip() async throws {
    let t = try TempStore()
    let snapshot = PasteboardSnapshot(items: [.init(types: [T.tiff], data: [T.tiff: try tiff(width: 40, height: 30)])])
    guard case .inserted(let id) = try await t.store.record(snapshot) else { Issue.record("应该是新增"); return }

    let clip = try #require(try await t.store.list().first)
    #expect(clip.kind == .image)
    #expect(clip.imageWidth == 40 && clip.imageHeight == 30)
    #expect(clip.title == "图片 40×30")
    let url = try #require(clip.imageURL)
    #expect(url.pathExtension == "png")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(clip.byteSize == (try Data(contentsOf: url)).count)
    let thumbnail = try #require(clip.thumbnailURL.flatMap { Images.downsample($0, maxPixel: 1000) })
    #expect(thumbnail.width == 40 && thumbnail.height == 30)
    #expect(t.imageFiles.count == 2)

    try await t.store.delete(id: id)
    #expect(try await t.store.count() == 0)
    #expect(t.imageFiles.isEmpty)
}

@Test func thumbnailIsShrunkAndCanBeMadeLater() async throws {
    let t = try TempStore()
    try await t.store.record(PasteboardSnapshot(items: [.init(types: [T.tiff], data: [T.tiff: try tiff(width: 400, height: 300)])]))
    let clip = try #require(try await t.store.list().first)
    let thumbnailURL = try #require(clip.thumbnailURL)
    let stored = try #require(Images.downsample(thumbnailURL, maxPixel: 1000))
    #expect(stored.width == ClipStore.thumbnailPixels && stored.height == 72)

    // 没存小图的老条目：用时从原图生成，存下来。
    try FileManager.default.removeItem(at: thumbnailURL)
    let imageURL = try #require(clip.imageURL)
    let made = try #require(ClipStore.makeThumbnail(of: imageURL, at: thumbnailURL))
    #expect(made.width == ClipStore.thumbnailPixels)
    #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
}

@Test func reopeningKeepsData() async throws {
    let t = try TempStore()
    try await t.store.record(text("persisted"))
    let reopened = try ClipStore(directory: t.directory)
    #expect(try await reopened.list().map(\.title) == ["persisted"])
    #expect(try await reopened.text(of: try await reopened.list()[0].id) == "persisted")
}

@Test func linkOnlyWhenWholeTextIsOneURL() async throws {
    let t = try TempStore()
    try await t.store.record(text("https://example.com/a?b=1"))
    try await t.store.record(text("看这个 https://example.com"))
    // 比标题（300 字）长的网址按全文认；超过 2048 字节的不认。
    try await t.store.record(text("https://example.com/" + String(repeating: "a", count: 400)))
    try await t.store.record(text("https://example.com/" + String(repeating: "a", count: 2100)))
    let clips = try await t.store.list()
    #expect(clips.map(\.isLink) == [false, true, false, true])
}

@Test func touchMovesToTopAndKeepsSource() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    try await t.store.record(text("old", at: base, from: "com.apple.Safari"))
    try await t.store.record(text("new", at: base + 10))
    let old = try #require(try await t.store.list().last)
    try await t.store.touch(id: old.id, at: base + 20)
    let clips = try await t.store.list()
    #expect(clips.map(\.title) == ["old", "new"])
    #expect(clips[0].sourceBundleID == "com.apple.Safari")
    #expect(clips[0].firstCopiedAt == base)
}

@Test func unpinnedCountSkipsPinned() async throws {
    let t = try TempStore()
    try await t.store.record(text("a"))
    try await t.store.record(text("b"))
    try await t.store.record(text("c"))
    let first = try #require(try await t.store.list().first)
    try await t.store.setPinned(true, id: first.id)
    #expect(try await t.store.unpinnedCount() == 2)
}

@Test func movePinnedSwapsWithNeighbor() async throws {
    let t = try TempStore()
    var ids: [String: Int64] = [:]
    for name in ["a", "b", "c", "d"] {
        guard case .inserted(let id) = try await t.store.record(text(name)) else { Issue.record("应该是新增"); return }
        ids[name] = id
    }
    for name in ["a", "b", "c"] {
        try await t.store.setPinned(true, id: ids[name]!)
        try await Task.sleep(for: .milliseconds(2))
    }
    // 后置顶的在上面
    #expect(try await t.store.list().map(\.title) == ["c", "b", "a", "d"])
    #expect(try await t.store.movePinned(id: ids["a"]!, up: true))
    #expect(try await t.store.list().map(\.title) == ["c", "a", "b", "d"])
    #expect(try await t.store.movePinned(id: ids["c"]!, up: false))
    #expect(try await t.store.list().map(\.title) == ["a", "c", "b", "d"])
    // 已经在头上、底下，没置顶的
    #expect(try await !t.store.movePinned(id: ids["a"]!, up: true))
    #expect(try await !t.store.movePinned(id: ids["b"]!, up: false))
    #expect(try await !t.store.movePinned(id: ids["d"]!, up: true))
}

@Test func deleteCopiedSinceSkipsPinnedAndOlder() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    try await t.store.record(text("old", at: base))
    try await t.store.record(text("recent", at: base + 10))
    guard case .inserted(let pinnedID) = try await t.store.record(text("recent pinned", at: base + 20)) else { Issue.record("应该是新增"); return }
    try await t.store.setPinned(true, id: pinnedID)
    #expect(try await t.store.deleteCopied(since: base + 5) == 1)
    #expect(Set(try await t.store.list().map(\.title)) == ["old", "recent pinned"])
}

@Test func clearCanStayInOneKind() async throws {
    let t = try TempStore()
    try await t.store.record(text("words"))
    try await t.store.record(PasteboardSnapshot(items: [.init(types: [T.tiff], data: [T.tiff: try tiff(width: 40, height: 30)])],
                                                sourceBundleID: nil, sourceName: nil, date: .now))
    #expect(try await t.store.unpinnedCount(filter: .image) == 1)
    #expect(try await t.store.unpinnedCount() == 2)
    #expect(try await t.store.deleteAllUnpinned(filter: .image) == 1)
    #expect(try await t.store.list().map(\.title) == ["words"])
    #expect(t.imageFiles.isEmpty)
}

@Test func formatTypesListsStoredFormats() async throws {
    let t = try TempStore()
    let snapshot = PasteboardSnapshot(items: [.init(types: [T.plainText, T.rtf, T.html],
                                                    data: [T.plainText: Data("hi".utf8), T.rtf: Data("{\\rtf1 hi}".utf8),
                                                           T.html: Data("<b>hi</b>".utf8)])],
                                      sourceBundleID: nil, sourceName: nil, date: .now)
    guard case .inserted(let id) = try await t.store.record(snapshot) else { Issue.record("应该是新增"); return }
    #expect(try await t.store.formatTypes(of: id) == [T.html, T.rtf])
}

@Test func renameShowsAndSearchesTheName() async throws {
    let t = try TempStore()
    guard case .inserted(let id) = try await t.store.record(text("ssh deploy@10.0.3.12")) else { Issue.record("应该是新增"); return }
    try await t.store.rename(id: id, to: "  生产服务器  ")
    #expect(try await t.store.list().first?.customTitle == "生产服务器")
    #expect(try await t.store.list(matching: "生产").map(\.id) == [id])
    #expect(try await t.store.list(matching: "deploy").map(\.id) == [id])
    try await t.store.rename(id: id, to: " ")
    #expect(try await t.store.list().first?.customTitle == nil)
}

@Test func editTextDropsFormatsAndMergesDuplicates() async throws {
    let t = try TempStore()
    let rich = PasteboardSnapshot(items: [.init(types: [T.plainText, T.html],
                                                data: [T.plainText: Data("draft".utf8), T.html: Data("<b>draft</b>".utf8)])])
    guard case .inserted(let id) = try await t.store.record(rich) else { Issue.record("应该是新增"); return }
    try await t.store.record(text("final"))
    try await t.store.setPinned(true, id: id)
    try await t.store.editText(id: id, to: "final")
    let clips = try await t.store.list()
    #expect(clips.count == 1)
    #expect(clips[0].id == id)
    #expect(clips[0].isPinned)
    #expect(clips[0].title == "final")
    #expect(clips[0].characterCount == 5)
    #expect(try await t.store.text(of: id) == "final")
    #expect(try await t.store.formats(of: id).isEmpty)
    #expect(try await t.store.list(matching: "fin").map(\.id) == [id])
    // 改过的内容再复制一遍，合并到这一条
    #expect(try await t.store.record(text("final")) == .bumped(id))
}

@Test func migratesVersionOneDatabase() async throws {
    let t = try TempStore()
    try await t.store.record(text("old row"))
    let db = try Database(path: t.directory.appending(path: "mochi.sqlite").path)
    try db.execute("ALTER TABLE clips DROP COLUMN custom_title; ALTER TABLE clips DROP COLUMN category; PRAGMA user_version = 1;")
    let reopened = try ClipStore(directory: t.directory)
    let clips = try await reopened.list()
    #expect(clips.map(\.title) == ["old row"])
    #expect(clips[0].customTitle == nil)
    try await reopened.rename(id: clips[0].id, to: "named")
    #expect(try await reopened.list()[0].customTitle == "named")
}

@Test func textCategoriesAreFilters() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    for (i, string) in ["hello", "https://example.com/a", "me@example.com", " #FF6347 ", "rgb(1 2 3)"].enumerated() {
        try await t.store.record(text(string, at: base + Double(i)))
    }
    #expect(try await t.store.list(filter: .text).map(\.title) == ["hello"])
    #expect(try await t.store.list(filter: .link).map(\.title) == ["https://example.com/a"])
    #expect(try await t.store.list(filter: .email).map(\.title) == ["me@example.com"])
    #expect(try await t.store.list(filter: .color).map(\.title) == ["rgb(1 2 3)", " #FF6347 "])
    #expect(try await t.store.list(filter: .link)[0].isLink)
    #expect(try await t.store.unpinnedCount(filter: .color) == 2)
    #expect(try await t.store.deleteAllUnpinned(filter: .color) == 2)
    #expect(try await t.store.list().count == 3)
}

@Test func editingTextRedoesItsCategory() async throws {
    let t = try TempStore()
    guard case .inserted(let id) = try await t.store.record(text("hello")) else { Issue.record("应该是新增"); return }
    try await t.store.editText(id: id, to: "#abc")
    #expect(try await t.store.list()[0].category == .color)
    try await t.store.editText(id: id, to: "#abc is a color")
    #expect(try await t.store.list()[0].category == .plain)
}

@Test func migrationFillsInCategories() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    try await t.store.record(text("plain words", at: base))
    try await t.store.record(text("https://example.com", at: base + 1))
    try await t.store.record(text("#fff", at: base + 2))
    let db = try Database(path: t.directory.appending(path: "mochi.sqlite").path)
    try db.execute("ALTER TABLE clips DROP COLUMN category; PRAGMA user_version = 2;")
    let reopened = try ClipStore(directory: t.directory)
    #expect(try await reopened.list().map(\.category) == [.color, .link, .plain])
    #expect(try await reopened.list(filter: .text).map(\.title) == ["plain words"])
}

@Test func sequenceGoesToOlderUnpinnedClips() async throws {
    let t = try TempStore()
    let base = Date(timeIntervalSince1970: 1_000_000)
    for (i, title) in ["a", "b", "pinned", "c"].enumerated() {
        guard case .inserted(let id) = try await t.store.record(text(title, at: base + Double(i))) else { continue }
        if title == "pinned" { try await t.store.setPinned(true, id: id) }
    }
    var titles: [String] = []
    var last: Int64?
    while let clip = try await t.store.unpinnedClip(before: last) {
        titles.append(clip.title)
        last = clip.id
    }
    #expect(titles == ["c", "b", "a"])
}
