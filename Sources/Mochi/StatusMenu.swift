import AppKit

/// 菜单栏图标和它的菜单。应用没有 Dock 图标（Info.plist 的 LSUIElement），打开设置、暂停、退出都从这里走。
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: Settings
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")

    init(settings: Settings) {
        self.settings = settings
        super.init()
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Mochi")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(placeholder("打开剪切板历史"))  // 阶段 2
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(placeholder("设置…", key: ","))  // 阶段 4
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        updatePauseItem()
    }

    @objc private func togglePause() {
        settings.isPaused.toggle()
        updatePauseItem()
    }

    /// 暂停时菜单栏图标变淡，一眼能看出现在不记。
    private func updatePauseItem() {
        pauseItem.title = settings.isPaused ? "恢复记录" : "暂停记录"
        item.button?.appearsDisabled = settings.isPaused
    }

    private func placeholder(_ title: String, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.isEnabled = false
        return item
    }
}
