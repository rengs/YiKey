import Foundation

/// 把“按键 → 状态变化”抽成纯逻辑，既方便单测，也保证每次按键的同步工作量是 O(1) 的微秒级。
public enum ComposeKey: Equatable, Sendable {
    case character(String)   // 可打印 ASCII
    case returnKey, tab, escape, delete
    case modified            // 带 ⌘/⌃/⌥ 的组合键
    case paste(String)       // ⌘V：剪贴板文本（已开启“粘贴到组词”时由 InputController 读取）
    case other               // 方向键、功能键、非 ASCII 等
}

public enum ComposeAction: Equatable, Sendable {
    case passThrough         // 不处理，交给应用
    case flushThenPass       // 先把缓冲区原文上屏，再交给应用
    case update              // 缓冲区变化：刷新下划线与浮窗
    case commitOriginal
    case commitTranslation
    case cancel
}

public struct CompositionBuffer: Sendable {
    public private(set) var text = ""
    public init() {}
    public var isEmpty: Bool { text.isEmpty }
    public mutating func clear() { text = "" }

    public mutating func handle(_ key: ComposeKey) -> ComposeAction {
        switch key {
        case .character(let s):
            if text.isEmpty {
                // 只有字母才开始组词；数字/标点/空格直接放行
                guard let f = s.unicodeScalars.first, f.isASCII, f.properties.isAlphabetic else { return .passThrough }
            }
            text += s
            return .update
        case .returnKey: return text.isEmpty ? .passThrough : .commitOriginal
        case .tab:       return text.isEmpty ? .passThrough : .commitTranslation
        case .escape:    return text.isEmpty ? .passThrough : .cancel
        case .delete:
            guard !text.isEmpty else { return .passThrough }
            text.removeLast()
            return text.isEmpty ? .cancel : .update
        case .paste(let raw):
            // 不接管的粘贴（空、过长、空组词时不是英文）交给应用按原样粘贴
            guard let s = PasteNormalizer.normalize(raw) else { return text.isEmpty ? .passThrough : .flushThenPass }
            if text.isEmpty {
                guard LanguageDetector.detect(s) == .english else { return .passThrough }
                text = s
            } else {
                text += s
                if text.count > PasteNormalizer.maxLength { text = String(text.prefix(PasteNormalizer.maxLength)) }
            }
            return .update
        case .modified, .other:
            return text.isEmpty ? .passThrough : .flushThenPass
        }
    }
}

/// ⌘V 粘贴到英文组词前的清理：换行/制表符 → 空格，合并连续空白，去首尾空白；
/// 空文本或超过 maxLength（避免把整篇文档塞进组词）返回 nil，表示不接管。
public enum PasteNormalizer {
    public static let maxLength = 500

    public static func normalize(_ raw: String) -> String? {
        let pieces = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let s = pieces.joined(separator: " ")
        guard !s.isEmpty, s.count <= maxLength else { return nil }
        // 去掉控制字符
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        return cleaned.isEmpty ? nil : cleaned
    }
}
