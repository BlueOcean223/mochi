import AppKit

/// 菜单栏图标和它的菜单。应用没有 Dock 图标（Info.plist 的 LSUIElement），打开设置、暂停、退出都从这里走。
@MainActor
final class StatusMenu {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init() {
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "剪切板历史")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.autoenablesItems = false
        // 下面三项先占位，接上功能的阶段见 plan.md。
        menu.addItem(placeholder("打开剪切板历史"))  // 阶段 2
        menu.addItem(placeholder("暂停记录"))  // 阶段 1
        menu.addItem(.separator())
        menu.addItem(placeholder("设置…", key: ","))  // 阶段 4
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    private func placeholder(_ title: String, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.isEnabled = false
        return item
    }
}
