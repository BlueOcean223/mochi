import Foundation

/// 文本条目再细分：整段是一个网址、一个邮箱地址、一个 CSS 写法的颜色。记录时认出来存下，类型筛选和列表图标用。
public enum TextCategory: Int, Sendable {
    case plain = 0
    case link = 1
    case email = 2
    case color = 3

    /// 超过 2048 字节的一律是普通文本（Tinycast 也这么划），不去逐个规则地看长文本。
    public init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.utf8.count > 2048 {
            self = .plain
        } else if CSSColor(trimmed) != nil {
            self = .color
        } else if trimmed.contains(where: \.isWhitespace) {
            self = .plain
        } else if Self.isEmail(trimmed) {
            self = .email
        } else if Classifier.isLink(trimmed) {
            self = .link
        } else {
            self = .plain
        }
    }

    /// 一个邮箱地址，或者 mailto: 开头的。
    private static func isEmail(_ text: String) -> Bool {
        let address = text.lowercased().hasPrefix("mailto:") ? String(text.dropFirst(7)) : text
        return address.wholeMatch(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/) != nil
    }
}

/// CSS 写法的颜色：#rgb、#rgba、#rrggbb、#rrggbbaa、rgb()、rgba()、hsl()、hsla()，64 字节以内。分量都是 0–1。
public struct CSSColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.utf8.count <= 64 else { return nil }
        if text.hasPrefix("#") {
            guard let rgba = Self.hex(String(text.dropFirst())) else { return nil }
            (red, green, blue, alpha) = rgba
        } else if let match = text.wholeMatch(of: /(rgba?|hsla?)\(([^()]*)\)/) {
            let arguments = match.output.2.split { $0 == "," || $0 == "/" || $0 == " " }.map(String.init)
            guard arguments.count == 3 || arguments.count == 4 else { return nil }
            let rgba = match.output.1.hasPrefix("rgb") ? Self.rgb(arguments) : Self.hsl(arguments)
            guard let rgba else { return nil }
            (red, green, blue, alpha) = rgba
        } else {
            return nil
        }
    }

    private static func hex(_ digits: String) -> (Double, Double, Double, Double)? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let pairs: [String] = digits.count <= 4 ? digits.map { String([$0, $0]) }
                                                : stride(from: 0, to: digits.count, by: 2).map {
                                                      let start = digits.index(digits.startIndex, offsetBy: $0)
                                                      return String(digits[start..<digits.index(start, offsetBy: 2)])
                                                  }
        let values = pairs.compactMap { UInt8($0, radix: 16) }.map { Double($0) / 255 }
        return (values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
    }

    /// rgb(255, 99, 71)、rgb(100% 39% 28% / 50%)。
    private static func rgb(_ arguments: [String]) -> (Double, Double, Double, Double)? {
        let channels = arguments.prefix(3).map { number($0, percentOf: 255, plainScale: 255) }
        guard channels.allSatisfy({ $0 != nil }), let alpha = arguments.count == 4 ? number(arguments[3], percentOf: 1, plainScale: 1) : 1
        else { return nil }
        let values = channels.compactMap { $0 }
        guard values.allSatisfy((0...1).contains), (0...1).contains(alpha) else { return nil }
        return (values[0], values[1], values[2], alpha)
    }

    /// hsl(9, 100%, 64%)、hsl(9deg 100% 64% / 0.5)。
    private static func hsl(_ arguments: [String]) -> (Double, Double, Double, Double)? {
        let hueText = arguments[0].hasSuffix("deg") ? String(arguments[0].dropLast(3)) : arguments[0]
        guard let hue = Double(hueText), arguments[1].hasSuffix("%"), arguments[2].hasSuffix("%"),
              let saturation = number(arguments[1], percentOf: 1, plainScale: 1),
              let lightness = number(arguments[2], percentOf: 1, plainScale: 1),
              let alpha = arguments.count == 4 ? number(arguments[3], percentOf: 1, plainScale: 1) : 1,
              (0...1).contains(saturation), (0...1).contains(lightness), (0...1).contains(alpha) else { return nil }
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1 / 3), channel(h), channel(h - 1 / 3), alpha)
    }

    /// 「50%」按百分比，否则按 `plainScale` 除。
    private static func number(_ text: String, percentOf scale: Double, plainScale: Double) -> Double? {
        if text.hasSuffix("%") {
            return Double(text.dropLast()).map { $0 / 100 }
        }
        return Double(text).map { $0 / plainScale }
    }
}

/// 类型筛选。文本只算普通文本，链接、邮箱、颜色各是一类（照 Raycast）。
public enum ClipFilter: Int, Sendable, CaseIterable {
    case text, image, file, link, email, color

    /// SQL 条件，只用固定的列名和数字。
    var condition: String {
        switch self {
        case .text: "kind = \(ClipKind.text.rawValue) AND category = \(TextCategory.plain.rawValue)"
        case .image: "kind = \(ClipKind.image.rawValue)"
        case .file: "kind = \(ClipKind.file.rawValue)"
        case .link: "kind = \(ClipKind.text.rawValue) AND category = \(TextCategory.link.rawValue)"
        case .email: "kind = \(ClipKind.text.rawValue) AND category = \(TextCategory.email.rawValue)"
        case .color: "kind = \(ClipKind.text.rawValue) AND category = \(TextCategory.color.rawValue)"
        }
    }
}
