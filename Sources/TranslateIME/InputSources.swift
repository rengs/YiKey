import AppKit
import Carbon
import IMECore

/// 真实的系统输入源（Text Input Sources）。
/// 只读取当前/已启用的输入源，只对**已启用且可选择**的输入源调用 TISSelectInputSource；
/// 不调用 TISEnableInputSource / TISRegisterInputSource，不改任何系统设置。
@MainActor
final class TISInputSourceSystem: InputSourceSystem {
    func currentSourceID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.string(src, kTISPropertyInputSourceID)
    }

    func enabledSources() -> [InputSourceInfo] {
        enabledTISSources().compactMap(Self.info)
    }

    @discardableResult
    func select(id: String) -> Bool {
        guard let src = enabledTISSources().first(where: { Self.string($0, kTISPropertyInputSourceID) == id }),
              Self.bool(src, kTISPropertyInputSourceIsSelectCapable) else { return false }
        return TISSelectInputSource(src) == noErr
    }

    private func enabledTISSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list
    }

    private static func info(_ src: TISInputSource) -> InputSourceInfo? {
        guard let id = string(src, kTISPropertyInputSourceID) else { return nil }
        return InputSourceInfo(id: id,
                               localizedName: string(src, kTISPropertyLocalizedName) ?? "",
                               languages: strings(src, kTISPropertyInputSourceLanguages),
                               isEnabled: bool(src, kTISPropertyInputSourceIsEnabled),
                               isSelectCapable: bool(src, kTISPropertyInputSourceIsSelectCapable))
    }

    private static func string(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    private static func strings(_ src: TISInputSource, _ key: CFString) -> [String] {
        guard let p = TISGetInputSourceProperty(src, key) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }
    private static func bool(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
}

/// 写系统剪贴板（带私有类型并登记 changeCount，剪贴板监测不会把自己复制的译文再弹出来）
final class SystemClipboard: ClipboardWriting {
    func write(_ text: String) {
        MainActor.assumeIsolated { OwnPasteboard.write(text) }
    }
}

/// TranslateIME 自己对剪贴板的所有写入都走这里
@MainActor
enum OwnPasteboard {
    static let ownType = NSPasteboard.PasteboardType(ClipboardTextFilter.ownType)
    /// AppContext 接到 ClipboardWatcher.markOwnChange
    static var onOwnChange: ((Int) -> Void)?

    static func write(_ text: String, notify: Bool = true) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string, ownType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ownType)
        if notify { noteOwnChange() }
    }

    /// 写完（例如恢复用户原剪贴板）后登记当前 changeCount
    static func noteOwnChange() { onOwnChange?(NSPasteboard.general.changeCount) }
}

/// 真实系统剪贴板的只读访问（ClipboardWatcher 用）。changeCount 是缓存的整数，读取极便宜。
final class SystemPasteboardReader: PasteboardReading {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func readTypes() -> [String] { (NSPasteboard.general.types ?? []).map(\.rawValue) }
    func readString() -> String? { NSPasteboard.general.string(forType: .string) }
}

/// 不写任何地方的剪贴板（只用来等待译文）
final class NullClipboard: ClipboardWriting {
    func write(_ text: String) {}
}
