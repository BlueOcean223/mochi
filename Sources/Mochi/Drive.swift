#if DEBUG
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import MochiCore
import UniformTypeIdentifiers

/// 调试构建里按脚本操作面板、截图，不碰真实的鼠标键盘、不抢用户的键盘（notes/dev-env.md「测界面」）。
///
/// `MOCHI_DRIVE=脚本 MOCHI_SHOTS=截图目录 MOCHI_SEED=1 build/Mochi.app/Contents/MacOS/Mochi`
/// 要从终端直接跑二进制：截图用的 `screencapture` 记在终端的屏幕录制权限上。`.agent/tools/shots/shots.sh` 是这么跑的。
///
/// 一行一条，`#` 后面是注释：
///
///     show                    呼出面板（放在屏幕外面，不是 key 窗口）
///     hide
///     key down                按键，走和真实按键一样的 PanelController.handleKey：
///                             down up cmd-down cmd-up enter cmd-enter shift-enter esc cmd-p
///                             cmd-dot ctrl-x ctrl-shift-x cmd-y cmd-o shift-cmd-f
///     clipboard               打印剪切板（`MOCHI_PASTEBOARD` 那个）上的类型和文字
///     type 关键词             把搜索框改成这个（空着就是清空）
///     select 关键词           选中标题里有这个词的第一条（假数据的时间跟着当前时间走，按位置找不稳）
///     appearance dark|light
///     wait 300                毫秒
///     shot 名字               截面板，存成 截图目录/名字.png。宿主终端有屏幕录制权限时用 screencapture 截真窗口，
///                             没有时在应用里画（画不出毛玻璃、vibrancy）
///     shot-quicklook 名字     截 Quick Look 窗口（只能用 screencapture）
///     quit
@MainActor
final class Drive {
    private let lines: [String]
    private let panel: PanelController
    private let pasteboard: NSPasteboard
    private let shots: URL

    init?(panel: PanelController, pasteboard: NSPasteboard) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MOCHI_DRIVE"], let script = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        lines = script.split(whereSeparator: \.isNewline).map(String.init)
        self.panel = panel
        self.pasteboard = pasteboard
        shots = URL(filePath: environment["MOCHI_SHOTS"] ?? "/tmp/mochi-shots", directoryHint: .isDirectory)
        panel.isQuiet = true
    }

    func run() async {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        for raw in lines {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            print("drive: \(line)")
            switch command {
            case "show": panel.show()
            case "hide": panel.hide()
            case "key": key(argument)
            case "type": panel.model.setQuery(argument)
            case "clipboard":
                let types = pasteboard.types?.map(\.rawValue) ?? []
                print("drive: clipboard types=\(types) string=\(pasteboard.string(forType: .string) ?? "nil")")
            case "appearance": NSApp.appearance = NSAppearance(named: argument == "light" ? .aqua : .darkAqua)
            case "wait": try? await Task.sleep(for: .milliseconds(Int(argument) ?? 0))
            case "select":
                if let clip = panel.model.clips.first(where: { $0.title.contains(argument) }) {
                    panel.model.select(clip.id)
                } else {
                    print("drive: 没有标题里有「\(argument)」的")
                }
            case "shot":
                if CGPreflightScreenCaptureAccess() {
                    await capture(window: panel.windowNumber, name: argument)
                } else {
                    await shot(argument)
                }
            case "shot-quicklook": await capture(window: panel.quickLookWindowNumber, name: argument)
            case "quit": NSApp.terminate(nil)
            default: print("drive: 不认识的命令 \(command)")
            }
            // 等 SwiftUI 画完、异步读库回来。
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func key(_ name: String) {
        let keys: [String: (Int, NSEvent.ModifierFlags)] = [
            "down": (kVK_DownArrow, []), "up": (kVK_UpArrow, []),
            "cmd-down": (kVK_DownArrow, .command), "cmd-up": (kVK_UpArrow, .command),
            "enter": (kVK_Return, []), "cmd-enter": (kVK_Return, .command),
            "shift-enter": (kVK_Return, .shift), "esc": (kVK_Escape, []), "cmd-p": (kVK_ANSI_P, .command),
            "cmd-dot": (kVK_ANSI_Period, .command), "ctrl-x": (kVK_ANSI_X, .control),
            "ctrl-shift-x": (kVK_ANSI_X, [.control, .shift]), "cmd-y": (kVK_ANSI_Y, .command),
            "cmd-o": (kVK_ANSI_O, .command), "shift-cmd-f": (kVK_ANSI_F, [.command, .shift]),
        ]
        guard let (code, modifiers) = keys[name],
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) else {
            print("drive: 不认识的键 \(name)")
            return
        }
        if !panel.handleKey(event) { print("drive: \(name) 没被面板处理") }
    }

    private func capture(window: Int, name: String) async {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window)", shots.appending(path: "\(name).png").path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print(process.terminationStatus == 0 ? "drive: shot \(name).png" : "drive: screencapture 失败：\(message)")
        } catch {
            print("drive: screencapture 跑不起来：\(error)")
        }
    }

    /// 在应用里把面板的视图画成 PNG（二倍）。不用 screencapture：它要宿主终端有屏幕录制权限。
    /// 毛玻璃画不出来，底色用一块接近的纯色代替；列表、文字、图标、间距和真的一样。
    private func shot(_ name: String) async {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.setFillColor(dark ? CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1) : CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.addPath(CGPath(roundedRect: view.bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil))
        context.fillPath()
        if let image = rep.cgImage { context.draw(image, in: view.bounds) }
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(shots.appending(path: "\(name).png") as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, output, nil)
        print(CGImageDestinationFinalize(destination) ? "drive: shot \(name).png" : "drive: 写不出 \(name).png")
    }
}

/// 截图用的假数据：`MOCHI_SEED=1` 并且库是空的时候写进去。
enum Fixtures {
    static func seedIfRequested(_ store: ClipStore) async {
        guard ProcessInfo.processInfo.environment["MOCHI_SEED"] != nil else { return }
        do {
            guard try await store.count() == 0 else { return }
            try await seed(store)
        } catch {
            print("seed failed: \(error)")
        }
    }

    private static func seed(_ store: ClipStore) async throws {
        let now = Date.now
        let minute: TimeInterval = 60
        let day: TimeInterval = 86_400
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser
        typealias T = PasteboardTypes

        func text(_ string: String) -> [PasteboardSnapshot.Item] {
            [.init(types: [T.plainText], data: [T.plainText: Data(string.utf8)])]
        }
        func files(_ urls: [URL]) -> [PasteboardSnapshot.Item] {
            urls.map { .init(types: [T.fileURL], data: [T.fileURL: Data($0.absoluteString.utf8)]) }
        }
        func image(_ data: Data) -> [PasteboardSnapshot.Item] {
            [.init(types: [T.png], data: [T.png: data])]
        }

        // 从旧到新写，后写的在上面。
        let entries: [(items: [PasteboardSnapshot.Item], app: (String, String), ago: TimeInterval, pinned: Bool)] = [
            (text("https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast"), ("com.apple.Safari", "Safari"), 15 * day, false),
            (text("收到，谢谢！"), ("com.tencent.xinWeChat", "微信"), 9 * day, false),
            (text("/usr/bin/log show --last 1m --predicate 'subsystem == \"com.blueocean223.mochi\"' --style compact"),
             ("com.mitchellh.ghostty", "Ghostty"), 4 * day, false),
            (files([home.appending(path: "Documents/季度报告.pdf")]), ("com.apple.finder", "访达"), 3 * day, false),
            (text("#FF6363"), ("com.microsoft.VSCode", "Code"), 1 * day + 6 * 60 * minute, false),
            (image(try picture(width: 1200, height: 800, colors: [(0.96, 0.70, 0.48), (0.91, 0.46, 0.42), (0.36, 0.29, 0.48)])),
             ("com.google.Chrome", "Google Chrome"), 1 * day + 4 * 60 * minute, false),
            (text(String(repeating: """
                SwiftUI List on macOS 26 loads 100,000 rows six times faster and updates sixteen times faster than before. \
                苹果说 macOS 26 上的 SwiftUI List 加载 10 万行快了 6 倍。剪切板只显示最近几百条，分页从 SQLite 读，够用了。\n\n
                """, count: 6)), ("com.apple.Safari", "Safari"), 1 * day + 2 * 60 * minute, false),
            (text("Mochi 是一个只做剪切板的小工具：按 ⌃⌘V 呼出，回车粘贴到前台应用。"), ("abnerworks.Typora", "Typora"), 5 * 60 * minute, false),
            (text("明天下午三点开会，记得把上周的数据带上 🙏"), ("com.tencent.xinWeChat", "微信"), 160 * minute, false),
            (files([repo.appending(path: "Package.swift"), repo.appending(path: "scripts/bundle.sh")]), ("com.apple.finder", "访达"), 64 * minute, false),
            (text("https://github.com/p0deje/Maccy/pull/1552"), ("com.google.Chrome", "Google Chrome"), 26 * minute, false),
            (text("""
                @discardableResult
                public func record(_ snapshot: PasteboardSnapshot) throws -> RecordResult {
                    switch Classifier.classify(snapshot) {
                    case .skip(let reason): .skipped(reason)
                    case .capture(let capture): try add(capture)
                    }
                }
                """), ("com.microsoft.VSCode", "Code"), 9 * minute, false),
            (image(try picture(width: 1920, height: 1080, colors: [(0.15, 0.20, 0.31), (0.35, 0.24, 0.36), (0.79, 0.39, 0.26)])),
             ("com.depthpicture.PixPin", "PixPin"), 3 * minute, false),
            (text("周报模板\n1. 本周完成：\n2. 下周计划：\n3. 风险和需要的支持："), ("com.electron.lark", "飞书"), 12 * day, true),
            (text("ssh -i ~/.ssh/id_ed25519 deploy@10.0.3.12 -p 2222"), ("com.mitchellh.ghostty", "Ghostty"), 5 * day, true),
        ]
        for entry in entries {
            let snapshot = PasteboardSnapshot(items: entry.items, sourceBundleID: entry.app.0, sourceName: entry.app.1,
                                              date: now - entry.ago)
            let result = try await store.record(snapshot)
            if entry.pinned, case .inserted(let id) = result {
                try await store.setPinned(true, id: id)
            }
        }
        print("seed: \(try await store.count()) clips")
    }

    /// 一张渐变底、上面几块色块的 PNG。
    private static func picture(width: Int, height: Int, colors: [(CGFloat, CGFloat, CGFloat)]) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: colors.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray,
                                        locations: nil) else { throw CocoaError(.featureUnsupported) }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 0.9))
        context.fill(CGRect(x: w * 0.1, y: h * 0.12, width: w * 0.8, height: h * 0.76))
        context.setFillColor(CGColor(red: 0.79, green: 0.39, blue: 0.26, alpha: 1))
        context.fill(CGRect(x: w * 0.14, y: h * 0.18, width: w * 0.34, height: h * 0.34))
        context.setFillColor(CGColor(red: 0.24, green: 0.44, blue: 0.71, alpha: 1))
        context.fill(CGRect(x: w * 0.52, y: h * 0.18, width: w * 0.34, height: h * 0.34))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        for row in 0..<3 {
            context.fill(CGRect(x: w * 0.14, y: h * (0.62 + 0.06 * CGFloat(row)), width: w * (0.5 - 0.08 * CGFloat(row)), height: h * 0.025))
        }
        guard let cgImage = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.featureUnsupported) }
        return data as Data
    }
}
#endif
