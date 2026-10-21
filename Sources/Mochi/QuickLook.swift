import AppKit
import Quartz

/// ⌘Y 的 Quick Look。用自己的浮动窗口装 QLPreviewView，不用系统的 QLPreviewPanel：
/// 那个面板要成为 key 窗口、要激活应用，面板一失焦就收起了，回车粘贴也会粘错地方。
/// 这个窗口不当 key，键盘一直在剪切板面板上，Esc、⌘Y 关掉它，上下键换一条它跟着换。
@MainActor
final class QuickLook {
    private let window: NSPanel
    private let preview: QLPreviewView
    /// 跑调试脚本时和面板一样压在桌面下面。
    var level: NSWindow.Level = .floating {
        didSet { window.level = NSWindow.Level(level.rawValue + 1) }
    }

    init() {
        window = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.autoresizingMask = [.width, .height]
        preview.shouldCloseWithWindow = false
        background.addSubview(preview)
        window.contentView = background
    }

    var isVisible: Bool { window.isVisible }
    var windowNumber: Int { window.windowNumber }

    /// 在 `over` 这个窗口所在的屏幕中间打开；已经开着就换内容。
    /// 给了 `imageSize`（像素）就按图片的比例开窗口，不留两条边；别的文件用固定的 900×640。
    func show(_ url: URL, imageSize: CGSize? = nil, over anchor: NSWindow) {
        preview.previewItem = url as NSURL
        let visible = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let limit = NSSize(width: min(900, visible.width * 0.8), height: min(640, visible.height * 0.8))
        var size = limit
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            let padding: CGFloat = 16
            let scale = min(1, (limit.width - padding) / imageSize.width, (limit.height - padding) / imageSize.height)
            size = NSSize(width: max(320, imageSize.width * scale + padding), height: max(240, imageSize.height * scale + padding))
        }
        window.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                               width: size.width.rounded(), height: size.height.rounded()), display: true)
        preview.frame = window.contentView?.bounds.insetBy(dx: 8, dy: 8) ?? .zero
        if !window.isVisible { window.orderFrontRegardless() }
        window.invalidateShadow()
    }

    func close() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        preview.previewItem = nil
    }
}

/// 点它也不当 key：键盘留在剪切板面板上，面板不会因为失焦收起。
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
