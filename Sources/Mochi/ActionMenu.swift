import AppKit
import MochiCore

/// ⌘K 操作面板里有子菜单的几项。
enum ActionSubmenu: Equatable {
    /// ⌥⌘↵：列出这条存了的格式，只粘贴选的那种。
    case pasteAs
    /// ⌘O（文件）：能打开它的应用。
    case openWith
    /// ⇧⌘X：5 分钟到 24 小时。
    case deleteRecent

    var title: String {
        switch self {
        case .pasteAs: "选格式粘贴"
        case .openWith: "用其他应用打开"
        case .deleteRecent: "删除最近的"
        }
    }
}

/// ⌘K 操作面板里的一行。
struct PanelAction: Identifiable {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    let title: String
    let icon: Icon
    /// 快捷键，每个字符画一个键帽。
    var shortcut: String?
    /// 删除类：红字。
    var isDestructive = false
    /// 第几组，组之间画分隔线。
    var group = 0
    let command: PanelCommand

    var id: String { title }
}

/// ⌘K 操作面板的状态。子菜单压在上面一层，Esc 退回上一层。底栏左边「设置」的菜单也用它。
struct ActionMenu {
    enum Placement {
        /// ⌘K：这一条的操作，贴在面板右下角。
        case clip
        /// 底栏左边的「设置」：Mochi 自己的菜单，贴在左下角。
        case app
    }

    struct Level {
        let title: String
        let actions: [PanelAction]
    }

    private(set) var levels: [Level]
    let placement: Placement
    /// 底下搜索框里的字，按标题筛。
    var query = "" {
        didSet { highlighted = 0 }
    }
    var highlighted = 0
    /// 上一次认的鼠标位置（屏幕坐标）。行滑到不动的指针下面（刚打开、按键滚动）也会报悬停，指针没动过就不算。
    private var pointer = NSEvent.mouseLocation

    init(_ root: Level, placement: Placement = .clip) {
        levels = [root]
        self.placement = placement
    }

    /// 鼠标停到第 `index` 行上。指针真的动过才跟着高亮（Raycast、Tinycast 都这样）。
    mutating func hover(_ index: Int) {
        let location = NSEvent.mouseLocation
        guard location != pointer else { return }
        pointer = location
        highlighted = index
    }

    var level: Level { levels[levels.count - 1] }
    var isSubmenu: Bool { levels.count > 1 }

    var visible: [PanelAction] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return level.actions }
        return level.actions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var highlightedAction: PanelAction? {
        let visible = visible
        return visible.indices.contains(highlighted) ? visible[highlighted] : nil
    }

    mutating func move(_ delta: Int) {
        highlighted = min(max(highlighted + delta, 0), max(visible.count - 1, 0))
    }

    mutating func push(_ level: Level) {
        levels.append(level)
        query = ""
    }

    /// Esc：先清搜索词，再退一层。已经在最外层返回 false（该关面板了）。
    mutating func back() -> Bool {
        if !query.isEmpty {
            query = ""
            return true
        }
        guard isSubmenu else { return false }
        levels.removeLast()
        highlighted = 0
        return true
    }
}

extension PanelModel {
    /// 打开 ⌘K 操作面板；给了 `submenu` 就直接进那个子菜单（⌥⌘↵、⇧⌘X），Esc 回到外层。
    func openActionMenu(submenu: ActionSubmenu? = nil) async {
        guard let clip = selectedClip else { return }
        let formats = await formatTypes(of: clip)
        guard clip.id == selectedID else { return }
        var menu = ActionMenu(.init(title: Self.menuTitle(clip), actions: rootActions(for: clip, formats: formats)))
        if let submenu, let level = submenuLevel(submenu, for: clip, formats: formats) {
            menu.push(level)
        }
        actionMenu = menu
    }

    /// 底栏左边「设置」的菜单。
    func openAppMenu() {
        isTypeMenuOpen = false
        let actions = [
            PanelAction(title: "设置…", icon: .symbol("gearshape"), shortcut: "⌘,", command: .settings),
            PanelAction(title: isPaused ? "恢复记录" : "暂停记录", icon: .symbol(isPaused ? "play.circle" : "pause.circle"),
                        command: .togglePause),
            PanelAction(title: "窗口位置复原", icon: .symbol("arrow.uturn.backward"), command: .resetPosition),
            PanelAction(title: "退出 Mochi", icon: .symbol("power"), shortcut: "⌘Q", group: 1, command: .quit),
        ]
        actionMenu = ActionMenu(.init(title: "Mochi", actions: actions), placement: .app)
    }

    /// 已经开着时进子菜单。
    func pushSubmenu(_ submenu: ActionSubmenu) async {
        guard let clip = selectedClip else { return }
        let formats = await formatTypes(of: clip)
        guard let level = submenuLevel(submenu, for: clip, formats: formats) else { return }
        actionMenu?.push(level)
    }

    /// 标题行：开头 40 个字，换行、连续的空白并成一个空格。
    private static func menuTitle(_ clip: Clip) -> String {
        let words = (clip.customTitle ?? clip.title).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 40 ? String(words.prefix(40)) + "…" : words
    }

    private func rootActions(for clip: Clip, formats: [String]) -> [PanelAction] {
        // 顺序照 Raycast：↵、⌘↵、⌥↵、⌥⌘↵、⌃⌘↵。每个组合做什么跟着设置变（EnterKeys）。
        let keys = enterKeys
        var actions = [pasteAction(keys.enter, "↵"), pasteAction(keys.commandEnter, "⌘↵"), pasteAction(keys.optionEnter, "⌥↵")]
        if !formats.isEmpty {
            actions.append(PanelAction(title: "选格式粘贴…", icon: .symbol("doc.richtext"), shortcut: "⌥⌘↵", command: .submenu(.pasteAs)))
        }
        if clip.kind == .text || clip.kind == .file {
            actions.append(pasteAction(keys.controlCommandEnter, "⌃⌘↵"))
        }

        var manage: [PanelAction] = []
        if clip.isLink {
            manage.append(PanelAction(title: "用浏览器打开", icon: .symbol("safari"), shortcut: "⌘O", command: .open))
        }
        if clip.kind == .file {
            manage.append(PanelAction(title: "用其他应用打开…", icon: .symbol("arrow.up.forward.app"), shortcut: "⌘O", command: .open))
            manage.append(PanelAction(title: "在 Finder 中显示", icon: .symbol("folder"), shortcut: "⇧⌘O", command: .revealInFinder))
        }
        if clip.kind != .text {
            manage.append(PanelAction(title: "Quick Look", icon: .symbol("eye"), shortcut: "⌘Y", command: .quickLook))
        }
        if clip.kind == .text {
            manage.append(PanelAction(title: "编辑", icon: .symbol("pencil"), shortcut: "⌘E", command: .edit))
        }
        manage.append(PanelAction(title: "改名…", icon: .symbol("character.cursor.ibeam"), shortcut: "⇧⌘E", command: .rename))
        manage.append(PanelAction(title: clip.isPinned ? "取消置顶" : "置顶", icon: .symbol(clip.isPinned ? "pin.slash" : "pin"),
                                  shortcut: "⌘.", command: .pin))
        if clip.isPinned {
            let pinned = clips.filter(\.isPinned)
            if pinned.first?.id != clip.id {
                manage.append(PanelAction(title: "在置顶里上移", icon: .symbol("arrow.up"), shortcut: "⌥⌘↑", command: .movePinnedUp))
            }
            if pinned.last?.id != clip.id {
                manage.append(PanelAction(title: "在置顶里下移", icon: .symbol("arrow.down"), shortcut: "⌥⌘↓", command: .movePinnedDown))
            }
        }

        let clearTitle = filter == nil ? "清空全部" : "清空所有\(filterLabel)"
        let delete = [
            PanelAction(title: "删除", icon: .symbol("trash"), shortcut: "⌃X", isDestructive: true, command: .delete),
            PanelAction(title: "删除最近的…", icon: .symbol("clock.arrow.circlepath"), shortcut: "⇧⌘X", isDestructive: true,
                        command: .submenu(.deleteRecent)),
            PanelAction(title: clearTitle, icon: .symbol("xmark.bin"), shortcut: "⌃⇧X", isDestructive: true, command: .clearAll),
        ]
        return actions + manage.map { $0.inGroup(1) } + delete.map { $0.inGroup(2) }
    }

    /// 粘贴、复制那几行。粘贴类的图标是前台应用的。
    private func pasteAction(_ command: PanelCommand, _ shortcut: String) -> PanelAction {
        let app: PanelAction.Icon = frontAppIcon.map { .image($0) } ?? .symbol("arrow.down.doc")
        let pasteTo = frontAppName.map { "粘贴到 \($0)" } ?? "粘贴"
        return switch command {
        case .paste: PanelAction(title: enterKeys.enter == .pastePlain ? "带格式粘贴" : pasteTo, icon: app, shortcut: shortcut, command: command)
        case .pastePlain: PanelAction(title: "粘贴为纯文本", icon: app, shortcut: shortcut, command: command)
        case .pasteKeepOpen: PanelAction(title: "粘贴且不关闭面板", icon: app, shortcut: shortcut, command: command)
        case .copyKeepOpen: PanelAction(title: "复制且不关闭面板", icon: .symbol("doc.on.doc"), shortcut: shortcut, command: command)
        default: PanelAction(title: "复制", icon: .symbol("doc.on.doc"), shortcut: shortcut, command: .copy)
        }
    }

    private func submenuLevel(_ submenu: ActionSubmenu, for clip: Clip, formats: [String]) -> ActionMenu.Level? {
        let actions: [PanelAction]
        switch submenu {
        case .pasteAs:
            guard !formats.isEmpty else { return nil }
            let types = [PasteboardTypes.plainText] + formats
            actions = types.map { type in
                PanelAction(title: Self.formatName(type), icon: .symbol("doc.text"), command: .pasteFormat(type))
            }
            .sorted { $0.title < $1.title }
        case .openWith:
            guard clip.kind == .file, let file = clip.fileURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                return nil
            }
            let preferred = NSWorkspace.shared.urlForApplication(toOpen: file)
            var apps = NSWorkspace.shared.urlsForApplications(toOpen: file).filter { $0 != preferred }
            if let preferred { apps.insert(preferred, at: 0) }
            var seen = Set<String>()
            actions = apps.compactMap { url in
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "", options: .anchored.union(.backwards))
                guard seen.insert(name).inserted else { return nil }
                return PanelAction(title: url == preferred ? "\(name)（默认）" : name,
                                   icon: .image(NSWorkspace.shared.icon(forFile: url.path)), command: .openWith(url))
            }
        case .deleteRecent:
            actions = [(5, "最近 5 分钟"), (15, "最近 15 分钟"), (30, "最近 30 分钟"), (60, "最近 1 小时"), (1440, "最近 24 小时")].map {
                PanelAction(title: $0.1, icon: .symbol("clock"), isDestructive: true, command: .deleteRecent(minutes: $0.0))
            }
        }
        return ActionMenu.Level(title: submenu.title, actions: actions)
    }

    private static func formatName(_ type: String) -> String {
        switch type {
        case PasteboardTypes.plainText: "纯文本"
        case PasteboardTypes.rtf: "RTF"
        case PasteboardTypes.html: "HTML"
        case PasteboardTypes.url: "网址"
        default: type
        }
    }
}

private extension PanelAction {
    func inGroup(_ group: Int) -> PanelAction {
        var action = self
        action.group = group
        return action
    }
}
