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

/// 管面板的显示、收起和键盘。面板只建一次，收起时藏起来不销毁（requirements.md「呼出要快」）。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: PanelModel
    private let panel = ClipPanel()
    private let settings: Settings
    private var wantsVisible = false
    private var keyMonitor: Any?

    /// 调试脚本在跑（`Drive`）：面板压在桌面壁纸下面，用户看不见；不抢键盘、不接鼠标，失焦也不收起。
    var isQuiet = false {
        didSet {
            panel.level = isQuiet ? NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 1) : .floating
            panel.ignoresMouseEvents = isQuiet
        }
    }

    init(store: ClipStore, settings: Settings) {
        model = PanelModel(store: store)
        self.settings = settings
        super.init()
        panel.delegate = self
        panel.contentView = makeContentView()
        model.perform = { [weak self] command in self?.perform(command) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    var windowNumber: Int { panel.windowNumber }
    var contentView: NSView? { panel.contentView }

    private func makeContentView() -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: PanelMetrics.size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedRectMask(radius: PanelMetrics.cornerRadius)
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
            await model.prepare(isPaused: settings.isPaused, frontAppName: frontApp?.localizedName)
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
        case .paste, .copy, .pastePlain, .pin, .delete, .clearAll, .quickLook, .revealInFinder, .openLink:
            break  // 阶段 3
        }
    }
}

extension PanelCommand {
    /// 快捷键表见 requirements.md「操作」。
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

private extension NSImage {
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
