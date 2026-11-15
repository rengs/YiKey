import Foundation

// MARK: - 阅读 ⇄ 回复 的会话状态（纯逻辑，可测）
//
// - 剪贴板来新的外部英文：无论在阅读还是回复，都切到“英文阅读”，来源更新为新复制的位置。
// - 正在回复时被打断：半截中文草稿连同“它要回复的来源”暂存；之后对同一来源按 ↩ 回复时恢复。
// - ⎋ / 关闭面板：丢弃草稿。

public struct ReplySession<Source: Equatable> {
    public enum Mode: Equatable, Sendable { case hidden, reading, replying }

    public struct Transition: Equatable, Sendable {
        /// 离开了回复模式（需要恢复原输入源）
        public var leftReply: Bool
        /// 草稿被暂存
        public var stashedDraft: Bool
        /// 取消旧回复里还没完成的翻译 / 填入
        public var cancelPending: Bool
    }

    public private(set) var mode: Mode = .hidden
    public private(set) var english: String?
    public private(set) var source: Source?
    public private(set) var stashedDraft: String?
    public private(set) var stashedSource: Source?

    public init() {}

    /// 新的剪贴板英文到来。newSource 为 nil（拿不到来源应用）时保留原来源。
    @discardableResult
    public mutating func clipboardEnglish(_ text: String, from newSource: Source?, draft: String = "") -> Transition {
        let wasReplying = mode == .replying
        var stashed = false
        if wasReplying, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stashedDraft = draft
            stashedSource = source
            stashed = true
        }
        english = text
        if let newSource { source = newSource }
        mode = .reading
        return Transition(leftReply: wasReplying, stashedDraft: stashed, cancelPending: true)
    }

    /// 阅读面板上按 ↩ / ⌃⌥T：进入回复。返回要恢复的草稿（同一来源才恢复，恢复后清掉）。
    public mutating func startReply() -> String? {
        guard mode == .reading else { return nil }
        mode = .replying
        guard let d = stashedDraft, stashedSource == source else { return nil }
        stashedDraft = nil
        stashedSource = nil
        return d
    }

    /// 直接用 ⌃⌥T 打开中文输入（不是从阅读面板进入）
    public mutating func openTranslator(source s: Source?) {
        mode = .replying
        english = nil
        source = s
    }

    /// ⎋ / 关闭 / 填入完成：丢弃草稿
    public mutating func hide() {
        mode = .hidden
        english = nil
        source = nil
        stashedDraft = nil
        stashedSource = nil
    }
}
