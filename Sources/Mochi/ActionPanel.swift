import AppKit
import SwiftUI

/// ⌘K 操作面板：贴在面板右下角往上长，顶上是这一条的标题（子菜单是子菜单名），中间是操作，最底下是搜索框。
/// 宽度、位置照 Raycast 2.8.2（宽 350，右下角往里 8）；行比它的 36 矮，和类型菜单一样紧凑；操作比它少分组，高一点能少滚。
struct ActionPanel: View {
    let model: PanelModel
    let menu: ActionMenu

    static let width: CGFloat = 350
    static let maxListHeight: CGFloat = 260
    static let rowHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            title
            list
            Hairline()
            SearchField(text: Binding(get: { model.actionMenu?.query ?? "" }, set: { model.actionMenu?.query = $0 }),
                        placeholder: "搜索操作…", fontSize: 13, focusesOnAppear: true)
                .padding(.horizontal, 14)
                .frame(height: 38)
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var title: some View {
        HStack(spacing: 4) {
            if menu.isSubmenu {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(menu.level.title)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var list: some View {
        let actions = menu.visible
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if actions.isEmpty {
                        Text("没有匹配的操作")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.rowHeight)
                    }
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        // 搜索时排成一列，不画组之间的线。
                        if index > 0, menu.query.isEmpty, action.group != actions[index - 1].group {
                            Hairline()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        ActionRow(action: action, isHighlighted: index == menu.highlighted)
                            .id(action.id)
                            .onHover { if $0 { model.actionMenu?.hover(index) } }
                            .onTapGesture { model.perform?(action.command) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: min(listHeight(actions), Self.maxListHeight))
            .onChange(of: menu.highlighted) {
                if let action = model.actionMenu?.highlightedAction { proxy.scrollTo(action.id) }
            }
        }
    }

    /// 内容有多高：行高加组之间的线，空的时候一行字。
    private func listHeight(_ actions: [PanelAction]) -> CGFloat {
        guard !actions.isEmpty else { return Self.rowHeight + 6 }
        let separators = menu.query.isEmpty ? zip(actions, actions.dropFirst()).filter { $0.group != $1.group }.count : 0
        return CGFloat(actions.count) * Self.rowHeight + CGFloat(separators) * 9 + 6
    }
}

private struct ActionRow: View {
    let action: PanelAction
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)
            Text(action.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut = action.shortcut {
                HStack(spacing: 2) {
                    ForEach(Array(shortcut.enumerated()), id: \.offset) { Keycap(key: String($0.element)) }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(action.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: ActionPanel.rowHeight)
        .background(isHighlighted ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch action.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(action.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        case .image(let image):
            Image(nsImage: image)
                .resizable()
        }
    }
}

/// 打开时照 Raycast：从 0.97 倍、0.6 的透明度长出来（右下角不动），0.25 秒，最后略微冲过头；关时 0.15 秒淡出。
extension AnyTransition {
    static var actionPanel: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PopModifier(scale: 0.97, opacity: 0.6), identity: PopModifier(scale: 1, opacity: 1))
                .animation(.timingCurve(0.3, 0.7, 0, 1.26, duration: 0.25)),
            removal: .opacity.animation(.easeOut(duration: 0.15)))
    }
}

private struct PopModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .bottomTrailing)
            .opacity(opacity)
    }
}
