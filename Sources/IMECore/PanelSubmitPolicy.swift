import Foundation

/// 翻译面板里回车键的含义（纯逻辑，可单测）
public enum PanelSubmitAction: Equatable, Sendable {
    case copyTranslation          // ↩：复制译文（默认随后关闭面板）
    case copyAndClear             // ⇧⌥↩：复制译文，清空输入，面板保持打开
    case commitTranslation        // ⌥↩：上屏译文（剪贴板 + 模拟 ⌘V）
    case commitOriginal           // ⌘↩ / ⇧↩：上屏原文
}

/// 复制完成后面板要做什么
public enum PanelAfterCopy: Equatable, Sendable {
    case closeAfter(TimeInterval)     // 显示“已复制 ✓”约 0.5 秒后关闭，恢复输入源并回到原应用
    case clearAndStay                 // 清空输入框，继续下一句
    case stay                         // 保持打开（已关闭“复制后自动关闭面板”）
    case showError(String)            // 翻译失败：不关闭，显示错误
    case nothing                      // 空输入/输入已变化：什么也不做
}

public enum PanelSubmitPolicy {
    public static let closeDelay: TimeInterval = 0.5

    public static func action(command: Bool, shift: Bool, option: Bool) -> PanelSubmitAction {
        if command { return .commitOriginal }
        if shift && option { return .copyAndClear }
        if option { return .commitTranslation }
        if shift { return .commitOriginal }
        return .copyTranslation
    }

    public static func afterCopy(_ outcome: CopyOutcome, action: PanelSubmitAction, closeAfterCopy: Bool) -> PanelAfterCopy {
        switch outcome {
        case .copied:
            if action == .copyAndClear { return .clearAndStay }
            return closeAfterCopy ? .closeAfter(closeDelay) : .stay
        case .failed(let message):
            return .showError(message)
        case .nothingToCopy, .superseded:
            return .nothing
        }
    }

    /// 面板底部的按键提示
    public static func hint(closeAfterCopy: Bool, autoInsert: Bool = false) -> String {
        let enter = autoInsert ? "↩ 填入原输入框" : (closeAfterCopy ? "↩ 复制并关闭" : "↩ 复制译文")
        return enter + " · ⇧⌥↩ 复制并清空 · ⌥↩ 上屏译文 · ⌘↩ 上屏原文 · ⎋ 关闭"
    }
}
