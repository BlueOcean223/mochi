import Testing
@testable import MochiCore

@Test(arguments: [
    ("hello world", TextCategory.plain),
    ("", .plain),
    ("https://example.com/path?q=1", .link),
    ("  https://example.com  ", .link),
    ("example.com", .plain),
    ("ftp://example.com", .plain),
    ("me@example.com", .email),
    ("mailto:First.Last+tag@mail.example.co.uk", .email),
    ("me@localhost", .plain),
    ("write to me@example.com", .plain),
    ("#ff6347", .color),
    ("#FFF", .color),
    ("rgb(255, 99, 71)", .color),
    ("hsl(9 100% 64% / 0.5)", .color),
    ("#ff634", .plain),
    ("#tag", .plain),
])
func categorizesText(_ text: String, _ expected: TextCategory) {
    #expect(TextCategory(text: text) == expected)
}

@Test func longTextIsPlain() {
    #expect(TextCategory(text: "https://example.com/" + String(repeating: "a", count: 2100)) == .plain)
}

@Test func parsesHexColors() throws {
    let color = try #require(CSSColor("#FF6347"))
    #expect(color == CSSColor(red: 1, green: 99 / 255, blue: 71 / 255, alpha: 1))
    #expect(CSSColor("#f00") == CSSColor(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(CSSColor("#f008") == CSSColor(red: 1, green: 0, blue: 0, alpha: 136 / 255))
    #expect(CSSColor("#00000080")?.alpha == 128.0 / 255)
    #expect(CSSColor("#12345") == nil)
    #expect(CSSColor("#ggg") == nil)
}

@Test func parsesFunctionColors() throws {
    #expect(CSSColor("rgb(255, 0, 0)") == CSSColor(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(CSSColor("rgba(0, 0, 255, 0.5)") == CSSColor(red: 0, green: 0, blue: 1, alpha: 0.5))
    #expect(CSSColor("rgb(100% 0% 0% / 50%)") == CSSColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    #expect(CSSColor("RGB(0,0,0)") == CSSColor(red: 0, green: 0, blue: 0, alpha: 1))
    let red = try #require(CSSColor("hsl(0, 100%, 50%)"))
    #expect(abs(red.red - 1) < 1e-9 && abs(red.green) < 1e-9 && abs(red.blue) < 1e-9)
    let green = try #require(CSSColor("hsla(120deg 100% 25% / 0.3)"))
    #expect(abs(green.green - 0.5) < 1e-9 && abs(green.red) < 1e-9 && green.alpha == 0.3)
    #expect(CSSColor("rgb(256, 0, 0)") == nil)
    #expect(CSSColor("rgb(1, 2)") == nil)
    #expect(CSSColor("hsl(0, 100, 50)") == nil)
    #expect(CSSColor("rgb(" + String(repeating: "1 ", count: 40) + ")") == nil)
}
