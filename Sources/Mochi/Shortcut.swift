import AppKit
import Carbon.HIToolbox

/// 一个快捷键组合：键码（`kVK_*`）加 Carbon 的修饰键（`cmdKey`、`controlKey` 这些），和 `RegisterEventHotKey` 要的一样。
struct Shortcut: Equatable {
    let keyCode: Int
    let modifiers: Int

    static let standard = Shortcut(keyCode: kVK_ANSI_V, modifiers: controlKey | cmdKey)

    /// 只留 ⌃⌥⇧⌘，大小写锁定、fn 这些不算。
    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (controlKey | optionKey | shiftKey | cmdKey)
    }

    init(_ event: NSEvent) {
        self.init(keyCode: Int(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags))
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return result
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: - 能不能用

    /// 不带 ⌃⌥⌘ 的组合会吞掉打字（⇧ 加字母就是大写字母），只有 F 键可以单按。
    var leavesTypingAlone: Bool {
        modifiers & (controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(keyCode)
    }

    /// 系统快捷键（系统设置 › 键盘 › 键盘快捷键里开着的）在用这个组合：系统先拿走，注册了也收不到。
    /// 别的应用注册的查不到：`RegisterEventHotKey` 不拦两个应用注册同一个组合（10-22 试过）。
    var isTakenBySystem: Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            entry[kHISymbolicHotKeyEnabled as String] as? Bool == true
                && entry[kHISymbolicHotKeyCode as String] as? Int == keyCode
                && Shortcut(keyCode: keyCode, modifiers: entry[kHISymbolicHotKeyModifiers as String] as? Int ?? 0) == self
        }
    }

    // MARK: - 显示

    /// 修饰键的顺序和系统菜单一样：⌃⌥⇧⌘。
    var description: String { keys.joined() }

    /// 一个键一项，设置窗口里画成一个个键帽。
    var keys: [String] { Self.symbols(modifiers) + [keyName] }

    static func symbols(_ modifiers: Int) -> [String] {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1)
    }

    /// 字母、数字、符号键按当前键盘布局翻成字符（法语键盘上 kVK_ANSI_Q 那个键是 A），别的键查表。
    var keyName: String {
        if let special = Self.specialKeys[keyCode] { return special.name }
        return character?.uppercased() ?? "键 \(keyCode)"
    }

    /// 菜单项后面显示的快捷键（`NSMenuItem.keyEquivalent`）。
    var menuKeyEquivalent: String {
        if let special = Self.specialKeys[keyCode] { return String(Character(UnicodeScalar(UInt16(special.menu)) ?? " ")) }
        return character?.lowercased() ?? ""
    }

    private var character: String? {
        // 用 ASCII 键盘布局：当前输入法是拼音时，当前输入源没有键盘布局数据。
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { buffer in
            UCKeyTranslate(buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                           &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : string
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// 键名和菜单用的字符。
    private static let specialKeys: [Int: (name: String, menu: Int)] = {
        var keys: [Int: (name: String, menu: Int)] = [
            kVK_Return: ("↩", 0x0D), kVK_ANSI_KeypadEnter: ("⌤", 0x03), kVK_Tab: ("⇥", 0x09), kVK_Space: ("空格", 0x20),
            kVK_Delete: ("⌫", 0x08), kVK_ForwardDelete: ("⌦", NSDeleteFunctionKey), kVK_Escape: ("⎋", 0x1B),
            kVK_Home: ("↖", NSHomeFunctionKey), kVK_End: ("↘", NSEndFunctionKey),
            kVK_PageUp: ("⇞", NSPageUpFunctionKey), kVK_PageDown: ("⇟", NSPageDownFunctionKey),
            kVK_LeftArrow: ("←", NSLeftArrowFunctionKey), kVK_RightArrow: ("→", NSRightArrowFunctionKey),
            kVK_UpArrow: ("↑", NSUpArrowFunctionKey), kVK_DownArrow: ("↓", NSDownArrowFunctionKey),
        ]
        for (index, code) in functionKeys.enumerated() {
            keys[code] = ("F\(index + 1)", NSF1FunctionKey + index)
        }
        return keys
    }()
}
