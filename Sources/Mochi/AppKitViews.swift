import AppKit
import SwiftUI

/// 搜索框。用 NSTextField 而不是 SwiftUI 的 TextField：呼出时要确定地把焦点给它，
/// 方向键、回车这些由 PanelController 先截下来，还要知道输入法是不是正在拼字。
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        // 系统默认的占位字在毛玻璃上几乎和正文一样深，用和分组标题一样的第三级颜色。
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 18),
        ])
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // 拼音还没选字时不搜，选完字会再来一次。
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// 文本预览。长文本用 NSTextView 排，SwiftUI 的 Text 排几万字会卡。不能选中，焦点一直留在搜索框。
struct TextPreview: NSViewRepresentable {
    let text: String
    let monospaced: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = false
            textView.isRichText = false
            textView.drawsBackground = false
            // 文本容器左右还有 5 点的 lineFragmentPadding，加起来左右各 18。
            textView.textContainerInset = NSSize(width: 13, height: 14)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.text != text || context.coordinator.monospaced != monospaced,
              let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = text
        context.coordinator.monospaced = monospaced
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = monospaced ? 3 : 4
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]))
        textView.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var text: String?
        var monospaced = false
    }
}
