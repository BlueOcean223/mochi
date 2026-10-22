import AppKit
import MochiCore
import SwiftUI

/// 尺寸照 Raycast 2.8.2 前端包里的样式；行高、列表宽度是对着截图估的。
enum PanelMetrics {
    static let size = CGSize(width: 750, height: 475)
    static let cornerRadius: CGFloat = 26
    static let headerHeight: CGFloat = 64
    static let listWidth: CGFloat = 300
    static let rowHeight: CGFloat = 40
    /// 比 Raycast 的 36 小，不那么抢眼。
    static let footerHeight: CGFloat = 30
    static let footerInset: CGFloat = 8
    /// 底部操作条浮在内容上面，列表和信息区底下要让出这么多。
    static var footerClearance: CGFloat { footerHeight + footerInset * 2 }
}

struct PanelView: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            Hairline()
            if model.clips.isEmpty {
                EmptyState(isFiltered: model.isFiltered)
            } else {
                HStack(spacing: 0) {
                    ClipList(model: model)
                        .frame(width: PanelMetrics.listWidth)
                    Hairline(vertical: true)
                    DetailView(model: model)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.selectedClip != nil || model.isPaused {
                Footer(model: model)
                    .padding(PanelMetrics.footerInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isTypeMenuOpen {
                TypeMenu(model: model)
                    .padding(.top, 54)
                    .padding(.trailing, 16)
            }
        }
        .overlay {
            if let count = model.clearConfirmation {
                ClearConfirmation(model: model, count: count)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
    }
}

private struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

private struct Keycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - 搜索栏

private struct Header: View {
    let model: PanelModel

    var body: some View {
        HStack(spacing: 10) {
            SearchField(text: Binding(get: { model.query }, set: { model.setQuery($0) }), placeholder: "搜索剪切板历史…")
            Button {
                model.toggleTypeMenu()
            } label: {
                HStack(spacing: 6) {
                    Text(model.kindLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .frame(height: PanelMetrics.headerHeight)
        .background(WindowDragArea())
    }
}

private struct TypeMenu: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(PanelModel.kindOptions.enumerated()), id: \.offset) { index, option in
                HStack {
                    Text(option.label)
                    Spacer()
                    if option.kind == model.kind {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(index == model.typeMenuIndex ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.chooseType(at: index) }
                .onHover { if $0 { model.typeMenuIndex = index } }
            }
        }
        .font(.system(size: 13))
        .padding(6)
        .frame(width: 180)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

// MARK: - 列表

private struct ClipList: View {
    let model: PanelModel

    /// 滚动区域只到底栏上沿，方向键选中的行才不会停在底栏下面（scrollTo 不管 contentMargins、safeAreaPadding）。
    /// 关掉裁剪，内容照样画到底栏下面，外面再按列表这一栏裁。
    var body: some View {
        VStack(spacing: 0) {
            list
            Color.clear
                .frame(height: PanelMetrics.footerClearance)
        }
        .clipped()
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 一层平铺的 ForEach：嵌套的 ForEach 里还没画出来的行，scrollTo 找不到。
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        switch row {
                        case .top:
                            Color.clear
                                .frame(height: 6)
                        case .header(let section):
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(EdgeInsets(top: 10, leading: 10, bottom: 5, trailing: 10))
                        case .clip(let clip):
                            ClipRow(clip: clip, isSelected: clip.id == model.selectedID)
                                .onTapGesture { model.select(clip.id) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { model.perform?(.paste) })
                                .onAppear { model.rowAppeared(clip) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .scrollClipDisabled()
            .onChange(of: model.selectedID) { old, id in
                guard let id else { return }
                // 一次更新里只有最后一个 scrollTo 算数，所以按方向挑一个：滚动只挪最少的距离，
                // 往下时滚到这一行，组名在它上面自然露出来；往上移到组里第一条时滚到组名（第一组滚到顶），这一行就在组名下面。
                let movingUp = (model.clips.firstIndex { $0.id == id } ?? 0) < (model.clips.firstIndex { $0.id == old } ?? 0)
                if movingUp, model.groups.first?.clips.first?.id == id {
                    proxy.scrollTo(Row.ID.top)
                } else if movingUp, let group = model.groups.first(where: { $0.clips.first?.id == id }) {
                    proxy.scrollTo(Row.ID.header(group.section))
                } else {
                    proxy.scrollTo(Row.ID.clip(id))
                }
            }
            .onChange(of: model.scrollToTop) {
                proxy.scrollTo(Row.ID.top, anchor: .top)
            }
            .onChange(of: model.scrollToSelection) {
                guard let id = model.selectedID else { return }
                // 置顶以后它到了第一组，滚到顶；取消置顶以后它回到时间里的位置。
                if model.groups.first?.clips.first?.id == id {
                    proxy.scrollTo(Row.ID.top, anchor: .top)
                } else {
                    proxy.scrollTo(Row.ID.clip(id))
                }
            }
        }
    }

    private enum Row {
        enum ID: Hashable {
            case top
            case header(ClipSection)
            case clip(Int64)
        }

        case top
        case header(ClipSection)
        case clip(Clip)

        var id: ID {
            switch self {
            case .top: .top
            case .header(let section): .header(section)
            case .clip(let clip): .clip(clip.id)
            }
        }
    }

    private var rows: [Row] {
        var rows = [Row.top]
        for group in model.groups {
            rows.append(.header(group.section))
            rows += group.clips.map(Row.clip)
        }
        return rows
    }
}

private struct ClipRow: View {
    let clip: Clip
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(clip: clip)
                .frame(width: 22, height: 22)
            Text(clip.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: PanelMetrics.rowHeight)
        .background(Color.primary.opacity(isSelected ? 0.1 : isHovered ? 0.05 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// 文本是类型图标（文本、链接），图片是缩略图，文件是文件图标。
private struct ClipIcon: View {
    let clip: Clip

    var body: some View {
        switch clip.kind {
        case .text:
            Image(systemName: clip.isLink ? "link" : "text.alignleft")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .image:
            if let url = clip.imageURL, let thumbnail = clip.thumbnailURL {
                Thumbnail(url: url, thumbnailURL: thumbnail)
            }
        case .file:
            if let url = clip.fileURLs.first {
                Image(nsImage: Icons.file(url))
                    .resizable()
            }
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    let thumbnailURL: URL
    @State private var image: CGImage?

    init(url: URL, thumbnailURL: URL) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        _image = State(initialValue: Thumbnails.cached(thumbnailURL))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.primary.opacity(0.08)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .task(id: url) {
            if image == nil { image = await Thumbnails.load(url, thumbnailURL: thumbnailURL) }
        }
    }
}

private struct EmptyState: View {
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(isFiltered ? "没有匹配的记录" : "还没有记录")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(isFiltered ? "换个词试试，或者按 ⌘P 换类型。" : "复制点什么，会出现在这里。")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 右侧

private struct DetailView: View {
    let model: PanelModel

    var body: some View {
        if let clip = model.selectedClip {
            VStack(spacing: 0) {
                PreviewArea(clip: clip, preview: model.preview(for: clip))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline()
                InfoSection(clip: clip, wordCount: model.wordCount(for: clip))
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, PanelMetrics.footerClearance)
            }
        } else {
            Color.clear
        }
    }
}

private struct PreviewArea: View {
    let clip: Clip
    let preview: Preview?

    var body: some View {
        ZStack {
            // 文本预览一直留着，不是文本时清空、藏起来，不销毁（原因见 TextPreview）。
            TextPreview(text: text ?? "", monospaced: CodeApps.contains(clip.sourceBundleID))
                .opacity(text == nil ? 0 : 1)
                .allowsHitTesting(text != nil)
            switch preview?.content {
            case .image(let image):
                ImagePreview(image: image)
            case .files:
                FileList(urls: clip.fileURLs)
            case .missing:
                Text("图片文件不在了")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            case .text, nil:
                EmptyView()
            }
        }
    }

    private var text: String? {
        if case .text(let text) = preview?.content { text } else { nil }
    }
}

/// 缩到放得下为止，不放大。
private struct ImagePreview: View {
    let image: CGImage

    var body: some View {
        GeometryReader { geometry in
            let natural = CGSize(width: image.width, height: image.height)
            let available = CGSize(width: geometry.size.width - 32, height: geometry.size.height - 32)
            let scale = max(0, min(1, available.width / natural.width, available.height / natural.height))
            ImageLayer(image: image, cornerRadius: 6)
                .frame(width: natural.width * scale, height: natural.height * scale)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct FileList: View {
    let urls: [URL]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(urls, id: \.self) { url in
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    HStack(spacing: 12) {
                        Image(nsImage: Icons.file(url))
                            .resizable()
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(exists ? Formatting.path(url) : "文件不在了：\(Formatting.path(url))")
                                .font(.system(size: 12))
                                .foregroundStyle(exists ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InfoSection: View {
    let clip: Clip
    let wordCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("信息")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            InfoRow(label: "来源") {
                HStack(spacing: 6) {
                    if let icon = Icons.app(clip.sourceBundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(clip.sourceName ?? "未知")
                }
            }
            InfoRow(label: "类型") { Text(clip.typeLabel) }
            switch clip.kind {
            case .text:
                InfoRow(label: "字符数") { Text((clip.characterCount ?? 0).formatted()) }
                InfoRow(label: "词数") { Text(wordCount.map { $0.formatted() } ?? " ") }
            case .image:
                InfoRow(label: "尺寸") { Text(verbatim: "\(clip.imageWidth ?? 0)×\(clip.imageHeight ?? 0)") }
                InfoRow(label: "大小") { Text(Formatting.bytes(clip.byteSize)) }
            case .file:
                InfoRow(label: "文件") {
                    Text(clip.fileURLs.count == 1 ? clip.fileURLs.first.map(Formatting.path) ?? "" : "\(clip.fileURLs.count) 个")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            InfoRow(label: "复制时间", isLast: true) { Text(Formatting.copiedAt(clip.lastCopiedAt)) }
        }
        .font(.system(size: 13))
    }
}

private struct InfoRow<Value: View>: View {
    let label: String
    var isLast = false
    @ViewBuilder let value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                value
            }
            .frame(height: 27)
            if !isLast { Hairline() }
        }
    }
}

/// 清空前问一句。回车清空、Esc 取消（PanelController.handleKey）。
private struct ClearConfirmation: View {
    let model: PanelModel
    let count: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .onTapGesture { model.cancelClear() }
            VStack(spacing: 4) {
                Text("清空全部记录？")
                    .font(.system(size: 15, weight: .semibold))
                Text(verbatim: "会删掉 \(count) 条，置顶的留着。删了找不回来。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button { model.cancelClear() } label: {
                        ConfirmButtonLabel(title: "取消", key: "esc", isDestructive: false)
                    }
                    Button { Task { await model.confirmClear() } } label: {
                        ConfirmButtonLabel(title: "清空", key: "↵", isDestructive: true)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            .padding(18)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
    }
}

private struct ConfirmButtonLabel: View {
    let title: String
    let key: String
    let isDestructive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key)
                .font(.system(size: 11))
                .opacity(0.7)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(isDestructive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - 底栏

/// 底栏：左右两个独立的胶囊，中间空着（照 Raycast）。左边是提示和次要操作，右边是粘贴和复制。
private struct Footer: View {
    let model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if !model.canPaste {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                            Text("没有辅助功能权限").foregroundStyle(.orange)
                        }
                        Text("回车只复制")
                        Button("去授权") { model.perform?(.openAccessibilitySettings) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10)
                } else if model.isPaused {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                            Text("暂停记录中").foregroundStyle(.orange)
                        }
                        Text("新的复制不会出现在这里")
                    }
                    .padding(.horizontal, 10)
                } else if let clip = model.selectedClip {
                    HStack(spacing: 2) {
                        ForEach(actions(for: clip), id: \.title) { action in
                            FooterButton(title: action.title, key: action.key) { model.perform?(action.command) }
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .footerPill()
            Spacer(minLength: 0)
            if model.selectedClip != nil {
                HStack(spacing: 2) {
                    if model.canPaste {
                        FooterButton(title: model.frontAppName.map { "粘贴到 \($0)" } ?? "粘贴", key: "↵", isPrimary: true) {
                            model.perform?(.paste)
                        }
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 12)
                        FooterButton(title: "复制", key: "⌘↵") { model.perform?(.copy) }
                    } else {
                        FooterButton(title: "复制", key: "↵", isPrimary: true) { model.perform?(.copy) }
                    }
                }
                .padding(.horizontal, 3)
                .footerPill()
            }
        }
        .font(.system(size: 12))
    }

    /// 当前这条能用的次要操作。
    private func actions(for clip: Clip) -> [(title: String, key: String, command: PanelCommand)] {
        var actions = [(title: clip.isPinned ? "取消置顶" : "置顶", key: "⌘.", command: PanelCommand.pin)]
        switch clip.kind {
        case .text: actions.append(clip.isLink ? ("打开链接", "⌘O", .openLink) : ("粘贴为纯文本", "⇧↵", .pastePlain))
        case .image: actions.append(("Quick Look", "⌘Y", .quickLook))
        case .file: actions += [("Quick Look", "⌘Y", .quickLook), ("在 Finder 中显示", "⇧⌘F", .revealInFinder)]
        }
        return actions
    }
}

private extension View {
    func footerPill() -> some View {
        frame(height: PanelMetrics.footerHeight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

private struct FooterButton: View {
    let title: String
    let key: String
    var isPrimary = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(isPrimary ? .primary : .secondary)
                    .lineLimit(1)
                Keycap(key: key)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
