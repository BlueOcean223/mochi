import AppKit

/// 菜单栏图标和它的菜单。应用没有 Dock 图标（Info.plist 的 LSUIElement），打开设置、暂停、退出都从这里走。
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: Settings
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
    private let openItem = NSMenuItem(title: "打开剪切板历史", action: #selector(open), keyEquivalent: "")
    private let openPanel: () -> Void
    private let openSettings: () -> Void
    private let resetPanelPosition: () -> Void

    init(settings: Settings, openPanel: @escaping () -> Void, openSettings: @escaping () -> Void,
         resetPanelPosition: @escaping () -> Void) {
        self.settings = settings
        self.openPanel = openPanel
        self.openSettings = openSettings
        self.resetPanelPosition = resetPanelPosition
        super.init()
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Mochi")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.autoenablesItems = false
        openItem.target = self
        menu.addItem(openItem)
        showShortcut(settings.shortcut)
        pauseItem.target = self
        menu.addItem(pauseItem)
        let resetItem = NSMenuItem(title: "窗口位置复原", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        updatePauseItem()
    }

    /// 菜单里「打开剪切板历史」后面显示的是现在的呼出快捷键。
    func showShortcut(_ shortcut: Shortcut) {
        openItem.keyEquivalent = shortcut.menuKeyEquivalent
        openItem.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    @objc private func open() {
        openPanel()
    }

    @objc private func showSettings() {
        openSettings()
    }

    /// 面板拖走以后回到默认位置（屏幕中间偏上），照 Raycast 的「Reset Raycast Window Position」。
    @objc private func resetPosition() {
        resetPanelPosition()
    }

    @objc private func togglePause() {
        settings.isPaused.toggle()
        updatePauseItem()
    }

    /// 暂停时菜单栏图标变淡，一眼能看出现在不记。在面板里暂停、恢复以后也调。
    func updatePauseItem() {
        pauseItem.title = settings.isPaused ? "恢复记录" : "暂停记录"
        item.button?.appearsDisabled = settings.isPaused
    }
}
