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
        // 保留时长原来按天存在 retentionDays 里，放不下「1 小时」，改成按小时存；读到旧值就换算过来。
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

    /// 面板拖过以后的位置，每块屏幕一份：面板左上角离这块屏幕可用区域左上角多远（向右、向下为正）。
    /// 键是显示器的 UUID。没拖过的屏幕没有，面板放在默认位置。
    func panelOffset(onDisplay display: String) -> CGPoint? {
        guard let values = (defaults.dictionary(forKey: Key.panelOffsets) as? [String: [Double]])?[display], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    func setPanelOffset(_ offset: CGPoint, onDisplay display: String) {
        var offsets = defaults.dictionary(forKey: Key.panelOffsets) ?? [:]
        offsets[display] = [Double(offset.x), Double(offset.y)]
        defaults.set(offsets, forKey: Key.panelOffsets)
    }

    /// 菜单栏的「窗口位置复原」：所有屏幕都回到默认位置。
    func resetPanelOffsets() {
        defaults.removeObject(forKey: Key.panelOffsets)
    }

    private enum Key {
        static let paused = "paused"
        static let retentionHours = "retentionHours"
        static let legacyRetentionDays = "retentionDays"
        static let ignoredApps = "ignoredApps"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let panelOffsets = "panelOffsets"
    }
}
