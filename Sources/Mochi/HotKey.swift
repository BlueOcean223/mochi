import Carbon.HIToolbox

/// 全局快捷键，用 Carbon 的 `RegisterEventHotKey`。
/// 不要辅助功能权限：系统只在这个组合按下时通知我们，别的按键看不到。
@MainActor
final class HotKey {
    private let ref: EventHotKeyRef
    private let id: UInt32

    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?
    private static let signature: OSType = 0x4D43_4849  // "MCHI"

    /// `keyCode` 是 `kVK_*`，`modifiers` 是 Carbon 的 `cmdKey`、`controlKey` 这些。组合已被别的应用占用时返回 nil。
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        Self.installHandler()
        let id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            return nil
        }
        self.ref = ref
        self.id = id
        Self.actions[id] = action
    }

    func unregister() {
        UnregisterEventHotKey(ref)
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon 的事件在主线程上派发。
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// 按设置注册的全局快捷键：呼出面板、按顺序粘贴。录新快捷键时先停掉，不然按下现在这个组合会直接触发；
/// 换成新的组合时注册不上就还用旧的。按顺序粘贴默认没有快捷键（nil）。
@MainActor
final class GlobalHotKey {
    private let load: () -> Shortcut?
    private let save: (Shortcut?) -> Void
    private let action: @MainActor () -> Void
    private var hotKey: HotKey?
    /// 跑调试脚本时不注册，免得和正在用的 Mochi 抢。
    var isQuiet = false
    /// 换了组合以后，菜单栏菜单里显示的快捷键跟着改。
    var changed: ((Shortcut?) -> Void)?

    init(load: @escaping () -> Shortcut?, save: @escaping (Shortcut?) -> Void, action: @escaping @MainActor () -> Void) {
        self.load = load
        self.save = save
        self.action = action
    }

    var shortcut: Shortcut? { load() }
    /// 没设快捷键也算生效。
    var isRegistered: Bool { isQuiet || shortcut == nil || hotKey != nil }

    @discardableResult
    func register() -> Bool {
        guard !isQuiet, hotKey == nil, let shortcut else { return isRegistered }
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: action)
        if hotKey == nil { log.error("hot key \(shortcut.description, privacy: .public) is taken") }
        return hotKey != nil
    }

    func suspend() {
        hotKey?.unregister()
        hotKey = nil
    }

    /// 换成 `new`；nil 是不要快捷键。
    func change(to new: Shortcut?) -> Bool {
        suspend()
        if !isQuiet, let new {
            guard let key = HotKey(keyCode: new.keyCode, modifiers: new.modifiers, action: action) else {
                register()
                return false
            }
            hotKey = key
        }
        save(new)
        changed?(new)
        return true
    }
}
