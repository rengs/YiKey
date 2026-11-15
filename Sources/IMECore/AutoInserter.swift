import Foundation

// MARK: - 回复模式最后一下 ↩：把英文自动填入原应用的输入框
//
// 优先级：
// 1. TranslateIME 正是原应用里的当前输入法 → IMK client.insertText（不碰剪贴板、不需要辅助功能）
// 2. 已授权辅助功能 → 写剪贴板（带自写标记）→ 模拟 ⌘V → 稍后恢复用户原剪贴板（同样登记为自写）
// 3. 都不行 → 只复制，提示“已复制，请 ⌘V（开启辅助功能可自动粘贴）”
// 任何情况下都**只插入文字，绝不发送回车**。

public enum InsertStrategy: Equatable, Sendable {
    case clientInsert
    case paste
    case copyOnly
}

public enum InsertOutcome: Equatable, Sendable {
    case inserted           // IMK insertText
    case pasted             // ⌘V
    case copiedOnly         // 仅复制（未授权辅助功能 / 关闭了自动填入）
}

public enum InsertionPlanner {
    /// 关闭“回车后自动填入原输入框”时只复制；否则按可用性选择
    public static func strategy(autoInsert: Bool, imeClientAvailable: Bool, accessibilityTrusted: Bool) -> InsertStrategy {
        guard autoInsert else { return .copyOnly }
        if imeClientAvailable { return .clientInsert }
        if accessibilityTrusted { return .paste }
        return .copyOnly
    }

    public static let copyOnlyHint = "已复制，请 ⌘V（开启辅助功能可自动粘贴）"
}

/// IMK 客户端插入（App 侧实现：只有当前激活的 InputController 的客户端正是原应用时才返回 true）
@MainActor
public protocol ClientTextInserter: AnyObject {
    func insertIntoClient(_ text: String) -> Bool
}

/// 发送 ⌘V（App 侧用 CGEvent 实现）。只允许 ⌘V，不提供发送回车的能力。
@MainActor
public protocol PasteKeystrokeSender: AnyObject {
    func sendCommandV()
}

/// 剪贴板快照与写入（App 侧用 NSPasteboard 实现）
@MainActor
public protocol PasteboardStore: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> [[String: Data]]
    func restore(_ items: [[String: Data]])
    /// 写入文本并带上 TranslateIME 私有类型
    func writeOwn(_ text: String)
}

@MainActor
public final class AutoInserter {
    private let pasteboard: PasteboardStore
    private let keys: PasteKeystrokeSender
    private let client: ClientTextInserter
    private let markOwn: (Int) -> Void
    private let sleep: (UInt64) async -> Void
    public var pasteDelayNs: UInt64 = 120_000_000      // 写剪贴板后等多久再 ⌘V
    public var restoreDelayNs: UInt64 = 500_000_000    // ⌘V 后等多久恢复原剪贴板

    public init(pasteboard: PasteboardStore, keys: PasteKeystrokeSender, client: ClientTextInserter,
                markOwn: @escaping (Int) -> Void,
                sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.client = client
        self.markOwn = markOwn
        self.sleep = sleep
    }

    /// 执行插入。strategy 为 .clientInsert 但运行时客户端不可用时，按授权情况降级。
    @discardableResult
    public func insert(_ text: String, strategy: InsertStrategy, accessibilityTrusted: Bool) async -> InsertOutcome {
        switch strategy {
        case .clientInsert:
            if client.insertIntoClient(text) { return .inserted }
            if accessibilityTrusted { return await paste(text) }
            copyOnly(text); return .copiedOnly
        case .paste:
            return await paste(text)
        case .copyOnly:
            copyOnly(text); return .copiedOnly
        }
    }

    private func copyOnly(_ text: String) {
        pasteboard.writeOwn(text)
        markOwn(pasteboard.changeCount)
    }

    private func paste(_ text: String) async -> InsertOutcome {
        let backup = pasteboard.snapshot()
        pasteboard.writeOwn(text)
        let ours = pasteboard.changeCount
        markOwn(ours)
        await sleep(pasteDelayNs)
        keys.sendCommandV()
        await sleep(restoreDelayNs)
        // 这段时间里用户自己又复制了别的东西 → 不覆盖
        if pasteboard.changeCount == ours {
            pasteboard.restore(backup)
            markOwn(pasteboard.changeCount)      // 恢复也是自己写的：剪贴板监测不能再弹出
        }
        return .pasted
    }
}
