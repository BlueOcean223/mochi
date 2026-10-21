import Foundation
import Testing
@testable import MochiCore

private typealias T = PasteboardTypes

private func item(_ data: [String: Data], extraTypes: [String] = []) -> PasteboardSnapshot.Item {
    .init(types: Array(data.keys) + extraTypes, data: data)
}

private func utf8(_ string: String) -> Data { Data(string.utf8) }

private func capture(_ snapshot: PasteboardSnapshot) throws -> Capture {
    guard case .capture(let capture) = Classifier.classify(snapshot) else {
        Issue.record("应该记下来，结果被跳过了")
        throw CancellationError()
    }
    return capture
}

private func skipReason(_ snapshot: PasteboardSnapshot) -> SkipReason? {
    if case .skip(let reason) = Classifier.classify(snapshot) { return reason }
    return nil
}

@Test func plainTextIsText() throws {
    let c = try capture(.init(items: [item([T.plainText: utf8("你好 hello")])]))
    #expect(c.kind == .text)
    #expect(c.text == "你好 hello")
}

@Test func textKeepsFormatsButNotOtherTypes() throws {
    let c = try capture(.init(items: [item([T.plainText: utf8("hi"), T.rtf: utf8("{\\rtf1 hi}"), T.html: utf8("<b>hi</b>")])]))
    #expect(Set(c.formats.keys) == [T.rtf, T.html])
}

@Test func passwordsAreSkippedByMarker() {
    let snapshot = PasteboardSnapshot(items: [item([T.plainText: utf8("hunter2")], extraTypes: ["org.nspasteboard.ConcealedType"])])
    #expect(skipReason(snapshot) == .marked("org.nspasteboard.ConcealedType"))
}

@Test func markerOnAnyItemSkipsEverything() {
    let snapshot = PasteboardSnapshot(items: [
        item([T.plainText: utf8("a")]),
        item([:], extraTypes: ["com.apple.is-sensitive"]),
    ])
    #expect(skipReason(snapshot) == .marked("com.apple.is-sensitive"))
}

@Test func blankTextIsSkipped() {
    #expect(skipReason(.init(items: [item([T.plainText: utf8(" \n\t ")])])) == .empty)
    #expect(skipReason(.init(items: [])) == .empty)
}

@Test func rtfWithoutPlainTextIsSkipped() {
    #expect(skipReason(.init(items: [item([T.rtf: utf8("{\\rtf1 hi}")])])) == .empty)
}

@Test func filesFromAllItemsInOrder() throws {
    let snapshot = PasteboardSnapshot(items: [
        item([T.fileURL: utf8("file:///Users/me/a.png"), T.tiff: Data([1, 2, 3])]),
        item([T.fileURL: utf8("file:///Users/me/b%20c.pdf")]),
    ])
    let c = try capture(snapshot)
    #expect(c.kind == .file)
    #expect(c.fileURLs.map(\.path) == ["/Users/me/a.png", "/Users/me/b c.pdf"])
}

@Test func imageWithoutTextIsImage() throws {
    let c = try capture(.init(items: [item([T.png: Data([1, 2, 3])])]))
    #expect(c.kind == .image)
    #expect(c.imageType == T.png)
}

/// Word、Excel 复制文字时顺带一张选区的图，要的是文字。
@Test func textWithImageIsText() throws {
    let c = try capture(.init(items: [item([T.plainText: utf8("A1\tB1"), T.tiff: Data([1, 2, 3])])]))
    #expect(c.kind == .text)
}

/// Safari 拷贝图片时带的文本是图片的网址，要的是图片。
@Test func imageWithLinkTextIsImage() throws {
    let c = try capture(.init(items: [item([T.plainText: utf8("https://example.com/cat.jpg"), T.tiff: Data([1, 2, 3])])]))
    #expect(c.kind == .image)
}

@Test func linkDetection() {
    #expect(Classifier.isLink("https://example.com/a?b=c"))
    #expect(Classifier.isLink("  http://example.com\n"))
    #expect(!Classifier.isLink("see https://example.com"))
    #expect(!Classifier.isLink("ftp://example.com"))
    #expect(!Classifier.isLink("example.com"))
}

@Test func tooLargeTextIsSkipped() {
    let big = Data(repeating: UInt8(ascii: "a"), count: Classifier.maxTextBytes + 1)
    #expect(skipReason(.init(items: [item([T.plainText: big])])) == .tooLarge)
}

@Test func sameTextSameHashRegardlessOfFormat() throws {
    let a = try capture(.init(items: [item([T.plainText: utf8("same")])]))
    let b = try capture(.init(items: [item([T.plainText: utf8("same"), T.html: utf8("<i>same</i>")])]))
    let c = try capture(.init(items: [item([T.plainText: utf8("other")])]))
    #expect(a.contentHash == b.contentHash)
    #expect(a.contentHash != c.contentHash)
}
