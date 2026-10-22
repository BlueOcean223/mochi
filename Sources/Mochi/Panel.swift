import AppKit
import Carbon.HIToolbox
import MochiCore
import SwiftUI

/// 呼出的面板。不激活：弹出时前台应用还是原来那个，键盘输入进面板。
final class ClipPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: PanelMetrics.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // 每个桌面都能弹，全屏应用上面也能盖住；不进 ⌘` 的窗口轮换。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 焦点一直留在搜索框：点列表行、按钮时 SwiftUI 的视图会要第一响应者，不给。
    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let responder, !(responder is NSText || responder is NSTextField), firstResponder is NSText {
            return false
        }
        return super.makeFirstResponder(responder)
    }
}

/// 管面板的显示、收起和键盘。面板只建一次，收起时藏起来不销毁，再呼出时不用重建，出来得快。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: PanelModel
    private let panel = ClipPanel()
    private let settings: Settings
    private let paster: Paster
    private let hud: HUD
    private let quickLook = QuickLook()
    private var wantsVisible = false
    private var keyMonitor: Any?
    var openSettings: (() -> Void)?

    /// 调试脚本在跑（`Drive`）：面板压在桌面壁纸下面，用户看不见；不抢键盘、不接鼠标，失焦也不收起；
    /// 不发 ⌘V，不打开 Finder、浏览器。
    var isQuiet = false {
        didSet {
            panel.level = isQuiet ? NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 1) : .floating
            panel.ignoresMouseEvents = isQuiet
            quickLook.level = panel.level
            paster.isQuiet = isQuiet
            hud.isQuiet = isQuiet
        }
    }

    init(store: ClipStore, settings: Settings, paster: Paster, hud: HUD) {
        model = PanelModel(store: store)
        self.settings = settings
        self.paster = paster
        self.hud = hud
        super.init()
        panel.delegate = self
        panel.contentView = makeContentView()
        model.perform = { [weak self] command in self?.perform(command) }
        model.selectionChanged = { [weak self] clip in self?.followSelection(clip) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    var windowNumber: Int { panel.windowNumber }
    var frame: NSRect { panel.frame }
    var contentView: NSView? { panel.contentView }
    private let tint = LightTintView()

    /// 浅色外观下盖在毛玻璃上的那层白有多浓。
    var lightTint: CGFloat {
        get { tint.alpha }
        set { tint.alpha = newValue }
    }
    var quickLookWindowNumber: Int { quickLook.windowNumber }

    private func makeContentView() -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: PanelMetrics.size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedRectMask(radius: PanelMetrics.cornerRadius)
        tint.frame = effect.bounds
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)
        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        return effect
    }

    // MARK: - 显示、收起

    func toggle() {
        wantsVisible ? hide() : show()
    }

    func show() {
        guard !wantsVisible else { return }
        wantsVisible = true
        let frontApp = NSWorkspace.shared.frontmostApplication
        Task {
            // 先把第一页读好再显示，免得先露出上次的列表再跳。
            await model.prepare(isPaused: settings.isPaused, frontAppName: frontApp?.localizedName, canPaste: paster.canPaste)
            guard wantsVisible else { return }
            panel.setFrameOrigin(origin())
            if isQuiet {
                panel.orderFrontRegardless()
            } else {
                panel.makeKeyAndOrderFront(nil)
                focusSearchField()
            }
            panel.invalidateShadow()
        }
    }

    func hide() {
        wantsVisible = false
        model.isTypeMenuOpen = false
        model.cancelClear()
        quickLook.close()
        panel.orderOut(nil)
    }

    /// 点了面板外面（别的应用、桌面），面板就不是 key 了。
    func windowDidResignKey(_ notification: Notification) {
        if !isQuiet { hide() }
    }

    /// 鼠标所在屏幕，水平居中，竖直方向偏上。
    private func origin() -> NSPoint {
        let size = PanelMetrics.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        return NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.minY + (frame.height - size.height) * 0.62).rounded())
    }

    private func focusSearchField() {
        // 第一次显示时 SwiftUI 可能还没建出搜索框，先排一次版。
        panel.contentView?.layoutSubtreeIfNeeded()
        if let field = panel.contentView?.firstSubview(of: NSTextField.self) {
            panel.makeFirstResponder(field)
        } else {
            log.error("search field not found")
        }
    }

    // MARK: - 键盘

    /// 方向键、回车、各个操作的快捷键在这里截下来，剩下的（打字、⌘A、⌘V）照常进搜索框。
    /// 返回真表示处理了，事件不再往下传。
    func handleKey(_ event: NSEvent) -> Bool {
        // 输入法正在拼字时方向键、回车是给输入法的。
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let command = PanelCommand(event)
        if model.clearConfirmation != nil {
            // 确认框开着时只认回车（清空）和 Esc（取消），别的键都吞掉。
            if command == .paste {
                Task { await model.confirmClear() }
            } else if command == .escape {
                model.cancelClear()
            }
            return true
        }
        if quickLook.isVisible, command == .escape {
            quickLook.close()
            return true
        }
        if model.isTypeMenuOpen {
            switch command {
            case .down: model.moveTypeMenu(1)
            case .up: model.moveTypeMenu(-1)
            case .paste: model.chooseType()
            case .escape, .typeMenu: model.isTypeMenuOpen = false
            default:
                model.isTypeMenuOpen = false
                return false
            }
            return true
        }
        guard let command else { return false }
        perform(command)
        return true
    }

    func perform(_ command: PanelCommand) {
        switch command {
        case .down: model.move(1)
        case .up: model.move(-1)
        case .sectionDown: model.jumpSection(1)
        case .sectionUp: model.jumpSection(-1)
        case .typeMenu: model.toggleTypeMenu()
        case .escape:
            if model.query.isEmpty { hide() } else { model.setQuery("") }
        case .paste: paste(plainText: false, sendKeystroke: true)
        case .pastePlain: paste(plainText: true, sendKeystroke: true)
        case .copy: paste(plainText: false, sendKeystroke: false)
        case .pin: Task { await model.togglePin() }
        case .delete: Task { await model.deleteSelected() }
        case .clearAll:
            Task {
                if await !model.askToClear() { hud.show("没有可以清空的，置顶的不删") }
            }
        case .quickLook: toggleQuickLook()
        case .revealInFinder: revealInFinder()
        case .openLink: openLink()
        case .openAccessibilitySettings:
            hide()
            paster.openAccessibilitySettings()
        case .settings:
            hide()
            openSettings?()
        }
    }

    // MARK: - 操作

    /// 回车粘贴、⇧↵ 粘贴纯文本、⌘↵ 只复制。先收起面板，键盘焦点回到前台应用，写好剪切板再替用户按 ⌘V。
    /// 没有辅助功能权限时只复制，提示一句，再弹一次系统的授权提示。
    private func paste(plainText: Bool, sendKeystroke: Bool) {
        guard let clip = model.selectedClip else { return }
        hide()
        Task {
            var note: String?
            switch await paster.write(clip, plainText: plainText && clip.kind == .text) {
            case .written:
                break
            case .failed:
                hud.show("没能写进剪切板")
                return
            case .missingFiles(let missing, let total) where missing == total:
                hud.show(total == 1 ? "文件已经不在了" : "这些文件都已经不在了")
                return
            case .missingFiles(let missing, _):
                note = "有 \(missing) 个文件已经不在了"
            }
            if !sendKeystroke {
                hud.show(note.map { "已复制，\($0)" } ?? "已复制到剪切板")
            } else if paster.canPaste {
                await paster.sendPasteKeystroke()
                if let note { hud.show(note) }
            } else {
                hud.show("已复制。没有辅助功能权限，要自己按 ⌘V")
                paster.requestPermissionOnce()
            }
        }
    }

    private func revealInFinder() {
        guard let clip = model.selectedClip, clip.kind == .file else { return }
        let urls = clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        hide()
        if urls.isEmpty {
            hud.show(clip.fileURLs.count == 1 ? "文件已经不在了" : "这些文件都已经不在了")
        } else if isQuiet {
            print("panel: 不打开 Finder（调试脚本）：\(urls.map(\.path))")
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func openLink() {
        guard let clip = model.selectedClip, clip.isLink,
              let url = URL(string: clip.title.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        hide()
        if isQuiet {
            print("panel: 不打开浏览器（调试脚本）：\(url)")
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 图片条目看存下的图，文件条目看第一个还在的文件。
    private func quickLookURL(_ clip: Clip?) -> URL? {
        switch clip?.kind {
        case .image: clip?.imageURL
        case .file: clip?.fileURLs.first { FileManager.default.fileExists(atPath: $0.path) }
        default: nil
        }
    }

    private func imageSize(_ clip: Clip?) -> CGSize? {
        guard let clip, clip.kind == .image, let width = clip.imageWidth, let height = clip.imageHeight else { return nil }
        return CGSize(width: width, height: height)
    }

    private func toggleQuickLook() {
        if quickLook.isVisible {
            quickLook.close()
        } else if let url = quickLookURL(model.selectedClip) {
            quickLook.show(url, imageSize: imageSize(model.selectedClip), over: panel)
            if isQuiet { print("panel: quick look \(url.lastPathComponent) visible=\(quickLook.isVisible) window=\(quickLook.windowNumber)") }
        }
    }

    /// Quick Look 开着时上下键换一条，它跟着换；换到文本就关掉。
    private func followSelection(_ clip: Clip?) {
        guard quickLook.isVisible else { return }
        if let url = quickLookURL(clip) {
            quickLook.show(url, imageSize: imageSize(clip), over: panel)
        } else {
            quickLook.close()
        }
    }
}

/// 浅色外观下在毛玻璃上盖一层白。背后是深色的窗口时毛玻璃发灰，黑字的对比不够。深色外观不盖。
final class LightTintView: NSView {
    var alpha: CGFloat = 0.7 {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isLight = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        layer?.backgroundColor = isLight ? NSColor.white.withAlphaComponent(alpha).cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension PanelCommand {
    /// 面板里的快捷键，尽量和 Raycast 的剪切板历史一样。
    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let command: PanelCommand?
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            command = modifiers == [] ? .down : modifiers == .command ? .sectionDown : nil
        case kVK_UpArrow:
            command = modifiers == [] ? .up : modifiers == .command ? .sectionUp : nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            command = modifiers == [] ? .paste : modifiers == .command ? .copy : modifiers == .shift ? .pastePlain : nil
        case kVK_Escape:
            command = modifiers == [] ? .escape : nil
        case kVK_ANSI_P:
            command = modifiers == .command ? .typeMenu : nil
        case kVK_ANSI_Period:
            command = modifiers == .command ? .pin : nil
        case kVK_ANSI_X:
            command = modifiers == .control ? .delete : modifiers == [.control, .shift] ? .clearAll : nil
        case kVK_ANSI_Y:
            command = modifiers == .command ? .quickLook : nil
        case kVK_ANSI_F:
            command = modifiers == [.command, .shift] ? .revealInFinder : nil
        case kVK_ANSI_O:
            command = modifiers == .command ? .openLink : nil
        case kVK_ANSI_Comma:
            command = modifiers == .command ? .settings : nil
        default:
            command = nil
        }
        guard let command else { return nil }
        self = command
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}

extension NSImage {
    /// NSVisualEffectView 的圆角遮罩：九宫格拉伸，四个角是圆的。
    static func roundedRectMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
