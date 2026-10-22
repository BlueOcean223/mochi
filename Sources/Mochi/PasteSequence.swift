import AppKit
import MochiCore

/// 按顺序粘贴（Raycast 的 Paste Sequentially）：每按一次全局快捷键，把下一条更早的记录粘贴到前台应用。
/// 从最新的一条不置顶的开始。粘贴过的不挪到最前，所以顺序不会被自己打乱。
/// 剪切板被别的复制改过（包括在面板里粘贴、复制），或者隔了 60 秒没按，下一次从最新的一条重新开始。
@MainActor
final class PasteSequence {
    /// Raycast 的 Sequence Timeout 默认 60 秒（可选 30 秒、1 分钟、3 分钟），这里固定 60 秒。
    static let timeout: TimeInterval = 60
    /// 两次按得比这还近时丢掉后一次：按住不放的自动重复会连着粘出好多条（Tinycast 也这么做）。
    static let minimumInterval: TimeInterval = 0.25

    private let store: ClipStore
    private let settings: Settings
    private let paster: Paster
    private let pasteboard: NSPasteboard
    private let hud: HUD
    /// 上一次粘贴的那条。
    private var lastID: Int64?
    private var lastPress = Date.distantPast
    /// 上一次写完以后剪切板的 changeCount。下次按时对不上，说明中间有别的复制。
    private var writtenChangeCount: Int?
    private var isPasting = false

    init(store: ClipStore, settings: Settings, paster: Paster, pasteboard: NSPasteboard, hud: HUD) {
        self.store = store
        self.settings = settings
        self.paster = paster
        self.pasteboard = pasteboard
        self.hud = hud
    }

    func pasteNext() {
        let now = Date.now
        guard !isPasting, now.timeIntervalSince(lastPress) >= Self.minimumInterval else { return }
        guard paster.canPaste else {
            paster.requestPermissionOnce()
            hud.show("按顺序粘贴要辅助功能权限")
            return
        }
        if now.timeIntervalSince(lastPress) > Self.timeout || pasteboard.changeCount != writtenChangeCount {
            lastID = nil
        }
        lastPress = now
        isPasting = true
        Task {
            defer { isPasting = false }
            await paste()
        }
    }

    private func paste() async {
        let clip: Clip?
        do {
            clip = try await store.unpinnedClip(before: lastID)
        } catch {
            log.error("sequence read failed: \(error, privacy: .public)")
            return
        }
        guard let clip else {
            hud.show(lastID == nil ? "还没有记录" : "没有更早的了")
            return
        }
        let outcome = await paster.write(clip, newline: settings.sequenceAddsNewline, touches: false)
        writtenChangeCount = pasteboard.changeCount
        lastID = clip.id
        switch outcome {
        case .failed:
            hud.show("没能写进剪切板")
        case .missingFiles(let missing, let total) where missing == total:
            // 这条跳过，再按一下是下一条。
            hud.show(total == 1 ? "文件已经不在了" : "这些文件都已经不在了")
        case .missingFiles(let missing, _):
            await paster.sendPasteKeystroke()
            hud.show("有 \(missing) 个文件已经不在了")
        case .written:
            // 用户这时多半还按着快捷键里的修饰键；sendPasteKeystroke 把修饰键明着设成只有 ⌘。
            await paster.sendPasteKeystroke()
        }
    }
}
