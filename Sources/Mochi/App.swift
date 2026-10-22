import AppKit
import MochiCore
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.blueocean223.mochi", category: "app")

// 入口。不用 SwiftUI 的 App 和 storyboard，生命周期交给 AppKit：
// 面板、热键、菜单栏都要直接管 NSWindow / NSStatusItem，SwiftUI 只画面板里的内容。
@main
enum MochiApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings(defaults: userDefaults())
    private var statusMenu: StatusMenu?
    private var recorder: Recorder?
    private var panel: PanelController?
    private var hotKey: GlobalHotKey?
    private var sequenceHotKey: GlobalHotKey?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logPasteboardAccess()
        NSApp.mainMenu = makeMainMenu()
        // 跑调试脚本时不放菜单栏图标，不然菜单栏上会多出一个 Mochi。
        if !isDriving {
            statusMenu = StatusMenu(settings: settings, openPanel: { [weak self] in self?.panel?.show() },
                                    openSettings: { [weak self] in self?.settingsWindow?.show() },
                                    resetPanelPosition: { [weak self] in self?.panel?.resetPosition() })
        }
        let directory = dataDirectory()
        let store: ClipStore
        do {
            store = try ClipStore(directory: directory)
        } catch {
            log.error("open store failed: \(error, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Mochi 打不开剪切板历史"
            alert.informativeText = "\(directory.path)\n\n\(error)"
            NSApp.activate()
            alert.runModal()
            return
        }
        let pasteboard = pasteboard()
        let recorder = Recorder(store: store, settings: settings, pasteboard: pasteboard)
        recorder.start()
        self.recorder = recorder
        log.notice("recording into \(directory.path, privacy: .public)")
        let paster = Paster(store: store, pasteboard: pasteboard, recorder: recorder)
        let hud = HUD()
        let panel = PanelController(store: store, settings: settings, paster: paster, hud: hud)
        self.panel = panel
        let settings = settings
        let hotKey = GlobalHotKey(load: { settings.shortcut }, save: { if let new = $0 { settings.shortcut = new } }) { [weak panel] in
            panel?.toggle()
        }
        hotKey.changed = { [weak self] shortcut in if let shortcut { self?.statusMenu?.showShortcut(shortcut) } }
        self.hotKey = hotKey
        let sequence = PasteSequence(store: store, settings: settings, paster: paster, pasteboard: pasteboard, hud: hud)
        let sequenceHotKey = GlobalHotKey(load: { settings.sequenceShortcut }, save: { settings.sequenceShortcut = $0 }) {
            sequence.pasteNext()
        }
        self.sequenceHotKey = sequenceHotKey
        let settingsWindow = SettingsWindowController(
            model: SettingsModel(settings: settings, store: store, recorder: recorder, hotKeys: [.panel: hotKey, .sequence: sequenceHotKey],
                                 paster: paster))
        self.settingsWindow = settingsWindow
        panel.openSettings = { [weak settingsWindow] in settingsWindow?.show() }
        panel.pauseChanged = { [weak self] in self?.statusMenu?.updatePauseItem() }

        #if DEBUG
        if let drive = Drive(panel: panel, settingsWindow: settingsWindow, paster: paster, pasteboard: pasteboard, sequence: sequence) {
            // 跑脚本时不占全局快捷键，免得和正在用的 Mochi 抢。
            hotKey.isQuiet = true
            sequenceHotKey.isQuiet = true
            Task {
                await Fixtures.seedIfRequested(store)
                await drive.run()
            }
            return
        }
        #endif
        hotKey.register()
        sequenceHotKey.register()
    }
}

/// 没有菜单栏菜单的应用也要一个主菜单：搜索框里的 ⌘V、⌘A、⌘Z 是靠主菜单「编辑」里的项派发的，设置窗口的 ⌘W 也是。
private func makeMainMenu() -> NSMenu {
    let edit = NSMenu(title: "编辑")
    edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let window = NSMenu(title: "窗口")
    window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let app = NSMenu(title: "Mochi")
    app.addItem(withTitle: "退出 Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let menu = NSMenu()
    for submenu in [app, edit, window] {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }
    return menu
}

private var isDriving: Bool {
    #if DEBUG
    Drive.isRequested
    #else
    false
    #endif
}

/// 调试脚本用单独的一份设置，每次清空：不读也不改用户的设置。
private func userDefaults() -> UserDefaults {
    #if DEBUG
    let suite = "com.blueocean223.mochi.drive"
    if Drive.isRequested, let defaults = UserDefaults(suiteName: suite) {
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
    #endif
    return .standard
}

/// 数据放在 `~/Library/Application Support/<bundle id>/`。
/// 调试构建可以用 `MOCHI_DATA_DIR` 指到别处，测试时不碰真实的历史。
private func dataDirectory() -> URL {
    #if DEBUG
    if let path = ProcessInfo.processInfo.environment["MOCHI_DATA_DIR"] {
        return URL(filePath: path, directoryHint: .isDirectory)
    }
    #endif
    return URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "com.blueocean223.mochi", directoryHint: .isDirectory)
}

/// 调试构建可以用 `MOCHI_PASTEBOARD` 换成一个有名字的剪切板，测试时不动用户正在用的剪切板。
private func pasteboard() -> NSPasteboard {
    #if DEBUG
    if let name = ProcessInfo.processInfo.environment["MOCHI_PASTEBOARD"] {
        return NSPasteboard(name: NSPasteboard.Name(name))
    }
    #endif
    return .general
}

/// 记下系统给的剪切板权限。macOS 15.4 起苹果预告读剪切板会弹提示，
/// 是 ask 的话每次读都可能被系统拦下来问用户，记录就不可靠了。
private func logPasteboardAccess() {
    let name = switch NSPasteboard.general.accessBehavior {
    case .default: "default"
    case .ask: "ask"
    case .alwaysAllow: "alwaysAllow"
    case .alwaysDeny: "alwaysDeny"
    @unknown default: "unknown"
    }
    log.notice("pasteboard accessBehavior=\(name, privacy: .public)")
}
