import AppKit
import Carbon.HIToolbox
import MochiCore
import ServiceManagement
import SwiftUI

/// 设置窗口。和面板不一样，它是普通的有标题栏的窗口：要点选、要能切走再回来。
/// 打开时激活 Mochi，关掉时把前台还给打开前的那个应用。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    /// 调试脚本在跑（`Drive`）：窗口压在桌面壁纸下面，不激活、不接鼠标；开机启动、系统设置都不真的动。
    var isQuiet = false {
        didSet { model.isQuiet = isQuiet }
    }

    init(model: SettingsModel) {
        self.model = model
        super.init()
        // 录快捷键时窗口收到的按键都给录制，不派给按钮、开关，也不触发菜单里的 ⌘W、⌘Q。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.model.isRecording, let window = self.window, event.window === window else { return event }
            self.model.handleRecording(event)
            return nil
        }
    }

    var windowNumber: Int? { window?.windowNumber }
    var sheetWindowNumber: Int? { window?.attachedSheet?.windowNumber }

    func show() {
        let window = self.window ?? makeWindow()
        model.refresh()
        if isQuiet {
            window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            return
        }
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Mochi 设置"
        window.isReleasedWhenClosed = false
        // 在别的桌面上开着时，点「设置…」把它挪到当前桌面，不跳过去。
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    /// 从系统设置授权回来、在登录项里改完回来，状态要重新读。
    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }

    func windowDidResignKey(_ notification: Notification) {
        model.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        // 菜单栏应用关掉最后一个窗口后系统不会把前台交回去，键盘就没地方去了。
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
    }
}

/// 设置窗口里显示的状态和改设置的操作。改完马上存、马上生效，没有「应用」按钮。
@MainActor
@Observable
final class SettingsModel {
    struct IgnoredApp: Identifiable {
        let id: String  // bundle id
        let name: String
        let icon: NSImage
    }

    /// 改短保留时长、会删掉记录时，先问一句。
    struct RetentionChange {
        let retention: Retention
        let count: Int
    }

    enum LoginItem { case off, on, needsApproval }

    private(set) var shortcut: Shortcut
    private(set) var isRecording = false
    /// 录快捷键时已经按住的修饰键，比如「⌃⌘」。
    private(set) var heldModifiers = ""
    private(set) var shortcutProblem: String?
    private(set) var retention: Retention
    var retentionChange: RetentionChange?
    private(set) var loginItem = LoginItem.off
    private(set) var loginProblem: String?
    private(set) var ignoredApps: [IgnoredApp] = []
    private(set) var isTrusted = false

    @ObservationIgnored var isQuiet = false
    private let settings: Settings
    private let store: ClipStore
    private let recorder: Recorder
    private let hotKey: PanelHotKey
    private let paster: Paster

    init(settings: Settings, store: ClipStore, recorder: Recorder, hotKey: PanelHotKey, paster: Paster) {
        self.settings = settings
        self.store = store
        self.recorder = recorder
        self.hotKey = hotKey
        self.paster = paster
        shortcut = settings.shortcut
        retention = settings.retention
    }

    func refresh() {
        shortcut = settings.shortcut
        retention = settings.retention
        isTrusted = paster.canPaste
        refreshLoginItem()
        loadIgnoredApps()
        if !isRecording {
            shortcutProblem = hotKey.isRegistered ? nil : "现在没生效，换一个试试"
        }
    }

    // MARK: - 呼出快捷键

    func startRecording() {
        guard !isRecording else { return }
        hotKey.suspend()
        isRecording = true
        heldModifiers = ""
        shortcutProblem = nil
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = ""
        hotKey.register()
        shortcutProblem = hotKey.isRegistered ? nil : "现在没生效，换一个试试"
    }

    /// 录快捷键时的按键。Esc 不带修饰键是取消；不能用的组合说明原因，接着录。
    func handleRecording(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            heldModifiers = Shortcut.symbols(Shortcut.carbonModifiers(event.modifierFlags))
        case .keyDown where !event.isARepeat:
            let new = Shortcut(event)
            if new == Shortcut(keyCode: kVK_Escape, modifiers: 0) {
                stopRecording()
            } else if !new.leavesTypingAlone {
                shortcutProblem = "要带上 ⌃、⌥、⌘ 里的一个，F 键可以单按"
            } else if new == Shortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey) {
                shortcutProblem = "⌘V 是粘贴，Mochi 粘贴时自己要按它"
            } else if new.isTakenBySystem {
                shortcutProblem = "\(new.description) 是系统快捷键，换一个"
            } else {
                isRecording = false
                heldModifiers = ""
                if hotKey.change(to: new) {
                    shortcut = new
                    shortcutProblem = nil
                } else {
                    shortcutProblem = "\(new.description) 注册不上，还用 \(shortcut.description)"
                }
            }
        default:
            break
        }
    }

    // MARK: - 保留时长

    func chooseRetention(_ new: Retention) {
        guard new != retention else { return }
        guard let cutoff = new.cutoff() else {
            apply(new)
            return
        }
        Task {
            let count = (try? await store.expiredCount(before: cutoff)) ?? 0
            if count == 0 {
                apply(new)
            } else {
                retentionChange = RetentionChange(retention: new, count: count)
            }
        }
    }

    func confirmRetentionChange() {
        if let change = retentionChange { apply(change.retention) }
        retentionChange = nil
    }

    private func apply(_ new: Retention) {
        settings.retention = new
        retention = new
        recorder.purge()
    }

    // MARK: - 开机启动

    func setLaunchAtLogin(_ on: Bool) {
        loginProblem = nil
        if isQuiet {
            print("settings: 开机启动 \(on ? "开" : "关")（调试脚本，不真的改）")
            loginItem = on ? .on : .off
            return
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("login item \(on ? "register" : "unregister", privacy: .public) failed: \(error, privacy: .public)")
            loginProblem = "没\(on ? "开" : "关")成：\(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    func openLoginItems() {
        guard !isQuiet else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshLoginItem() {
        guard !isQuiet else { return }
        loginItem = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    // MARK: - 忽略的应用

    /// 从选文件的窗口选来的 .app。读不出 bundle id 的跳过。
    func ignoreApps(at urls: [URL]) {
        let ids = urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !ids.isEmpty else { return }
        settings.ignoredApps.formUnion(ids)
        loadIgnoredApps()
    }

    func stopIgnoring(_ id: String) {
        settings.ignoredApps.remove(id)
        loadIgnoredApps()
    }

    /// 卸载了的应用还留在列表里，显示 bundle id。
    private func loadIgnoredApps() {
        ignoredApps = settings.ignoredApps.map { id in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                IgnoredApp(id: id, name: FileManager.default.displayName(atPath: url.path), icon: NSWorkspace.shared.icon(forFile: url.path))
            } else {
                IgnoredApp(id: id, name: id, icon: NSWorkspace.shared.icon(for: .applicationBundle))
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - 辅助功能

    func openAccessibilitySettings() {
        guard !isQuiet else { return }
        paster.openAccessibilitySettings()
    }
}
