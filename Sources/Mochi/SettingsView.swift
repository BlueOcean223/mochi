import SwiftUI

/// 设置窗口里的内容：呼出快捷键、保留时长、开机启动、回车做什么、按顺序粘贴、辅助功能权限、忽略的应用、更新。样子照 Raycast。
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(model: model, slot: .panel)
                } label: {
                    Text("呼出快捷键")
                    // 总有一行小字，开始录的时候窗口不跳。
                    if let problem = model.shortcutProblems[.panel] {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(model.recording == .panel ? "按下新的组合，Esc 取消" : "点右边录新的组合")
                    }
                }
                Picker(selection: Binding(get: { model.retention }, set: { model.chooseRetention($0) })) {
                    ForEach(Retention.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("保留时长")
                    Text("置顶的不过期")
                }
                Toggle(isOn: Binding(get: { model.loginItem != .off }, set: { model.setLaunchAtLogin($0) })) {
                    Text("开机启动")
                    if let problem = model.loginProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                if model.loginItem == .needsApproval {
                    LabeledContent {
                        Button("打开登录项") { model.openLoginItems() }
                    } label: {
                        Text("还要在系统设置里允许")
                        Text("系统设置 › 通用 › 登录项与扩展，打开 Mochi")
                    }
                }
            }

            Section {
                Picker(selection: $model.enterAction) {
                    Text("粘贴到前台应用").tag(EnterAction.paste)
                    Text("复制到剪切板").tag(EnterAction.copy)
                } label: {
                    Text("回车")
                    Text(model.enterAction == .paste ? "⌘↵ 复制，⌥↵ 粘贴且不关闭面板" : "⌘↵ 粘贴，⌥↵ 复制且不关闭面板")
                }
                Toggle(isOn: $model.prefersPlainText) {
                    Text("优先粘贴纯文本")
                    Text("粘贴文本时去掉网页、文档带的格式；要带格式时按 ⌃⌘↵")
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        if model.sequenceShortcut != nil, model.recording != .sequence {
                            ClearButton { model.clearSequenceShortcut() }
                        }
                        ShortcutRecorder(model: model, slot: .sequence)
                    }
                } label: {
                    Text("按顺序粘贴")
                    if let problem = model.shortcutProblems[.sequence] {
                        Text(problem).foregroundStyle(.red)
                    } else if model.recording == .sequence {
                        Text("按下新的组合，⌫ 清掉，Esc 取消")
                    } else {
                        Text("每按一次，粘贴下一条更早的记录")
                    }
                }
                Toggle(isOn: $model.sequenceAddsNewline) {
                    Text("粘贴文本后换行")
                    Text("按顺序粘贴文本时，每条后面加一个换行")
                }
            }

            Section {
                LabeledContent {
                    if model.isTrusted {
                        Label {
                            Text("已授权")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    } else {
                        Button("去授权") { model.openAccessibilitySettings() }
                    }
                } label: {
                    Text("辅助功能权限")
                    Text(model.isTrusted ? "回车直接粘贴到前台应用" : "没有它，回车只复制，要自己按 ⌘V")
                }
            }

            Section {
                IgnoredApps(model: model)
            }

            Section {
                UpdateRow(updater: model.updater)
                Toggle(isOn: $model.checksForUpdates) {
                    Text("自动检查更新")
                    Text("每天问一次 GitHub 有没有新版本")
                }
            }
        }
        .formStyle(.grouped)
        // 标题栏不画标题以后，上面的空白显得太多，收一点。滚动的时候不收，不然内容会滚到红绿灯底下。
        .padding(.top, scrolls ? 0 : -12)
        // 窗口跟着内容一样高；忽略的应用多到窗口太高时改成固定高度，里面滚动。
        .frame(width: 480, height: scrolls ? 800 : nil)
        .fixedSize(horizontal: false, vertical: !scrolls)
        .scrollDisabled(!scrolls)
        .fileImporter(isPresented: $model.isChoosingFile, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.ignoreApps(at: urls) }
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
        .alert(retentionTitle, isPresented: Binding(get: { model.retentionChange != nil }, set: { if !$0 { model.retentionChange = nil } }),
               presenting: model.retentionChange) { change in
            Button(role: .destructive) {
                model.confirmRetentionChange()
            } label: {
                Text(verbatim: "删掉 \(change.count) 条")
            }
            Button("取消", role: .cancel) {}
        } message: { change in
            Text(verbatim: "超过 \(change.retention.title)的 \(change.count) 条记录会马上删掉，置顶的不删。删了找不回来。")
        }
    }

    /// 4 个时窗口大约 810 高（每个应用 33），再多就固定高度、里面滚动。13 寸的 MacBook Air 屏幕可用的高度在 900 上下。
    private var scrolls: Bool { model.ignoredApps.count > 4 }

    private var retentionTitle: String {
        "改成只保留 \(model.retentionChange?.retention.title ?? "")？"
    }
}

/// 现在的版本和检查更新的结果。有新版本时右边是「更新到 …」，下面是更新说明的链接。
private struct UpdateRow: View {
    let updater: Updater

    var body: some View {
        LabeledContent {
            if updater.isBusy {
                ProgressView().controlSize(.small)
            } else if let version = updater.latest?.version {
                Button("更新到 \(version.description)") { Task { await updater.install() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("检查更新") { Task { await updater.check(userInitiated: true) } }
                    .disabled(!updater.isAvailable)
            }
        } label: {
            Text(verbatim: "Mochi \(updater.currentVersion)")
            detail
        }
    }

    @ViewBuilder private var detail: some View {
        switch updater.status {
        case .checking: Text("正在检查…")
        case .downloading: Text("正在下载…")
        case .installing: Text("正在安装…")
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .upToDate where updater.latest == nil: Text("已经是最新版本")
        default:
            if let latest = updater.latest {
                Text(Self.notesLink(latest.pageURL))
            } else if let checked = updater.lastChecked {
                Text(verbatim: "上次检查：\(Formatting.copiedAt(checked))")
            } else {
                Text("还没检查过")
            }
        }
    }

    /// 链接直接设在 AttributedString 上。不用 `LocalizedStringKey("…[看看改了什么](\(url))")`：字面量里的插值
    /// 变成格式参数，Markdown 解析的是 `(%@)`，点了交给系统的网址是 `%@`，系统报 -50。
    private static func notesLink(_ url: URL) -> AttributedString {
        var text = AttributedString("新版本已发布，")
        var link = AttributedString("看看改了什么")
        link.link = url
        text.append(link)
        return text
    }
}

/// 点一下开始录，再点一下或者按 Esc 取消。每个键画成一个键帽，录的时候按住的修饰键一个个冒出来。
private struct ShortcutRecorder: View {
    let model: SettingsModel
    let slot: ShortcutSlot
    @State private var isHovering = false

    private var isRecording: Bool { model.recording == slot }

    var body: some View {
        Button {
            isRecording ? model.stopRecording() : model.startRecording(slot)
        } label: {
            HStack(spacing: 3) {
                if !isRecording {
                    if let shortcut = model.shortcut(for: slot) {
                        ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { ShortcutKeycap(key: $0.element) }
                    } else {
                        Text("录快捷键")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                } else if model.heldModifiers.isEmpty {
                    Text("按下快捷键")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                } else {
                    ForEach(Array(model.heldModifiers.enumerated()), id: \.offset) { ShortcutKeycap(key: $0.element) }
                    Text(verbatim: "…").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(minWidth: 96, minHeight: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if isRecording {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: "\(slot.title) \(model.shortcut(for: slot)?.description ?? "没有")"))
    }

    private var fill: Color {
        if isRecording { return Color(nsColor: .windowBackgroundColor) }
        return .primary.opacity(isHovering ? 0.12 : 0.08)
    }
}

/// 快捷键左边的 ⓧ：不要这个快捷键了。
private struct ClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .help("清掉快捷键")
        .accessibilityLabel(Text("清掉快捷键"))
    }
}

private struct ShortcutKeycap: View {
    let key: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 12))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 19)
            .background(colorScheme == .dark ? Color.white.opacity(0.1) : .white, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 0.5, y: 0.5)
    }
}

/// 「忽略的应用」整张卡片是表单里的一行：标题、说明、+ 在上面，下面是应用，行间的线自己画，
/// 这样标题和第一个应用之间没有线，应用行可以比表单的行矮（32）。
private struct IgnoredApps: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("忽略的应用")
                    Text("这些应用在前台时复制的东西不记")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PlusButton { model.openAppPicker() }
                    .popover(isPresented: Binding(get: { model.isPickingApp && !model.isQuiet }, set: { model.isPickingApp = $0 }),
                             arrowEdge: .bottom) {
                        AppPicker(model: model)
                    }
            }
            .padding(.bottom, model.ignoredApps.isEmpty ? 0 : 6)
            ForEach(Array(model.ignoredApps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider() }
                IgnoredAppRow(model: model, app: app)
            }
        }
    }
}

/// 灰底小方块，和快捷键那一格一样的底色。
private struct PlusButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(.primary.opacity(isHovering ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("添加应用")
        .accessibilityLabel(Text("添加应用"))
    }
}

/// 平时只有图标和名字；鼠标移上去行尾出现 ⊖。右键也能移除。
private struct IgnoredAppRow: View {
    let model: SettingsModel
    let app: SettingsModel.IgnoredApp

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if model.hoveredApp == app.id {
                Button {
                    model.stopIgnoring(app.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("不再忽略")
            }
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hoveredApp = app.id
            } else if model.hoveredApp == app.id {
                model.hoveredApp = nil
            }
        }
        .contextMenu {
            Button("不再忽略「\(app.name)」") { model.stopIgnoring(app.id) }
        }
    }
}

private extension Retention {
    var title: String {
        switch self {
        case .hour: "1 小时"
        case .day: "1 天"
        case .week: "7 天"
        case .month: "30 天"
        case .threeMonths: "3 个月"
        case .year: "1 年"
        case .forever: "永久"
        }
    }
}
