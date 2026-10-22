import AppKit
import Quartz

/// ⌘Y 的 Quick Look。用自己的浮动窗口装 QLPreviewView，不用系统的 QLPreviewPanel：
/// 那个面板要成为 key 窗口、要激活应用，面板一失焦就收起了，回车粘贴也会粘错地方。
/// 这个窗口不当 key，键盘一直在剪切板面板上，Esc、⌘Y 关掉它，上下键换一条它跟着换。
///
/// 开关的动画照系统的 Quick Look（Raycast 用的是系统那个，给了起点位置和过渡用的图）：
/// 打开时图片从面板里预览图的位置放大到窗口里，窗口的底跟着淡入；关掉时缩回预览图的位置。
/// 没有预览图（文件列表、预览还没出来）时只淡入淡出。换一条时窗口大小也是渐变的。
@MainActor
final class QuickLook {
    /// 面板里预览图在屏幕上的位置和那张图：放大的起点、缩回的终点。
    struct Source {
        let frame: NSRect
        let image: CGImage
        let cornerRadius: CGFloat
    }

    private static var zoomDuration: TimeInterval { 0.26 * slowdown }
    private static var fadeDuration: TimeInterval { 0.16 * slowdown }
    private static var resizeDuration: TimeInterval { 0.2 * slowdown }
    /// 调试脚本把动画放慢，好一帧帧截图。
    static var slowdown: Double = 1
    /// 起步快、收尾慢。
    private static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    /// QLPreviewView 在窗口里四边留的空。
    private static let inset: CGFloat = 8

    private let window: NSPanel
    private let preview: QLPreviewView
    /// 放大、缩回时飞着的那张图。单独一个窗口，因为它要飞出 Quick Look 窗口的范围。
    private var flight: NSWindow?
    /// 当前这条图片的像素尺寸，算图片在窗口里的位置用。
    private var imageSize: CGSize?
    /// 每次开关加一。动画收尾时对不上号，说明中途又开关过，不再动窗口。
    private var generation = 0
    /// 开着，或者正在打开。关的动画还在放时已经是 false。
    private(set) var isVisible = false
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

        let background = NSVisualEffectView(frame: window.contentRect(forFrameRect: window.frame))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.frame = background.bounds.insetBy(dx: Self.inset, dy: Self.inset)
        preview.autoresizingMask = [.width, .height]
        preview.shouldCloseWithWindow = false
        background.addSubview(preview)
        window.contentView = background
    }

    var windowNumber: Int { window.windowNumber }

    /// 在 `over` 这个窗口所在的屏幕中间打开；已经开着就换内容，窗口渐变到新的大小。
    /// 给了 `imageSize`（像素）就按图片的比例开窗口，不留两条边；别的文件用固定的 900×640。
    /// 给了 `source` 就从那里放大。
    func show(_ url: URL, imageSize: CGSize? = nil, over anchor: NSWindow, from source: Source? = nil) {
        self.imageSize = imageSize
        let frame = frame(for: imageSize, over: anchor)
        preview.previewItem = url as NSURL
        generation += 1
        if isVisible {
            endFlight()
            preview.alphaValue = 1
            animate(duration: Self.resizeDuration) {
                self.window.animator().setFrame(frame, display: true)
                self.window.animator().alphaValue = 1
            }
            return
        }
        isVisible = true
        let current = generation
        endFlight()
        window.setFrame(frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.invalidateShadow()
        guard let source else {
            preview.alphaValue = 1
            animate(duration: Self.fadeDuration) { self.window.animator().alphaValue = 1 }
            return
        }
        // 飞的过程中窗口里的图先藏着，只淡入底；落地以后换成真的。
        preview.alphaValue = 0
        animate(duration: Self.zoomDuration) { self.window.animator().alphaValue = 1 }
        fly(source.image, from: (source.frame, source.cornerRadius), to: (imageFrame(in: frame), 0)) { [weak self] in
            guard let self, self.generation == current else { return }
            self.preview.alphaValue = 1
            // QLPreviewView 是异步出图的。飞来的图和它出的图在同一个位置，多留一会儿看不出来，免得它还没画好时闪一下。
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.generation == current else { return }
                self.endFlight()
            }
        }
    }

    /// 给了 `source` 就缩回那里，没给就淡出。`animated` 为 false 时直接消失（面板跟着收起的时候）。
    func close(to source: Source? = nil, animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        generation += 1
        let current = generation
        endFlight()
        guard animated else {
            finishClosing()
            return
        }
        if let source {
            preview.alphaValue = 0
            fly(source.image, from: (imageFrame(in: window.frame), 0), to: (source.frame, source.cornerRadius)) { [weak self] in
                guard let self, self.generation == current else { return }
                self.endFlight()
            }
        }
        animate(duration: source == nil ? Self.fadeDuration : Self.zoomDuration) {
            self.window.animator().alphaValue = 0
        } completion: { [weak self] in
            guard let self, self.generation == current else { return }
            self.finishClosing()
        }
    }

    private func finishClosing() {
        window.orderOut(nil)
        window.alphaValue = 1
        preview.alphaValue = 1
        preview.previewItem = nil
    }

    private func frame(for imageSize: CGSize?, over anchor: NSWindow) -> NSRect {
        let visible = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let limit = NSSize(width: min(900, visible.width * 0.8), height: min(640, visible.height * 0.8))
        var size = limit
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            let padding = Self.inset * 2
            let scale = min(1, (limit.width - padding) / imageSize.width, (limit.height - padding) / imageSize.height)
            size = NSSize(width: max(320, imageSize.width * scale + padding), height: max(240, imageSize.height * scale + padding))
        }
        return NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width.rounded(), height: size.height.rounded())
    }

    /// 图片在 Quick Look 窗口里显示的位置（屏幕坐标）：按比例放进留了边的区域，居中，不放大。
    private func imageFrame(in frame: NSRect) -> NSRect {
        let area = frame.insetBy(dx: Self.inset, dy: Self.inset)
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else { return area }
        let scale = min(1, area.width / imageSize.width, area.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 在 Quick Look 窗口上面开一个透明窗口，把图从 `from` 移到 `to`，圆角跟着变。
    private func fly(_ image: CGImage, from start: (frame: NSRect, radius: CGFloat), to end: (frame: NSRect, radius: CGFloat),
                     completion: @escaping @MainActor () -> Void) {
        let area = start.frame.union(end.frame).insetBy(dx: -2, dy: -2).integral
        let flight = NonKeyPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        flight.isOpaque = false
        flight.backgroundColor = .clear
        flight.hasShadow = false
        flight.ignoresMouseEvents = true
        flight.isReleasedWhenClosed = false
        flight.animationBehavior = .none
        flight.level = window.level
        flight.collectionBehavior = window.collectionBehavior
        let view = NSView(frame: NSRect(origin: .zero, size: area.size))
        view.wantsLayer = true
        flight.contentView = view

        let local = { (rect: NSRect) in rect.offsetBy(dx: -area.minX, dy: -area.minY) }
        let from = local(start.frame), to = local(end.frame)
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = to
        layer.cornerRadius = end.radius
        view.layer?.addSublayer(layer)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let changes: [(String, Any, Any)] = [
            ("position", NSValue(point: NSPoint(x: from.midX, y: from.midY)), NSValue(point: NSPoint(x: to.midX, y: to.midY))),
            ("bounds.size", NSValue(size: from.size), NSValue(size: to.size)),
            ("cornerRadius", start.radius, end.radius),
        ]
        for (keyPath, fromValue, toValue) in changes {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = Self.zoomDuration
            animation.timingFunction = Self.timing
            layer.add(animation, forKey: keyPath)
        }
        CATransaction.commit()
        flight.orderFrontRegardless()
        self.flight = flight
    }

    private func endFlight() {
        flight?.orderOut(nil)
        flight = nil
    }

    private func animate(duration: TimeInterval, _ changes: @escaping () -> Void, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Self.timing
            changes()
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}

/// 点它也不当 key：键盘留在剪切板面板上，面板不会因为失焦收起。
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
