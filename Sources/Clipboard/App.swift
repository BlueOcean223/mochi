import AppKit
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.blueocean223.clipboard", category: "app")

// 入口。不用 SwiftUI 的 App 和 storyboard，生命周期交给 AppKit：
// 面板、热键、菜单栏都要直接管 NSWindow / NSStatusItem，SwiftUI 只画面板里的内容。
@main
enum ClipboardApp {
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
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu()
        logPasteboardAccess()
    }
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
