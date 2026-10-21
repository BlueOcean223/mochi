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
