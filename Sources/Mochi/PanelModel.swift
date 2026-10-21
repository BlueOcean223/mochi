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

/// 面板里的键盘命令和底栏按钮。
enum PanelCommand {
    case up, down, sectionUp, sectionDown, typeMenu, escape
    case paste, copy, pastePlain, pin, delete, clearAll, quickLook, revealInFinder, openLink
}

/// 面板的状态：搜索词、类型筛选、当前这一页、选中哪条、预览。界面只读它，改都走这里的方法。
@MainActor
@Observable
final class PanelModel {
    struct KindOption {
        let kind: ClipKind?
        let label: String
    }

    static let kindOptions = [
        KindOption(kind: nil, label: "全部类型"),
        KindOption(kind: .text, label: "文本"),
        KindOption(kind: .image, label: "图片"),
        KindOption(kind: .file, label: "文件"),
    ]

    /// 一次读多少条；往下翻到离末尾 20 条时读下一页。
    static let pageSize = 100
    /// 文本预览最多显示这么多个字符，再长的 NSTextView 排版会卡。
    static let previewLength = 100_000

    private(set) var query = ""
    private(set) var kind: ClipKind?
    private(set) var clips: [Clip] = []
    private(set) var groups: [ClipGroup] = []
    private(set) var selectedID: Int64?
    private(set) var preview: Preview?
    private(set) var wordCount: (clipID: Int64, count: Int)?
    private(set) var isPaused = false
    /// 呼出面板时的前台应用，回车粘贴到它那里。
    private(set) var frontAppName: String?
    var isTypeMenuOpen = false
    var typeMenuIndex = 0
    /// 每次加一，列表就滚回顶上（呼出、换搜索词时）。
    private(set) var scrollToTop = 0

    /// 底栏按钮、双击走这里，由 PanelController 接。
    @ObservationIgnored var perform: ((PanelCommand) -> Void)?

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

    var kindLabel: String {
        Self.kindOptions.first { $0.kind == kind }?.label ?? "全部类型"
    }

    var isFiltered: Bool {
        !query.isEmpty || kind != nil
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
    func prepare(isPaused: Bool, frontAppName: String?) async {
        self.isPaused = isPaused
        self.frontAppName = frontAppName
        isTypeMenuOpen = false
        query = ""
        kind = nil
        await reload()
        scrollToTop += 1
    }

    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        Task { await reload(); scrollToTop += 1 }
    }

    func setKind(_ kind: ClipKind?) {
        guard kind != self.kind else { return }
        self.kind = kind
        Task { await reload(); scrollToTop += 1 }
    }

    /// 重读第一页。`keepSelection` 为真时（置顶、删除以后）尽量留在原来那条上。
    func reload(keepSelection: Bool = false) async {
        generation += 1
        let generation = generation
        do {
            let page = try await store.list(matching: query, kind: kind, limit: Self.pageSize)
            guard generation == self.generation else { return }
            clips = page
            hasMore = page.count == Self.pageSize
            regroup()
            if !(keepSelection && clips.contains { $0.id == selectedID }) {
                select(clips.first?.id)
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
            guard let page = try? await store.list(matching: query, kind: kind, limit: Self.pageSize, offset: offset),
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

    // MARK: - 类型菜单

    func toggleTypeMenu() {
        isTypeMenuOpen.toggle()
        typeMenuIndex = Self.kindOptions.firstIndex { $0.kind == kind } ?? 0
    }

    func moveTypeMenu(_ delta: Int) {
        typeMenuIndex = min(max(typeMenuIndex + delta, 0), Self.kindOptions.count - 1)
    }

    func chooseType(at index: Int? = nil) {
        isTypeMenuOpen = false
        setKind(Self.kindOptions[index ?? typeMenuIndex].kind)
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
                if let url = clip.imageURL, let image = await Images.downsample(url, maxPixel: 1200) {
                    content = .image(image)
                } else {
                    content = .missing
                }
            case .file:
                // 只有一个文件、而且是图片时显示图片本身。
                if clip.fileURLs.count == 1, let url = clip.fileURLs.first, isImageFile(url),
                   let image = await Images.downsample(url, maxPixel: 1200) {
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
