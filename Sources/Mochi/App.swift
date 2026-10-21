import AppKit
import MochiCore
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.blueocean223.mochi", category: "app")

// 入口。不用 SwiftUI 的 App 和 storyboard，生命周期交给 AppKit：
// 面板、热键、菜单栏都要直接管 NSWindow / NSStatusItem，SwiftUI 只画面板里的内容。
@main
enum MochiApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var statusMenu: StatusMenu?
    private var recorder: Recorder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logPasteboardAccess()
        statusMenu = StatusMenu(settings: settings)
        let directory = dataDirectory()
        do {
            let store = try ClipStore(directory: directory)
            let recorder = Recorder(store: store, settings: settings, pasteboard: pasteboard())
            recorder.start()
            self.recorder = recorder
            log.notice("recording into \(directory.path, privacy: .public)")
        } catch {
            log.error("open store failed: \(error, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Mochi 打不开剪切板历史"
            alert.informativeText = "\(directory.path)\n\n\(error)"
            NSApp.activate()
            alert.runModal()
        }
    }
}

/// 数据放在 `~/Library/Application Support/<bundle id>/`。
/// 调试构建可以用 `MOCHI_DATA_DIR` 指到别处，测试时不碰真实的历史。
private func dataDirectory() -> URL {
    #if DEBUG
    if let path = ProcessInfo.processInfo.environment["MOCHI_DATA_DIR"] {
        return URL(filePath: path, directoryHint: .isDirectory)
    }
    #endif
    return URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "com.blueocean223.mochi", directoryHint: .isDirectory)
}

/// 调试构建可以用 `MOCHI_PASTEBOARD` 换成一个有名字的剪切板，测试时不动用户正在用的剪切板。
private func pasteboard() -> NSPasteboard {
    #if DEBUG
    if let name = ProcessInfo.processInfo.environment["MOCHI_PASTEBOARD"] {
        return NSPasteboard(name: NSPasteboard.Name(name))
    }
    #endif
    return .general
}

/// 记下系统给的剪切板权限。macOS 15.4 起苹果预告读剪切板会弹提示（tech-selection.md 第二节），
/// 是 ask 的话每次读都可能被系统拦下来问用户，记录就不可靠了。
private func logPasteboardAccess() {
    let name = switch NSPasteboard.general.accessBehavior {
    case .default: "default"
    case .ask: "ask"
    case .alwaysAllow: "alwaysAllow"
    case .alwaysDeny: "alwaysDeny"
    @unknown default: "unknown"
    }
    log.notice("pasteboard accessBehavior=\(name, privacy: .public)")
}
