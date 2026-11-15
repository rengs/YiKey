import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey）：不需要“输入监控/辅助功能”权限。
@MainActor
final class HotKeyManager {
    var onTrigger: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { mgr.onTrigger?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x544D4531), id: 1)   // 'TME1'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
