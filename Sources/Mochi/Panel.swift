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

    /// 搜索框空着时，按在它上面拖的是整个面板：它占了搜索栏的大半，空着时点它也没有用处（Tinycast 也这么做）。
    /// 有字、正在用输入法组字时照常点、选字。搜索栏别的空白处由 WindowDragArea 拖。
    /// 右键按下，参数是面板里的位置（左上角原点）。处理了返回真。SwiftUI 的行上没有右键手势，只能在这里截。
    var onRightClick: ((CGPoint) -> Bool)?
    /// 空着的搜索框能拖面板。跑调试脚本时关掉：脚本在应用里造的点击不能变成拖窗口，拖动跟的是真鼠标。
    var dragsFromEmptyField = true

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let height = contentView?.bounds.height,
           onRightClick?(CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)) == true {
            return
        }
        if event.type == .leftMouseDown, dragsFromEmptyField, let field = textField(at: event.locationInWindow), field.stringValue.isEmpty,
           !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    private func textField(at point: NSPoint) -> NSTextField? {
        var view = contentView?.hitTest(point)
        while let current = view {
            if let field = current as? NSTextField { return field }
            view = current.superview
        }
        return nil
    }

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
    private let store: ClipStore
    private let panel = ClipPanel()
    private let settings: Settings
    private let paster: Paster
    private let hud: HUD
    private let quickLook = QuickLook()
    private var wantsVisible = false
    /// 呼出时的前台应用。⌥↵ 粘贴且不关闭面板时 ⌘V 直接发给它的进程。
    private var frontApp: NSRunningApplication?
    /// 呼出时自己摆的位置。windowDidMove 里和它一样就不是用户拖的。
    private var placedOrigin: NSPoint?
    private var keyMonitor: Any?
    private var hintMonitor: Any?
    private var hintTimer: Task<Void, Never>?
    var openSettings: (() -> Void)?
    /// 在面板里暂停、恢复了记录，菜单栏图标跟着变。
    var pauseChanged: (() -> Void)?

    /// 调试脚本在跑（`Drive`）：面板压在桌面壁纸下面，用户看不见；不抢键盘、不接鼠标，失焦也不收起；
    /// 不发 ⌘V，不打开 Finder、浏览器。
    var isQuiet = false {
        didSet {
            panel.level = isQuiet ? NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 1) : .floating
            panel.ignoresMouseEvents = isQuiet
            panel.dragsFromEmptyField = !isQuiet
            quickLook.level = panel.level
            paster.isQuiet = isQuiet
            hud.isQuiet = isQuiet
        }
    }

    init(store: ClipStore, settings: Settings, paster: Paster, hud: HUD) {
        model = PanelModel(store: store)
        self.store = store
        self.settings = settings
        self.paster = paster
        self.hud = hud
        super.init()
        panel.delegate = self
        panel.contentView = makeContentView()
        model.perform = { [weak self] command in self?.perform(command) }
        panel.onRightClick = { [weak self] point in self?.rightClick(at: point) ?? false }
        model.selectionChanged = { [weak self] clip in self?.followSelection(clip) }
        hintMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .scrollWheel]) { [weak self] event in
            if let self, event.window === self.panel { self.updateNumberHints(event) }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    var windowNumber: Int { panel.windowNumber }
    var frame: NSRect { panel.frame }
    #if DEBUG
    /// 调试脚本模拟用户拖面板：和拖动一样会走 windowDidMove。
    func moveBy(dx: CGFloat, dy: CGFloat) {
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
    }
    #endif
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
        let started = ContinuousClock.now
        let frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        self.frontApp = frontApp
        Task {
            // 先把第一页读好再显示，免得先露出上次的列表再跳。
            await model.prepare(isPaused: settings.isPaused, frontAppName: frontApp?.localizedName, frontAppIcon: frontApp?.icon,
                                canPaste: paster.canPaste, enterAction: settings.enterAction, prefersPlainText: settings.prefersPlainText)
            guard wantsVisible else { return }
            let origin = origin()
            placedOrigin = origin
            panel.setFrameOrigin(origin)
            if isQuiet {
                panel.orderFrontRegardless()
            } else {
                panel.makeKeyAndOrderFront(nil)
                focusSearchField()
            }
            panel.invalidateShadow()
            afterThisFrame { [weak self] in
                let elapsed = ContinuousClock.now - started
                log.debug("panel shown in \(elapsed.milliseconds, format: .fixed(precision: 1)) ms")
                self?.didShow?(elapsed)
            }
        }
    }

    /// 面板这一帧交给系统以后调，参数是从 `show()` 开始用了多久。
    var didShow: ((Duration) -> Void)?

    /// 这一轮 run loop 里 AppKit 排版、SwiftUI 更新、Core Animation 提交都做完以后调一次。
    /// 它们都挂在 beforeWaiting 上，这个观察者排在最后。之后窗口服务器还要等下一次刷新才合成到屏幕上。
    private func afterThisFrame(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated(body)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func hide() {
        wantsVisible = false
        hintTimer?.cancel()
        model.showsNumberHints = false
        model.isTypeMenuOpen = false
        model.cancelClear()
        quickLook.close(animated: false)
        panel.orderOut(nil)
    }

    /// 点了面板外面（别的应用、桌面），面板就不是 key 了。
    func windowDidResignKey(_ notification: Notification) {
        if !isQuiet { hide() }
    }

    /// 鼠标所在屏幕。在这块屏幕上拖过就放回拖到的位置（屏幕变小了就挪进来），没拖过就水平居中、竖直方向偏上。
    private func origin() -> NSPoint {
        let size = PanelMetrics.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        guard let display = screen.displayUUID, let offset = settings.panelOffset(onDisplay: display) else {
            return NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.minY + (frame.height - size.height) * 0.62).rounded())
        }
        let x = min(max(frame.minX + offset.x, frame.minX), frame.maxX - size.width)
        let y = min(max(frame.maxY - offset.y - size.height, frame.minY), frame.maxY - size.height)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// 用户拖了面板（搜索栏的空白处），记下它现在所在屏幕上的位置。
    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, panel.frame.origin != placedOrigin,
              let screen = panel.screen, let display = screen.displayUUID else { return }
        let frame = screen.visibleFrame
        settings.setPanelOffset(CGPoint(x: panel.frame.minX - frame.minX, y: frame.maxY - panel.frame.maxY), onDisplay: display)
        placedOrigin = nil
    }

    /// 菜单栏的「窗口位置复原」。
    func resetPosition() {
        settings.resetPanelOffsets()
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
        // 编辑框、改名框开着时只认它们的几个键，别的（打字、↵ 换行、方向键）给输入区。
        if model.editing != nil || model.renaming != nil {
            guard let command, [.escape, .paste, .copy, .pasteKeepOpen].contains(command) else { return false }
            if model.editing != nil, command == .paste { return false }
            perform(command)
            return true
        }
        if model.clearConfirmation != nil {
            // 确认框开着时只认回车（清空）和 Esc（取消），别的键都吞掉。
            if command == .paste {
                Task { await model.confirmClear() }
            } else if command == .escape {
                model.cancelClear()
            }
            return true
        }
        if model.actionMenu != nil {
            switch command {
            case .down: model.actionMenu?.move(1)
            case .up: model.actionMenu?.move(-1)
            case .paste:
                if let action = model.actionMenu?.highlightedAction { perform(action.command) }
            case .escape:
                if model.actionMenu?.back() == false { closeActionMenu() }
            case .sectionUp, .sectionDown, .typeMenu:
                break
            case .number(let n):
                if let action = model.actionMenu?.visible.dropFirst(n - 1).first { perform(action.command) }
            case nil:
                // Tab 吞掉；打字、删字、⌘A 给操作面板的搜索框。
                return Int(event.keyCode) == kVK_Tab
            case let command?:
                // 面板开着时各操作的快捷键照样能用。
                perform(model.enterKeys.resolve(command))
            }
            return true
        }
        if quickLook.isVisible, command == .escape {
            quickLook.close(to: quickLookSource())
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
        perform(model.enterKeys.resolve(command))
        return true
    }

    func perform(_ command: PanelCommand) {
        if model.editing != nil {
            // ⌘↵ 保存，⌥↵ 保存并复制，Esc 不保存。
            switch command {
            case .escape: finishEditing { $0.editing = nil }
            case .copy: finishEditing { await $0.saveEdit() }
            case .pasteKeepOpen: finishEditing { await $0.saveEdit() } then: { self.paste(.copy) }
            default: break
            }
            return
        }
        if model.renaming != nil {
            switch command {
            case .escape: finishEditing { $0.renaming = nil }
            case .paste: finishEditing { await $0.saveRename() }
            default: break
            }
            return
        }
        // 文件的 ⌘O 是进「用其他应用打开」子菜单。
        if command == .open, model.selectedClip?.kind == .file {
            perform(.submenu(.openWith))
            return
        }
        // 操作面板里选了一项，或者面板开着时按了某个操作的快捷键：先关面板再做。子菜单是换一层，不关。
        switch command {
        case .actions, .submenu, .appMenu: break
        default: closeActionMenu()
        }
        switch command {
        case .down: model.move(1)
        case .up: model.move(-1)
        case .sectionDown: model.jumpSection(1)
        case .sectionUp: model.jumpSection(-1)
        case .typeMenu: model.toggleTypeMenu()
        case .escape:
            if model.query.isEmpty { hide() } else { model.setQuery("") }
        case .paste: paste(.paste)
        case .pastePlain: paste(.paste, plainText: true)
        case .copy: paste(.copy)
        case .pasteKeepOpen: paste(.keepOpen, plainText: model.enterKeys.enter == .pastePlain)
        case .copyKeepOpen: paste(.copyKeepOpen)
        case .pasteFormat(let type): paste(.paste, format: type)
        case .actions:
            if model.actionMenu == nil { openActionMenu() } else { closeActionMenu() }
        case .submenu(let submenu):
            if model.actionMenu == nil {
                openActionMenu(submenu: submenu)
            } else {
                Task { await model.pushSubmenu(submenu) }
            }
        case .openWith(let app): open(with: app)
        case .deleteRecent(let minutes):
            Task {
                let count = await model.deleteRecent(minutes: minutes)
                let span = minutes < 60 ? "\(minutes) 分钟" : minutes < 1440 ? "\(minutes / 60) 小时" : "\(minutes / 1440) 天"
                hud.show(count == 0 ? "最近 \(span)没有要删的，置顶的不删" : "删掉了最近 \(span)的 \(count) 条")
            }
        case .drag(let id): startDrag(id)
        case .edit: Task { await model.startEdit() }
        case .rename: model.startRename()
        case .number(let n):
            guard model.clips.indices.contains(n - 1) else { return }
            model.select(model.clips[n - 1].id)
            perform(model.enterKeys.enter)
        case .movePinnedUp: Task { await model.movePinned(up: true) }
        case .movePinnedDown: Task { await model.movePinned(up: false) }
        case .pin: Task { await model.togglePin() }
        case .delete: Task { await model.deleteSelected() }
        case .clearAll:
            Task {
                if await !model.askToClear() { hud.show("没有可以清空的，置顶的不删") }
            }
        case .quickLook: toggleQuickLook()
        case .revealInFinder: revealInFinder()
        case .open: openLink()
        case .openAccessibilitySettings:
            hide()
            paster.openAccessibilitySettings()
        case .settings:
            hide()
            openSettings?()
        case .appMenu:
            if model.actionMenu?.placement == .app {
                closeActionMenu()
            } else {
                model.openAppMenu()
            }
        case .togglePause:
            settings.isPaused.toggle()
            model.setPaused(settings.isPaused)
            pauseChanged?()
            hud.show(settings.isPaused ? "已暂停记录" : "已恢复记录")
        case .resetPosition:
            resetPosition()
            let origin = origin()
            placedOrigin = origin
            panel.setFrameOrigin(origin)
        case .quit:
            if isQuiet {
                print("panel: 不退出（调试脚本）")
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    /// 只按住 ⌘ 0.4 秒，列表前 10 行显示 ⌘1…⌘0（照 Raycast）；松开、按了别的键、滚动时收起。
    private func updateNumberHints(_ event: NSEvent) {
        hintTimer?.cancel()
        let onlyCommand = event.type == .flagsChanged
            && event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command
        guard onlyCommand else {
            if model.showsNumberHints { model.showsNumberHints = false }
            return
        }
        hintTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.model.actionMenu == nil else { return }
            self.model.showsNumberHints = true
        }
    }

    // MARK: - 拖出去

    /// 拖出去的时候不是 nil。拖动手势在拖动期间还会报变化，开一次就够。
    private var dragging: TextProvider?

    /// 开始把一行拖到别的应用：图片、文件拖出去是文件，文本是文字（长文本放下时才去读全文）。放下以后面板收起。
    private func startDrag(_ id: Int64) {
        guard dragging == nil, let clip = model.clips.first(where: { $0.id == id }),
              let event = NSApp.currentEvent, event.type == .leftMouseDragged, let view = panel.contentView else { return }
        let writers: [NSPasteboardWriting]
        let provider = TextProvider(store: store, clip: clip)
        switch clip.kind {
        case .text:
            let item = NSPasteboardItem()
            if clip.characterCount == clip.title.count {
                item.setString(clip.title, forType: .string)
            } else {
                item.setDataProvider(provider, forTypes: [.string])
            }
            writers = [item]
        case .image:
            writers = clip.imageURL.map { [$0 as NSURL] } ?? []
        case .file:
            writers = clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0 as NSURL }
        }
        guard !writers.isEmpty else { return }
        let icon = dragIcon(for: clip)
        let location = view.convert(event.locationInWindow, from: nil)
        let items = writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(NSRect(x: location.x - 16 + offset, y: location.y - 16 - offset, width: 32, height: 32), contents: icon)
            return item
        }
        dragging = provider
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    #if DEBUG
    /// 调试脚本：走一遍长文本拖出去放下时取全文的路（不真的拖，拖动跟的是真鼠标）。
    func provideDraggedText(_ id: Int64) -> String? {
        guard let clip = model.clips.first(where: { $0.id == id }) else { return nil }
        let item = NSPasteboardItem()
        TextProvider(store: store, clip: clip).pasteboard(nil, item: item, provideDataForType: .string)
        return item.string(forType: .string)
    }
    #endif

    private func dragIcon(for clip: Clip) -> NSImage {
        switch clip.kind {
        case .image:
            if let url = clip.thumbnailURL, let image = NSImage(contentsOf: url) { return image }
        case .file:
            if let url = clip.fileURLs.first { return NSWorkspace.shared.icon(forFile: url.path) }
        case .text:
            break
        }
        let symbol = NSImage(systemSymbolName: clip.textSymbol, accessibilityDescription: nil)
        return symbol?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) ?? NSImage()
    }

    // MARK: - 操作面板

    private func openActionMenu(submenu: ActionSubmenu? = nil) {
        guard model.selectedClip != nil else { return }
        model.isTypeMenuOpen = false
        Task { await model.openActionMenu(submenu: submenu) }
    }

    /// 右键一行：选中它，打开操作面板。操作面板开着时右键哪里都是关掉它（和左键点别处一样）。
    private func rightClick(at point: CGPoint) -> Bool {
        if model.actionMenu != nil {
            closeActionMenu()
            return true
        }
        guard model.clearConfirmation == nil, let id = model.clipID(at: point) else { return false }
        model.select(id)
        openActionMenu()
        return true
    }

    /// 编辑框、改名框做完（保存或者取消）：键盘焦点回到主搜索框，再做 `then`。
    private func finishEditing(_ change: @escaping (PanelModel) async -> Void, then: (() -> Void)? = nil) {
        Task {
            await change(model)
            focusSearchField()
            then?()
        }
    }

    /// 关掉操作面板，键盘焦点回到主搜索框。
    private func closeActionMenu() {
        guard model.actionMenu != nil else { return }
        model.actionMenu = nil
        focusSearchField()
    }

    // MARK: - 操作

    private enum PasteMode {
        /// 收起面板，替用户按 ⌘V。
        case paste
        /// 收起面板，只写剪切板。
        case copy
        /// ⌥↵：面板不收，⌘V 直接发给前台应用的进程。
        case keepOpen
        /// 回车默认复制时的 ⌥↵：面板不收，只写剪切板。
        case copyKeepOpen
    }

    /// 回车粘贴、⌃⌘↵ 粘贴纯文本、⌘↵ 只复制、⌥↵ 粘贴且不关闭面板、选格式粘贴。
    /// 先收起面板，键盘焦点回到前台应用，写好剪切板再替用户按 ⌘V。
    /// 没有辅助功能权限时只复制，提示一句，再弹一次系统的授权提示。
    private func paste(_ mode: PasteMode, plainText: Bool = false, format: String? = nil) {
        guard let clip = model.selectedClip else { return }
        if mode == .paste || mode == .copy { hide() }
        Task {
            var note: String?
            switch await paster.write(clip, plainText: plainText, format: format) {
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
            if mode == .copy || mode == .copyKeepOpen {
                hud.show(note.map { "已复制，\($0)" } ?? "已复制到剪切板")
            } else if paster.canPaste {
                await paster.sendPasteKeystroke(to: mode == .keepOpen ? frontApp?.processIdentifier : nil)
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

    /// 「用其他应用打开」子菜单里选了一个应用。
    private func open(with app: URL) {
        guard let clip = model.selectedClip, clip.kind == .file else { return }
        let urls = clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        hide()
        if urls.isEmpty {
            hud.show(clip.fileURLs.count == 1 ? "文件已经不在了" : "这些文件都已经不在了")
        } else if isQuiet {
            print("panel: 不打开（调试脚本）：\(urls.map(\.lastPathComponent)) 用 \(app.lastPathComponent)")
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// 标题只有前 300 个字，长网址要读全文。
    private func openLink() {
        guard let clip = model.selectedClip, clip.isLink else { return }
        Task {
            let text = (try? await store.text(of: clip.id)) ?? clip.title
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            hide()
            if isQuiet {
                print("panel: 不打开浏览器（调试脚本）：\(url)")
            } else {
                NSWorkspace.shared.open(url)
            }
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

    /// 图片条目用存下的尺寸；只有一个文件、而且面板里显示的是这张图时读文件的尺寸。
    private func imageSize(_ clip: Clip?) -> CGSize? {
        guard let clip else { return nil }
        switch clip.kind {
        case .image:
            guard let width = clip.imageWidth, let height = clip.imageHeight else { return nil }
            return CGSize(width: width, height: height)
        case .file:
            guard clip.fileURLs.count == 1, let url = clip.fileURLs.first, previewImage(of: clip) != nil else { return nil }
            return Images.pixelSize(url)
        case .text:
            return nil
        }
    }

    private func previewImage(of clip: Clip) -> CGImage? {
        guard let preview = model.preview, preview.clipID == clip.id, case .image(let image) = preview.content else { return nil }
        return image
    }

    /// 面板里这一条的预览图在屏幕上的位置，Quick Look 从这里放大、缩回这里。预览还没换到这一条时没有。
    private func quickLookSource() -> QuickLook.Source? {
        guard let clip = model.selectedClip, let image = previewImage(of: clip),
              let view = panel.contentView?.firstSubview(of: ImageLayerView.self), let window = view.window else { return nil }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard frame.width > 1, frame.height > 1 else { return nil }
        return QuickLook.Source(frame: frame, image: image, cornerRadius: view.layer?.cornerRadius ?? 0)
    }

    private func toggleQuickLook() {
        if quickLook.isVisible {
            quickLook.close(to: quickLookSource())
        } else if let url = quickLookURL(model.selectedClip) {
            quickLook.show(url, imageSize: imageSize(model.selectedClip), over: panel, from: quickLookSource())
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
    var alpha: CGFloat = 0.64 {
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
            command = modifiers == [] ? .down : modifiers == .command ? .sectionDown : modifiers == [.option, .command] ? .movePinnedDown : nil
        case kVK_UpArrow:
            command = modifiers == [] ? .up : modifiers == .command ? .sectionUp : modifiers == [.option, .command] ? .movePinnedUp : nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            switch modifiers {
            case []: command = .paste
            case .command: command = .copy
            case .option: command = .pasteKeepOpen
            case [.option, .command]: command = .submenu(.pasteAs)
            // ⇧↵ 是 Mochi 原来的键，⌃⌘↵ 是 Raycast 的，都认。
            case [.control, .command], .shift: command = .pastePlain
            default: command = nil
            }
        case kVK_Escape:
            command = modifiers == [] ? .escape : nil
        case kVK_ANSI_P:
            command = modifiers == .command ? .typeMenu : nil
        case kVK_ANSI_Period:
            command = modifiers == .command ? .pin : nil
        case kVK_ANSI_X:
            switch modifiers {
            case .control: command = .delete
            case [.control, .shift]: command = .clearAll
            case [.command, .shift]: command = .submenu(.deleteRecent)
            default: command = nil
            }
        case kVK_ANSI_K:
            command = modifiers == .command ? .actions : nil
        case kVK_ANSI_E:
            command = modifiers == .command ? .edit : modifiers == [.command, .shift] ? .rename : nil
        case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]
            command = modifiers == .command ? digits.firstIndex(of: Int(event.keyCode)).map { .number($0 + 1) } : nil
        case kVK_ANSI_Y:
            command = modifiers == .command ? .quickLook : nil
        case kVK_ANSI_F:
            // Mochi 原来的键；Raycast 是 ⇧⌘O。
            command = modifiers == [.command, .shift] ? .revealInFinder : nil
        case kVK_ANSI_O:
            command = modifiers == .command ? .open : modifiers == [.command, .shift] ? .revealInFinder : nil
        case kVK_ANSI_Comma:
            command = modifiers == .command ? .settings : nil
        case kVK_ANSI_Q:
            command = modifiers == .command ? .quit : nil
        default:
            command = nil
        }
        guard let command else { return nil }
        self = command
    }
}

extension PanelController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = nil
        if operation != [] { hide() }
    }
}

/// 长文本拖出去时，放下那一刻对方要文字了才读全文。读库在 ClipStore 自己的线程上，主线程在这里等它（只等这一次）；
/// 不能经过主线程上的东西（PanelModel），不然互相等。
private final class TextProvider: NSObject, NSPasteboardItemDataProvider {
    private let store: ClipStore
    private let clip: Clip

    init(store: ClipStore, clip: Clip) {
        self.store = store
        self.clip = clip
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let done = DispatchSemaphore(value: 0)
        let box = TextBox()
        let (store, id) = (store, clip.id)
        Task.detached {
            box.text = try? await store.text(of: id)
            done.signal()
        }
        done.wait()
        item.setString(box.text ?? clip.title, forType: type)
    }
}

private final class TextBox: @unchecked Sendable {
    var text: String?
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}

private extension NSScreen {
    /// 显示器的 UUID，换接口、重新插拔都不变（NSScreenNumber 会变）。
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
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
