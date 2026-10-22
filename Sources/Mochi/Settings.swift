import Foundation

/// 保留多久，按小时算。置顶的不过期。
enum Retention: Int, CaseIterable {
    case hour = 1
    case day = 24
    case week = 168
    case month = 720
    case threeMonths = 2160
    case year = 8760
    case forever = 0

    /// 早于这个时间的要清掉；永久保留时是 nil。
    func cutoff(from now: Date = .now) -> Date? {
        self == .forever ? nil : now.addingTimeInterval(-Double(rawValue) * 3600)
    }
}

/// 用户设置，存在 UserDefaults 里。设置窗口和菜单栏的「暂停记录」会改它。
@MainActor
final class Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 10-22 加「1 小时」以前保留时长按天存在 retentionDays 里，改成按小时存。
        if defaults.object(forKey: Key.retentionHours) == nil, let days = defaults.object(forKey: Key.legacyRetentionDays) as? Int {
            defaults.set(days * 24, forKey: Key.retentionHours)
            defaults.removeObject(forKey: Key.legacyRetentionDays)
        }
        defaults.register(defaults: [
            Key.retentionHours: Retention.threeMonths.rawValue,
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
        get { Retention(rawValue: defaults.integer(forKey: Key.retentionHours)) ?? .threeMonths }
        set { defaults.set(newValue.rawValue, forKey: Key.retentionHours) }
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
        static let retentionHours = "retentionHours"
        static let legacyRetentionDays = "retentionDays"
        static let ignoredApps = "ignoredApps"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
    }
}
