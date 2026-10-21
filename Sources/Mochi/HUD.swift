import AppKit

/// 屏幕下方一闪而过的提示：「已复制」「没有辅助功能权限，按 ⌘V 粘贴」。不接鼠标，不抢焦点，1.5 秒后淡出。
@MainActor
final class HUD {
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()
    private var hideTask: Task<Void, Never>?
    /// 跑调试脚本时只打印，不上屏。
    var isQuiet = false

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        background.addSubview(label)
        window.contentView = background
    }

    func show(_ text: String) {
        guard !isQuiet else {
            print("hud: \(text)")
            return
        }
        label.stringValue = text
        label.sizeToFit()
        let height: CGFloat = 36
        let size = NSSize(width: min(label.frame.width + 36, 640), height: height)
        label.frame = NSRect(x: 18, y: (height - label.frame.height) / 2, width: size.width - 36, height: label.frame.height)
        background.maskImage = capsuleMask(height: height)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        window.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 80, width: size.width, height: size.height),
                        display: true)
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.invalidateShadow()

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            window.orderOut(nil)
        }
    }

    private func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let image = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: radius, bottom: 0, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
