import MochiCore
import SwiftUI

/// ⌘E 编辑文本：整个面板换成编辑框（照 Raycast 进一个编辑页）。⌘↵ 保存，⌥↵ 保存并复制，Esc 不保存。
struct EditView: View {
    let model: PanelModel
    let edit: TextEdit

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("编辑")
                    .font(.system(size: 15, weight: .semibold))
                Text(edit.clip.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .frame(height: PanelMetrics.headerHeight)
            Hairline()
            if edit.dropsFormats {
                Text("这条原来带格式（RTF、HTML），保存后只留纯文本。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
            }
            TextEditorView(text: Binding(get: { model.editing?.text ?? "" }, set: { model.editing?.text = $0 }),
                           monospaced: CodeApps.contains(edit.clip.sourceBundleID))
            Hairline()
            HStack(spacing: 8) {
                Spacer()
                Button { model.perform?(.escape) } label: { EditButtonLabel(title: "取消", key: "esc") }
                Button { model.perform?(.copy) } label: { EditButtonLabel(title: "保存", key: "⌘↵", isPrimary: true) }
                Button { model.perform?(.pasteKeepOpen) } label: { EditButtonLabel(title: "保存并复制", key: "⌥↵") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: PanelMetrics.footerClearance)
        }
        .background(.regularMaterial)
    }
}

private struct EditButtonLabel: View {
    let title: String
    let key: String
    var isPrimary = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Keycap(key: key)
        }
        .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.primary.opacity(isPrimary ? 0.12 : 0.06), in: Capsule())
        .contentShape(Capsule())
    }
}

/// ⇧⌘E 改名：一个小框。↵ 保存，Esc 不改；清空就恢复原来的标题。
struct RenameSheet: View {
    let model: PanelModel
    let request: RenameRequest

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .onTapGesture { model.perform?(.escape) }
            VStack(alignment: .leading, spacing: 4) {
                Text("改名")
                    .font(.system(size: 15, weight: .semibold))
                Text("列表里显示这个名字，搜索也搜得到；清空就恢复原来的标题。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                SearchField(text: Binding(get: { model.renaming?.title ?? "" }, set: { model.renaming?.title = $0 }),
                            placeholder: originalTitle, fontSize: 14, focusesOnAppear: true)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 10)
                HStack(spacing: 8) {
                    Spacer()
                    Button { model.perform?(.escape) } label: { EditButtonLabel(title: "取消", key: "esc") }
                    Button { model.perform?(.paste) } label: { EditButtonLabel(title: "保存", key: "↵", isPrimary: true) }
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            .padding(18)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
    }

    /// 不算名字的标题，空着时当提示字。
    private var originalTitle: String {
        let clip = request.clip
        return clip.kind == .text ? (clip.title.split(whereSeparator: \.isNewline).first.map(String.init) ?? clip.title) : clip.title
    }
}
