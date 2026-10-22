import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MochiCore

/// 把历史里的一条写回剪切板，需要时再替用户按一下 ⌘V。
@MainActor
final class Paster {
    enum Outcome {
        case written
        /// 文件条目里有的文件不在了；一个都不在时什么都没写。
        case missingFiles(missing: Int, total: Int)
        case failed
    }

    private let store: ClipStore
    private let pasteboard: NSPasteboard
    private let recorder: Recorder
    /// 跑调试脚本时不发 ⌘V：脚本写的是有名字的剪切板，发了会把用户剪切板上的东西粘进前台应用。
    var isQuiet = false
    private var hasPromptedForTrust = false

    init(store: ClipStore, pasteboard: NSPasteboard, recorder: Recorder) {
        self.store = store
        self.pasteboard = pasteboard
        self.recorder = recorder
    }

    #if DEBUG
    /// 调试脚本截「有权限」的样子用（`Drive` 的 trusted）。跑脚本时本来就不发 ⌘V。
    var pretendsTrusted = false
    #endif

    /// 发 ⌘V 要辅助功能权限。
    var canPaste: Bool {
        #if DEBUG
        if pretendsTrusted { return true }
        #endif
        return AXIsProcessTrusted()
    }

    /// 弹系统的授权提示（「Mochi 想要使用辅助功能控制这台电脑」，带去系统设置的按钮）。每次启动最多弹一次，不反复打扰。
    func requestPermissionOnce() {
        guard !hasPromptedForTrust, !isQuiet else { return }
        hasPromptedForTrust = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 写回剪切板。文本带上存下的 RTF、HTML、网址（`plainText` 时只写纯文本）；图片写 PNG；文件写文件 URL。
    /// 写完挪到历史最前，和再复制一遍一样。
    func write(_ clip: Clip, plainText: Bool = false) async -> Outcome {
        let item = NSPasteboardItem()
        var outcome = Outcome.written
        var urls: [URL] = []
        do {
            switch clip.kind {
            case .text:
                guard let text = try await store.text(of: clip.id) else { return .failed }
                item.setString(text, forType: .string)
                if !plainText {
                    for (type, data) in try await store.formats(of: clip.id) {
                        item.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                }
            case .image:
                guard let url = clip.imageURL else { return .failed }
                item.setData(try Data(contentsOf: url), forType: .png)
            case .file:
                urls = clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
                if urls.count < clip.fileURLs.count {
                    outcome = .missingFiles(missing: clip.fileURLs.count - urls.count, total: clip.fileURLs.count)
                }
                if urls.isEmpty { return outcome }
            }
        } catch {
            log.error("read clip for paste failed: \(error, privacy: .public)")
            return .failed
        }

        pasteboard.clearContents()
        let ok = urls.isEmpty ? pasteboard.writeObjects([item]) : pasteboard.writeObjects(urls as [NSURL])
        recorder.ignoreCurrentChange()
        guard ok else { return .failed }
        do {
            try await store.touch(id: clip.id)
        } catch {
            log.error("touch failed: \(error, privacy: .public)")
        }
        return outcome
    }

    /// 替用户按 ⌘V。面板收起以后前台应用本来就是激活的，等一下让键盘焦点回到它的窗口再发。
    func sendPasteKeystroke() async {
        guard !isQuiet else {
            print("paster: 不发 ⌘V（调试脚本）")
            return
        }
        try? await Task.sleep(for: .milliseconds(30))
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            // 明着设成只有 ⌘：用户这时可能还按着 ⇧（⇧↵ 粘贴纯文本），不能变成 ⇧⌘V。
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
