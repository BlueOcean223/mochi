#if DEBUG
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import MochiCore
import SwiftUI
import UniformTypeIdentifiers

/// 调试构建里按脚本操作面板、截图，不碰真实的鼠标键盘、不抢用户的键盘。
///
/// `MOCHI_DRIVE=脚本 MOCHI_SHOTS=截图目录 MOCHI_SEED=1 build/Mochi.app/Contents/MacOS/Mochi`
/// 要从终端直接跑二进制：截图用的 `screencapture` 记在终端的屏幕录制权限上。`.agent/tools/shots/shots.sh` 是这么跑的。
///
/// 一行一条，`#` 后面是注释：
///
///     show                    呼出面板（放在屏幕外面，不是 key 窗口）
///     hide
///     key down                按键，走和真实按键一样的 PanelController.handleKey。写法是修饰键（ctrl alt shift cmd）
///                             加键名，比如 cmd-down、ctrl-shift-x、cmd-dot、cmd-comma；键名有字母、数字、f1–f12、
///                             up down left right enter esc space tab dot comma
///     clipboard               打印剪切板（`MOCHI_PASTEBOARD` 那个）上的类型和文字
///     type 关键词             把搜索框改成这个（空着就是清空）
///     select 关键词           选中标题里有这个词的第一条（假数据的时间跟着当前时间走，按位置找不稳）
///     appearance dark|light
///     wait 300                毫秒
///     shot 名字               截面板，存成 截图目录/名字.png。宿主终端有屏幕录制权限时用 screencapture 截真窗口，
///                             没有时在应用里画（画不出毛玻璃、vibrancy）
///     shot-quicklook 名字     截 Quick Look 窗口（只能用 screencapture）
///     backdrop 60             在面板后面垫一块灰（0–255），看毛玻璃背后是深色窗口时的样子；backdrop 不带参数是拿掉
///     tint 0.7                浅色外观下毛玻璃上那层白的浓度（试样子用）
///     shot-backdrop 名字      把面板连同 backdrop 一起截（ScreenCaptureKit，只合成这两个窗口），毛玻璃透出背后那块灰
///     trusted                 当作有辅助功能权限（底栏、设置里显示有权限的样子；照样不发 ⌘V）
///     settings                打开设置窗口（也压在桌面下面）
///     settings-close
///     record                  开始录呼出快捷键
///     press ctrl-alt-k        录快捷键时按键，写法同 key；只写修饰键（ctrl-cmd）是按住修饰键。加应用的弹层开着时给弹层
///     pick                    点「忽略的应用」的 +。弹层（NSPopover）压不到桌面下面，脚本里把弹层的内容放进一个压在桌面下的窗口
///     pick-type 微            在弹层的搜索框里打字
///     shot-picker 名字        截弹层
///     hover bundle-id         鼠标停在这个忽略的应用上（出现移除按钮）；hover 不带参数是移开
///     retention 7d            选保留时长：1h、1d、7d、30d、90d、365d，0 是永久；要删记录时会弹确认
///     retention-confirm       确认框里点「删掉」；retention-cancel 点「取消」
///     ignore /路径/某个.app    加进忽略的应用；unignore bundle-id 移除
///     login on|off            开机启动开关（不真的改登录项）
///     shot-settings 名字      截设置窗口；有确认框时另存一张 名字-sheet.png
///     quit
@MainActor
final class Drive {
    private let lines: [String]
    private let panel: PanelController
    private let settingsWindow: SettingsWindowController
    private let paster: Paster
    private let pasteboard: NSPasteboard
    private let shots: URL
    private var pickerWindow: NSWindow?
    private var backdropWindow: NSWindow?

    nonisolated static var isRequested: Bool { ProcessInfo.processInfo.environment["MOCHI_DRIVE"] != nil }

    init?(panel: PanelController, settingsWindow: SettingsWindowController, paster: Paster, pasteboard: NSPasteboard) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MOCHI_DRIVE"], let script = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        lines = script.split(whereSeparator: \.isNewline).map(String.init)
        self.panel = panel
        self.settingsWindow = settingsWindow
        self.paster = paster
        self.pasteboard = pasteboard
        shots = URL(filePath: environment["MOCHI_SHOTS"] ?? "/tmp/mochi-shots", directoryHint: .isDirectory)
        panel.isQuiet = true
        settingsWindow.isQuiet = true
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
            case "trusted": paster.pretendsTrusted = true
            case "backdrop": setBackdrop(Int(argument))
            case "tint": panel.lightTint = CGFloat(Double(argument) ?? 0.7)
            case "shot-backdrop": await captureWithBackdrop(name: argument)
            case "settings": settingsWindow.show()
            case "settings-close": settingsWindow.close()
            case "record": settings.startRecording()
            case "press":
                if let event = event(argument, window: settingsWindow.windowNumber ?? 0) {
                    if settings.isRecording {
                        settings.handleRecording(event)
                    } else if settings.isPickingApp {
                        if !settings.handlePickerKey(event) { print("drive: \(argument) 弹层不处理") }
                    } else {
                        print("drive: 没在录快捷键，弹层也没开")
                    }
                }
            case "pick":
                settings.openAppPicker()
                showPicker()
            case "pick-type": settings.pickerQuery = argument
            case "shot-picker":
                if let window = pickerWindow { await capture(window: window.windowNumber, name: argument) }
            case "hover": settings.hoveredApp = argument.isEmpty ? nil : argument
            case "retention":
                let hours = argument.hasSuffix("h") ? Int(argument.dropLast()) : argument.hasSuffix("d") ? Int(argument.dropLast()).map { $0 * 24 } : Int(argument)
                if let retention = Retention(rawValue: hours ?? -1) {
                    settings.chooseRetention(retention)
                } else {
                    print("drive: 没有这一档保留时长 \(argument)")
                }
            case "retention-confirm": settings.confirmRetentionChange()
            case "retention-cancel": settings.retentionChange = nil
            case "ignore": settings.ignoreApps(at: [URL(filePath: argument)])
            case "unignore": settings.stopIgnoring(argument)
            case "login": settings.setLaunchAtLogin(argument == "on")
            case "shot-settings":
                if let window = settingsWindow.windowNumber { await capture(window: window, name: argument) }
                // 确认框是另一个窗口，弹出来要一会儿。
                try? await Task.sleep(for: .milliseconds(300))
                if let sheet = settingsWindow.sheetWindowNumber { await capture(window: sheet, name: "\(argument)-sheet") }
            case "quit": NSApp.terminate(nil)
            default: print("drive: 不认识的命令 \(command)")
            }
            // 等 SwiftUI 画完、异步读库回来。
            try? await Task.sleep(for: .milliseconds(250))
            if !settings.isPickingApp, let window = pickerWindow {
                window.orderOut(nil)
                pickerWindow = nil
            }
        }
    }

    private var settings: SettingsModel { settingsWindow.model }

    /// 只合成面板和垫在后面的那块灰，别的窗口、桌面都不进图。
    private func captureWithBackdrop(name: String) async {
        guard let backdrop = backdropWindow else { print("drive: 先 backdrop"); return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ids: Set<CGWindowID> = [CGWindowID(panel.windowNumber), CGWindowID(backdrop.windowNumber)]
            let windows = content.windows.filter { ids.contains($0.windowID) }
            guard windows.count == 2, let display = content.displays.first(where: { $0.frame.intersects(panel.frame) }) ?? content.displays.first else {
                print("drive: 找不到窗口 \(windows.count)")
                return
            }
            let filter = SCContentFilter(display: display, including: windows)
            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            // 只截面板那一块：sourceRect 是显示器坐标（左上角原点）。
            let screenHeight = display.frame.height
            let rect = CGRect(x: panel.frame.minX - display.frame.minX, y: screenHeight - panel.frame.maxY,
                              width: panel.frame.width, height: panel.frame.height)
            config.sourceRect = rect
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let destination = CGImageDestinationCreateWithURL(shots.appending(path: "\(name).png") as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            print(CGImageDestinationFinalize(destination) ? "drive: shot \(name).png" : "drive: 写不出 \(name).png")
        } catch {
            print("drive: ScreenCaptureKit 失败：\(error)")
        }
    }

    /// 面板背后垫一块纯灰的窗口，比面板再低一层，也压在桌面下面。毛玻璃会把它透出来。
    private func setBackdrop(_ gray: Int?) {
        backdropWindow?.orderOut(nil)
        backdropWindow = nil
        guard let gray else { return }
        let frame = panel.frame.insetBy(dx: -60, dy: -60)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 2)
        window.ignoresMouseEvents = true
        let value = CGFloat(gray) / 255
        window.backgroundColor = NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        window.orderFrontRegardless()
        backdropWindow = window
    }

    /// 弹层的内容放进一个和弹层一样的毛玻璃圆角窗口，压在桌面下面，摆在设置窗口右边。
    private func showPicker() {
        let size = NSSize(width: 360, height: 320)
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedRectMask(radius: 16)
        let hosting = NSHostingView(rootView: AppPicker(model: settings))
        hosting.frame = effect.bounds
        effect.addSubview(hosting)
        window.contentView = effect
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(NSPoint(x: screen.midX + 260, y: screen.midY - size.height / 2))
        window.orderFrontRegardless()
        pickerWindow = window
    }

    private func key(_ name: String) {
        guard let event = event(name, window: panel.windowNumber) else { return }
        if !panel.handleKey(event) { print("drive: \(name) 没被面板处理") }
    }

    /// 「ctrl-shift-x」：前面是修饰键，最后是键名。只有修饰键时是一个 flagsChanged（按住修饰键）。
    private func event(_ name: String, window: Int) -> NSEvent? {
        let modifierNames: [String: NSEvent.ModifierFlags] = ["ctrl": .control, "alt": .option, "shift": .shift, "cmd": .command]
        var parts = name.split(separator: "-").map(String.init)
        var modifiers: NSEvent.ModifierFlags = []
        while let first = parts.first, let flag = modifierNames[first] {
            modifiers.insert(flag)
            parts.removeFirst()
        }
        let type: NSEvent.EventType = parts.isEmpty ? .flagsChanged : .keyDown
        guard parts.count <= 1, let code = parts.isEmpty ? 0 : Self.keyCodes[parts[0]],
              let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) else {
            print("drive: 不认识的键 \(name)")
            return nil
        }
        return event
    }

    private static let keyCodes: [String: Int] = {
        var codes = [
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "enter": kVK_Return, "esc": kVK_Escape, "space": kVK_Space, "tab": kVK_Tab,
            "dot": kVK_ANSI_Period, "comma": kVK_ANSI_Comma,
        ]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
                       kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                       kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letters) { codes[String(letter)] = code }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in digits.enumerated() { codes[String(digit)] = code }
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functions.enumerated() { codes["f\(index + 1)"] = code }
        return codes
    }()

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
