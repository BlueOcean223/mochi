import AppKit
import MochiCore
import Observation
import UniformTypeIdentifiers

/// 列表里的组。顺序就是显示的顺序。
enum ClipSection: Int, CaseIterable {
    case pinned, today, yesterday, thisWeek, earlier

    var title: String {
        switch self {
        case .pinned: "置顶"
        case .today: "今天"
        case .yesterday: "昨天"
        case .thisWeek: "本周"
        case .earlier: "更早"
        }
    }

    init(_ clip: Clip, now: Date, calendar: Calendar) {
        let date = clip.lastCopiedAt
        if clip.isPinned {
            self = .pinned
        } else if calendar.isDate(date, inSameDayAs: now) {
            self = .today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            self = .yesterday
        } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            self = .thisWeek
        } else {
            self = .earlier
        }
    }
}

struct ClipGroup: Identifiable {
    let section: ClipSection
    var clips: [Clip]
    var id: ClipSection { section }
}

/// 选中一条时现取的预览内容。
struct Preview {
    enum Content {
        case text(String)
        case image(CGImage)
        case files
        /// 图片文件被删了。
        case missing
    }

    let clipID: Int64
    let content: Content
}

/// 面板里的键盘命令、底栏按钮和 ⌘K 操作面板里的操作。
enum PanelCommand: Equatable {
    case up, down, sectionUp, sectionDown, typeMenu, escape
    case paste, copy, pastePlain, pin, delete, clearAll, quickLook, revealInFinder
    /// ⌥↵：粘贴到前台应用，面板不关。
    case pasteKeepOpen
    /// 回车默认复制时的 ⌥↵：复制，面板不关。
    case copyKeepOpen
    /// ⌘O：链接用浏览器打开，文件打开「用其他应用打开」子菜单。
    case open
    /// ⌥⌘↑、⌥⌘↓：在置顶的里面挪一位。
    case movePinnedUp, movePinnedDown
    /// ⌘K：操作面板开关。
    case actions
    /// ⌘E：改文本条目的内容。
    case edit
    /// ⇧⌘E：给条目起名字。
    case rename
    /// 按住一行拖出去（拖到别的应用）。
    case drag(Int64)
    /// ⌘1…⌘9、⌘0：对列表第 1–10 条做回车做的事；操作面板开着时执行面板里第 N 项。
    case number(Int)
    /// 打开操作面板里的子菜单（⌥⌘↵ 选格式粘贴、⇧⌘X 删除最近的）。
    case submenu(ActionSubmenu)
    /// 子菜单里的一项：只写这一种格式再粘贴。
    case pasteFormat(String)
    /// 子菜单里的一项：用这个应用打开文件。
    case openWith(URL)
    /// 子菜单里的一项：删掉最近这么多分钟里复制的。
    case deleteRecent(minutes: Int)
    /// 底栏「去授权」：打开系统设置的辅助功能页。
    case openAccessibilitySettings
    /// ⌘,：收起面板，打开设置窗口。
    case settings
    /// 底栏左边的「设置」：Mochi 自己的菜单（设置、暂停记录、窗口位置复原、退出）。菜单栏图标被隐藏、被挤掉时也能退出。
    case appMenu
    case togglePause
    /// 面板回到默认位置，清掉记下的位置。
    case resetPosition
    /// ⌘Q：退出 Mochi。
    case quit
}

/// 回车这几个组合各做什么，跟着设置变（照 Raycast）：回车默认复制时 ↵ 和 ⌘↵ 对调、⌥↵ 变成复制且不关闭面板；
/// 优先粘贴纯文本时粘贴写纯文本、⌃⌘↵ 变成带格式粘贴（只对文本条目，图片、文件照常）。
struct EnterKeys {
    let enter: PanelCommand
    let commandEnter: PanelCommand
    let optionEnter: PanelCommand
    let controlCommandEnter: PanelCommand

    init(action: EnterAction, plainFirst: Bool) {
        let paste: PanelCommand = plainFirst ? .pastePlain : .paste
        enter = action == .copy ? .copy : paste
        commandEnter = action == .copy ? paste : .copy
        optionEnter = action == .copy ? .copyKeepOpen : .pasteKeepOpen
        controlCommandEnter = plainFirst ? .paste : .pastePlain
    }

    /// 按键表（PanelCommand(event)）按默认设置写的：↵ 是 .paste、⌘↵ 是 .copy、⌥↵ 是 .pasteKeepOpen、⌃⌘↵ 是 .pastePlain。
    func resolve(_ command: PanelCommand) -> PanelCommand {
        switch command {
        case .paste: enter
        case .copy: commandEnter
        case .pasteKeepOpen: optionEnter
        case .pastePlain: controlCommandEnter
        default: command
        }
    }
}

/// 改名时的小框：这条和输入框里的字。
struct RenameRequest {
    let clip: Clip
    var title: String
}

/// 编辑文本时整个面板换成编辑框。
struct TextEdit {
    let clip: Clip
    var text: String
    /// 原来存了 RTF、HTML，保存后会去掉。
    let dropsFormats: Bool
}

/// 清空前的确认。
struct ClearRequest {
    let count: Int
    /// 有类型筛选时只清这一类。
    let filter: ClipFilter?
}

/// 面板的状态：搜索词、类型筛选、当前这一页、选中哪条、预览。界面只读它，改都走这里的方法。
@MainActor
@Observable
final class PanelModel {
    struct FilterOption {
        let filter: ClipFilter?
        let label: String
    }

    /// 顺序照 Raycast。
    static let filterOptions = [
        FilterOption(filter: nil, label: "全部类型"),
        FilterOption(filter: .text, label: "文本"),
        FilterOption(filter: .image, label: "图片"),
        FilterOption(filter: .file, label: "文件"),
        FilterOption(filter: .link, label: "链接"),
        FilterOption(filter: .email, label: "邮箱"),
        FilterOption(filter: .color, label: "颜色"),
    ]

    /// 一次读多少条；往下翻到离末尾 20 条时读下一页。
    static let pageSize = 100
    /// 文本预览最多显示这么多个字符，再长的 NSTextView 排版会卡。
    static let previewLength = 100_000
    /// 预览图解到长边这么多像素：预览区最宽约 450 点，二倍屏 900 像素就够，再大也是缩小了显示。
    static let previewPixels = 900

    private(set) var query = ""
    private(set) var filter: ClipFilter?
    private(set) var clips: [Clip] = []
    private(set) var groups: [ClipGroup] = []
    private(set) var selectedID: Int64?
    private(set) var preview: Preview?
    private(set) var wordCount: (clipID: Int64, count: Int)?
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }
    /// 呼出面板时的前台应用，回车粘贴到它那里。
    private(set) var frontAppName: String?
    /// 有辅助功能权限，回车能替用户按 ⌘V；没有时回车只复制。
    private(set) var canPaste = true
    /// 呼出面板时前台应用的图标，操作面板里粘贴那几行用。
    private(set) var frontAppIcon: NSImage?
    /// 设置里回车做什么、是否优先粘贴纯文本，呼出时读一次。
    private(set) var enterAction = EnterAction.paste
    private(set) var prefersPlainText = false
    /// 回车这几个组合各做什么，跟着设置变（照 Raycast）：回车默认复制时 ↵ 和 ⌘↵ 对调、⌥↵ 变成复制且不关闭面板；
/// 优先粘贴纯文本时粘贴写纯文本、⌃⌘↵ 变成带格式粘贴（只对文本条目，图片、文件照常）。
struct EnterKeys {
    let enter: PanelCommand
    let commandEnter: PanelCommand
    let optionEnter: PanelCommand
    let controlCommandEnter: PanelCommand

    init(action: EnterAction, plainFirst: Bool) {
        let paste: PanelCommand = plainFirst ? .pastePlain : .paste
        enter = action == .copy ? .copy : paste
        commandEnter = action == .copy ? paste : .copy
        optionEnter = action == .copy ? .copyKeepOpen : .pasteKeepOpen
        controlCommandEnter = plainFirst ? .paste : .pastePlain
    }

    /// 按键表（PanelCommand(event)）按默认设置写的：↵ 是 .paste、⌘↵ 是 .copy、⌥↵ 是 .pasteKeepOpen、⌃⌘↵ 是 .pastePlain。
    func resolve(_ command: PanelCommand) -> PanelCommand {
        switch command {
        case .paste: enter
        case .copy: commandEnter
        case .pasteKeepOpen: optionEnter
        case .pastePlain: controlCommandEnter
        default: command
        }
    }
}

/// 清空前的确认。
    private(set) var clearConfirmation: ClearRequest?
    /// ⌘K 操作面板，开着时不是 nil。
    var actionMenu: ActionMenu?
    var renaming: RenameRequest?
    var editing: TextEdit?
    var isTypeMenuOpen = false
    var typeMenuIndex = 0
    /// 每次加一，列表就滚回顶上（呼出、换搜索词时）。
    private(set) var scrollToTop = 0
    /// 每次加一，列表就滚到选中的那条（置顶以后它挪到了最上面）。
    private(set) var scrollToSelection = 0

    /// 按住 ⌘ 一会儿，列表前 10 行右边显示 ⌘1…⌘0。
    var showsNumberHints = false

    /// 列表里现在建出来的行在面板里的位置（左上角原点），右键时按位置找是哪一行。
    @ObservationIgnored var rowFrames: [Int64: CGRect] = [:]

    /// 面板里这一点（左上角原点）上是哪一行。只认列表那一栏里露出来的部分：滚出去的行位置还在，但不在这一栏里。
    func clipID(at point: CGPoint) -> Int64? {
        guard point.x < PanelMetrics.listWidth, point.y > PanelMetrics.headerHeight else { return nil }
        return rowFrames.first { $0.value.contains(point) }?.key
    }

    /// 底栏按钮、双击走这里，由 PanelController 接。
    @ObservationIgnored var perform: ((PanelCommand) -> Void)?
    /// 选中的换了（Quick Look 开着时跟着换）。
    @ObservationIgnored var selectionChanged: ((Clip?) -> Void)?

    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(store: ClipStore) {
        self.store = store
    }

    var selectedClip: Clip? {
        clips.first { $0.id == selectedID }
    }

    var filterLabel: String {
        Self.filterOptions.first { $0.filter == filter }?.label ?? "全部类型"
    }

    /// 选中这条时回车这几个组合做什么。优先纯文本只管文本条目。
    var enterKeys: EnterKeys {
        EnterKeys(action: enterAction, plainFirst: prefersPlainText && selectedClip?.kind == .text)
    }

    var isFiltered: Bool {
        !query.isEmpty || filter != nil
    }

    /// 预览还没取到时先接着显示上一条的，同类型才行，免得每按一下方向键闪一下空白。
    func preview(for clip: Clip) -> Preview? {
        guard let preview, preview.clipID == clip.id || selectedKindMatches(preview) else { return nil }
        return preview
    }

    func wordCount(for clip: Clip) -> Int? {
        wordCount?.clipID == clip.id ? wordCount?.count : nil
    }

    private func selectedKindMatches(_ preview: Preview) -> Bool {
        guard let old = clips.first(where: { $0.id == preview.clipID }) else { return false }
        return old.kind == selectedClip?.kind
    }

    // MARK: - 打开、搜索、筛选

    /// 每次呼出前调：清空搜索词和类型，读第一页，选中第一条。
    func prepare(isPaused: Bool, frontAppName: String?, frontAppIcon: NSImage?, canPaste: Bool,
                 enterAction: EnterAction, prefersPlainText: Bool) async {
        self.enterAction = enterAction
        self.prefersPlainText = prefersPlainText
        self.isPaused = isPaused
        self.frontAppName = frontAppName
        self.frontAppIcon = frontAppIcon
        self.canPaste = canPaste
        isTypeMenuOpen = false
        actionMenu = nil
        renaming = nil
        editing = nil
        clearConfirmation = nil
        query = ""
        filter = nil
        await reload()
        scrollToTop += 1
    }

    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        Task { await reload(); scrollToTop += 1 }
    }

    func setFilter(_ filter: ClipFilter?) {
        guard filter != self.filter else { return }
        self.filter = filter
        Task { await reload(); scrollToTop += 1 }
    }

    /// 重读第一页。`keepSelection` 为真时（置顶、删除以后）尽量留在原来那条上。
    func reload(keepSelection: Bool = false) async {
        generation += 1
        let generation = generation
        do {
            let page = try await store.list(matching: query, filter: filter, limit: Self.pageSize)
            guard generation == self.generation else { return }
            clips = page
            hasMore = page.count == Self.pageSize
            regroup()
            if !(keepSelection && clips.contains { $0.id == selectedID }) {
                // 没有搜索词时选中最新的一条不置顶的，回车粘贴的是刚复制的那条（Raycast、Tinycast 都这样）。
                select((query.isEmpty ? clips.first { !$0.isPinned } : nil)?.id ?? clips.first?.id)
            }
        } catch {
            log.error("list failed: \(error, privacy: .public)")
        }
    }

    private func loadMore(near index: Int) {
        guard hasMore, !isLoadingMore, index >= clips.count - 20 else { return }
        isLoadingMore = true
        let generation = generation
        let offset = clips.count
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await store.list(matching: query, filter: filter, limit: Self.pageSize, offset: offset),
                  generation == self.generation else { return }
            // 翻页期间又记了新的，偏移会错开一点，按 id 去重。
            let seen = Set(clips.map(\.id))
            clips += page.filter { !seen.contains($0.id) }
            hasMore = page.count == Self.pageSize
            regroup()
        }
    }

    /// 列表行出现在屏幕上时调，翻到底就读下一页。
    func rowAppeared(_ clip: Clip) {
        if let index = clips.lastIndex(where: { $0.id == clip.id }) { loadMore(near: index) }
    }

    private func regroup() {
        let now = Date.now
        let calendar = Calendar.current
        var groups: [ClipGroup] = []
        for clip in clips {
            let section = ClipSection(clip, now: now, calendar: calendar)
            if groups.last?.section == section {
                groups[groups.count - 1].clips.append(clip)
            } else {
                groups.append(ClipGroup(section: section, clips: [clip]))
            }
        }
        self.groups = groups
    }

    // MARK: - 选中

    func select(_ id: Int64?) {
        isTypeMenuOpen = false
        guard id != selectedID || preview == nil else { return }
        selectedID = id
        loadPreview()
        selectionChanged?(selectedClip)
    }

    func move(_ delta: Int) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), clips.count - 1)
        select(clips[next].id)
        loadMore(near: next)
    }

    /// ⌘↓ 到下一组的第一条（已经是最后一组就到最后一条），⌘↑ 到上一组的第一条（已经是第一组就到第一条）。
    func jumpSection(_ direction: Int) {
        guard let index = groups.firstIndex(where: { $0.clips.contains { $0.id == selectedID } }) else { return }
        let target: Clip?
        if direction > 0 {
            target = index + 1 < groups.count ? groups[index + 1].clips.first : groups[index].clips.last
        } else {
            target = index > 0 ? groups[index - 1].clips.first : groups[index].clips.first
        }
        select(target?.id)
        if let target, let position = clips.firstIndex(where: { $0.id == target.id }) { loadMore(near: position) }
    }

    // MARK: - 改

    func togglePin() async {
        guard let clip = selectedClip else { return }
        do {
            try await store.setPinned(!clip.isPinned, id: clip.id)
        } catch {
            log.error("pin failed: \(error, privacy: .public)")
        }
        await reload(keepSelection: true)
        scrollToSelection += 1
    }

    /// 删掉选中的，选中它下面那条（已经是最后一条就选上面那条）。
    func deleteSelected() async {
        guard let index = clips.firstIndex(where: { $0.id == selectedID }) else { return }
        let id = clips[index].id
        let neighbor = index + 1 < clips.count ? clips[index + 1] : index > 0 ? clips[index - 1] : nil
        do {
            try await store.delete(id: id)
        } catch {
            log.error("delete failed: \(error, privacy: .public)")
        }
        select(neighbor?.id)
        await reload(keepSelection: true)
    }

    /// 先问一句；有类型筛选时只清这一类。没有能删的（全是置顶的）返回 false。
    func askToClear() async -> Bool {
        let count = (try? await store.unpinnedCount(filter: filter)) ?? 0
        guard count > 0 else { return false }
        clearConfirmation = ClearRequest(count: count, filter: filter)
        return true
    }

    func cancelClear() {
        clearConfirmation = nil
    }

    func confirmClear() async {
        let filter = clearConfirmation?.filter
        clearConfirmation = nil
        do {
            try await store.deleteAllUnpinned(filter: filter)
        } catch {
            log.error("clear failed: \(error, privacy: .public)")
        }
        await reload()
        scrollToTop += 1
    }

    /// 删掉最近这么多分钟里复制的（置顶的不删），返回删了几条。
    func deleteRecent(minutes: Int) async -> Int {
        let count: Int
        do {
            count = try await store.deleteCopied(since: Date.now.addingTimeInterval(-Double(minutes) * 60))
        } catch {
            log.error("delete recent failed: \(error, privacy: .public)")
            return 0
        }
        await reload(keepSelection: true)
        return count
    }

    /// 选中的置顶条目在置顶的里面往上、往下挪一位。
    func movePinned(up: Bool) async {
        guard let clip = selectedClip, clip.isPinned else { return }
        do {
            guard try await store.movePinned(id: clip.id, up: up) else { return }
        } catch {
            log.error("move pinned failed: \(error, privacy: .public)")
        }
        await reload(keepSelection: true)
        scrollToSelection += 1
    }

    // MARK: - 改名、编辑

    func startRename() {
        guard let clip = selectedClip else { return }
        renaming = RenameRequest(clip: clip, title: clip.customTitle ?? "")
    }

    func saveRename() async {
        guard let request = renaming else { return }
        renaming = nil
        do {
            try await store.rename(id: request.clip.id, to: request.title)
        } catch {
            log.error("rename failed: \(error, privacy: .public)")
        }
        await reload(keepSelection: true)
    }

    func startEdit() async {
        guard let clip = selectedClip, clip.kind == .text, let text = try? await store.text(of: clip.id) else { return }
        let formats = await formatTypes(of: clip)
        guard clip.id == selectedID else { return }
        editing = TextEdit(clip: clip, text: text, dropsFormats: !formats.isEmpty)
    }

    /// 保存编辑，回到列表，还选着这一条。
    func saveEdit() async {
        guard let edit = editing else { return }
        editing = nil
        do {
            try await store.editText(id: edit.clip.id, to: edit.text)
        } catch {
            log.error("edit failed: \(error, privacy: .public)")
        }
        await reload(keepSelection: true)
        // 还是这一条，select 不会重读预览，内容改了要重读。
        loadPreview()
    }

    /// 文本条目除了纯文本还存了哪些格式。
    func formatTypes(of clip: Clip) async -> [String] {
        guard clip.kind == .text else { return [] }
        return (try? await store.formatTypes(of: clip.id)) ?? []
    }

    // MARK: - 类型菜单

    func toggleTypeMenu() {
        isTypeMenuOpen.toggle()
        typeMenuIndex = Self.filterOptions.firstIndex { $0.filter == filter } ?? 0
    }

    func moveTypeMenu(_ delta: Int) {
        typeMenuIndex = min(max(typeMenuIndex + delta, 0), Self.filterOptions.count - 1)
    }

    func chooseType(at index: Int? = nil) {
        isTypeMenuOpen = false
        setFilter(Self.filterOptions[index ?? typeMenuIndex].filter)
    }

    // MARK: - 预览

    private func loadPreview() {
        previewTask?.cancel()
        guard let clip = selectedClip else {
            preview = nil
            return
        }
        previewTask = Task { [store] in
            let content: Preview.Content
            switch clip.kind {
            case .text:
                let full = (try? await store.text(of: clip.id)) ?? clip.title
                guard !Task.isCancelled else { return }
                var shown = String(full.prefix(Self.previewLength))
                if shown.utf8.count < full.utf8.count {
                    shown += "\n\n……（太长了，只显示前 \(Self.previewLength / 10_000) 万个字符）"
                }
                preview = Preview(clipID: clip.id, content: .text(shown))
                let count = await countWords(full)
                guard !Task.isCancelled else { return }
                wordCount = (clip.id, count)
                return
            case .image:
                if let url = clip.imageURL, let image = await ImageQueue.previews.downsample(url, maxPixel: Self.previewPixels) {
                    content = .image(image)
                } else {
                    content = .missing
                }
            case .file:
                // 只有一个文件、而且是图片时显示图片本身。
                if clip.fileURLs.count == 1, let url = clip.fileURLs.first, isImageFile(url),
                   let image = await ImageQueue.previews.downsample(url, maxPixel: Self.previewPixels) {
                    content = .image(image)
                } else {
                    content = .files
                }
            }
            guard !Task.isCancelled else { return }
            preview = Preview(clipID: clip.id, content: content)
        }
    }
}

private func isImageFile(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
}

/// 按系统的分词数词，中文按词算（ICU 的词典分词）。几 MB 的文本要数一会儿，放到后台。
@concurrent
private func countWords(_ text: String) async -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
        count += 1
    }
    return count
}
