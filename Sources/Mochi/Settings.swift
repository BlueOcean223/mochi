import Foundation

/// 保留多久。置顶的不过期。
enum Retention: Int, CaseIterable {
    case week = 7
    case month = 30
    case threeMonths = 90
    case year = 365
    case forever = 0

    /// 早于这个时间的要清掉；永久保留时是 nil。
    func cutoff(from now: Date = .now) -> Date? {
        self == .forever ? nil : now.addingTimeInterval(-Double(rawValue) * 86_400)
    }
}

/// 用户设置，存在 UserDefaults 里。设置窗口和菜单栏的「暂停记录」会改它。
@MainActor
final class Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.retentionDays: Retention.threeMonths.rawValue,
            Key.hotKeyCode: Shortcut.standard.keyCode,
            Key.hotKeyModifiers: Shortcut.standard.modifiers,
            // 钥匙串访问、系统的「密码」应用：它们多半会打密码标记，这里再兜一层。
            Key.ignoredApps: ["com.apple.keychainaccess", "com.apple.Passwords"],
        ])
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused) }
    }

    var retention: Retention {
        get { Retention(rawValue: defaults.integer(forKey: Key.retentionDays)) ?? .threeMonths }
        set { defaults.set(newValue.rawValue, forKey: Key.retentionDays) }
    }

    /// 呼出面板的快捷键，默认 ⌃⌘V。
    var shortcut: Shortcut {
        get { Shortcut(keyCode: defaults.integer(forKey: Key.hotKeyCode), modifiers: defaults.integer(forKey: Key.hotKeyModifiers)) }
        set {
            defaults.set(newValue.keyCode, forKey: Key.hotKeyCode)
            defaults.set(newValue.modifiers, forKey: Key.hotKeyModifiers)
        }
    }

    /// 这些应用在前台时复制的不记，按 bundle id。
    var ignoredApps: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.ignoredApps) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.ignoredApps) }
    }

    private enum Key {
        static let paused = "paused"
        static let retentionDays = "retentionDays"
        static let ignoredApps = "ignoredApps"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
    }
}
