import AppKit
import SwiftUI

/// 搜索框。用 NSTextField 而不是 SwiftUI 的 TextField：呼出时要确定地把焦点给它，
/// 方向键、回车这些由 PanelController 先截下来，还要知道输入法是不是正在拼字。
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 18
    /// 建出来就拿键盘焦点（⌘K 操作面板的搜索框）。
    var focusesOnAppear = false

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        // 系统默认的占位字在毛玻璃上几乎和正文一样深，用和分组标题一样的第三级颜色。
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: fontSize),
        ])
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        if focusesOnAppear {
            // 这时还没放进窗口。
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
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
///
/// 这个视图建一次就一直留着，换条目只换文字（见 PreviewArea）。macOS 26 上 TextKit 2 的 NSTextView 销毁以后，
/// 排版用的子视图 `_NSTextViewportElementView` 被 AppKit 在 `-[NSView _commonAwake]` 里注册的通知 block 拿着不放，
/// 连带整套排版对象和全文都留下；文本、图片来回切换时每次新建一个，翻一会儿就是几十 MB。
/// 没换 TextKit 1：它不漏，可排长文本要多占好几 MB（10 万字的预览多 6 MB 左右）。
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

    /// 还是被销毁了（搜不到东西时右边整块撤掉）：先清空文字，漏下的只是几个空对象。
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? NSTextView)?.string = ""
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

/// 图片预览：图层直接显示 CGImage。
/// 不用 SwiftUI 的 Image：翻过几十张图以后收起面板，用 Image 时内存多留二三十 MB（两次对比：94 对 67 MB、109 对 81 MB）。
struct ImageLayer: NSViewRepresentable {
    let image: CGImage
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> ImageLayerView {
        let view = ImageLayerView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        view.layer?.minificationFilter = .trilinear
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: ImageLayerView, context: Context) {
        view.layer?.contents = image
    }
}

/// 有自己的类名，Quick Look 开关时按它找预览图在屏幕上的位置。
final class ImageLayerView: NSView {}

/// 按住拖动整个窗口。放在搜索栏的背景上：搜索框、按钮照常接点击，空白处能拖。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
