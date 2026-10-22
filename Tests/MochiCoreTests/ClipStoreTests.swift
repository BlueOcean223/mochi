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

    let files = try await t.store.list(kind: .file)
    #expect(files.map(\.title) == ["report.pdf"])
    #expect(files[0].fileURLs == [URL(filePath: "/tmp/report.pdf")])
    #expect(try await t.store.list(matching: "report").count == 1)

    #expect(try await t.store.list(kind: .text, limit: 2).map(\.title) == ["t4", "t3"])
    #expect(try await t.store.list(kind: .text, limit: 2, offset: 2).map(\.title) == ["t2", "t1"])
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
    // 比标题长的文本：标题只是开头，开头像网址也不算。
    try await t.store.record(text("https://example.com/" + String(repeating: "a", count: 400)))
    let clips = try await t.store.list()
    #expect(clips.map(\.isLink) == [false, false, true])
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
