import Foundation
import CoreGraphics

// MARK: - 回复的英文“落到聊天输入框”
//
// 流程（最后一下 ↩）：
//   1. 英文**总是**写入剪贴板并保留（标记为自写，剪贴板监测不会再弹）——找不到输入框时用户可直接 ⌘V
//   2. 重新激活来源应用 + 来源窗口
//   3. 找输入框：焦点元素本身可编辑 → 用它；否则在焦点窗口的 AX 树里（限深度/数量/0.3s）挑最佳候选
//   4. 聚焦：AXFocused = true；失败且已授权时，对选中的这个元素中心点一次合成点击
//   5. 插入：优先设置 AXSelectedText（在光标处插入，不覆盖已有文字），读回 AXValue 校验；
//      不支持/没变化 → 确认前台后发一次 ⌘V。**绝不发送回车。**

/// 一个候选输入元素的属性快照（坐标为 Cocoa：原点左下，y 向上）
public struct InputCandidate: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var roleDescription: String?
    public var placeholder: String?
    public var title: String?
    public var help: String?
    public var frame: CGRect
    public var enabled: Bool
    public var focused: Bool
    public var editableFlag: Bool          // AXEditable（网页 contenteditable 等）
    public var valueSettable: Bool
    public var selectedTextSettable: Bool

    public init(role: String, subrole: String? = nil, roleDescription: String? = nil, placeholder: String? = nil,
                title: String? = nil, help: String? = nil, frame: CGRect, enabled: Bool = true, focused: Bool = false,
                editableFlag: Bool = false, valueSettable: Bool = true, selectedTextSettable: Bool = true) {
        self.role = role; self.subrole = subrole; self.roleDescription = roleDescription
        self.placeholder = placeholder; self.title = title; self.help = help; self.frame = frame
        self.enabled = enabled; self.focused = focused; self.editableFlag = editableFlag
        self.valueSettable = valueSettable; self.selectedTextSettable = selectedTextSettable
    }
}

public enum InputBoxFinder {
    public static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    static let messageWords = ["message", "messag", "reply", "type", "write", "compose", "chat", "comment", "say",
                               "send", "talk", "输入", "消息", "回复", "发送", "说点", "评论", "聊天", "写"]
    static let searchWords = ["search", "搜索", "查找", "find", "filter", "过滤"]

    /// 是否是可以往里填文字的输入元素（排除搜索框、密码框、禁用的）
    public static func isEditableInput(_ c: InputCandidate) -> Bool {
        if c.role == "AXSearchField" || c.subrole == "AXSearchField" { return false }
        if c.role == "AXSecureTextField" || c.subrole == "AXSecureTextField" { return false }
        guard c.enabled else { return false }
        let editable = textRoles.contains(c.role) || c.editableFlag
        guard editable else { return false }
        return c.valueSettable || c.selectedTextSettable || c.editableFlag
    }

    private static func mentions(_ c: InputCandidate, _ words: [String]) -> Bool {
        let hay = [c.placeholder, c.roleDescription, c.title, c.help].compactMap { $0?.lowercased() }.joined(separator: " ")
        return words.contains { hay.contains($0) }
    }

    /// 打分；nil 表示不考虑。越靠下、越宽、越像“消息框”分越高
    public static func score(_ c: InputCandidate, window: CGRect) -> Double? {
        guard isEditableInput(c) else { return nil }
        let f = c.frame
        guard f.width >= 40, f.height >= 10 else { return nil }
        guard window.width > 0, window.height > 0, window.insetBy(dx: -4, dy: -4).intersects(f) else { return nil }
        if mentions(c, searchWords) { return nil }                       // “搜索”“查找”占位符的普通文本框
        let bottomness = 1 - min(max((f.midY - window.minY) / window.height, 0), 1)   // 底部 = 1
        let widthRatio = min(f.width / window.width, 1)
        var s = bottomness * 50 + widthRatio * 30
        if mentions(c, messageWords) { s += 25 }
        if c.role == "AXTextArea" { s += 10 }
        if c.focused { s += 15 }
        if f.height > window.height * 0.5 { s -= 30 }                    // 占半个窗口：更像文档/历史区域
        return s
    }

    /// 返回最佳候选的下标
    public static func best(_ cs: [InputCandidate], window: CGRect) -> Int? {
        var bestIndex: Int?, bestScore = -Double.infinity
        for (i, c) in cs.enumerated() {
            if let s = score(c, window: window), s > bestScore { bestScore = s; bestIndex = i }
        }
        return bestIndex
    }
}

// MARK: 编排（AX 细节由 App 侧 driver 实现，测试用 mock）

@MainActor
public protocol ReplyTargetDriver: AnyObject {
    associatedtype Element
    /// 重新激活来源应用并抬起来源窗口；返回前台是否已是来源应用
    func activateSource() async -> Bool
    /// 来源窗口的矩形（Cocoa）
    func windowFrame() -> CGRect?
    /// 焦点元素（及其属性）
    func focusedElement() -> (Element, InputCandidate)?
    /// 在来源窗口里搜索文本输入候选（实现方负责限深度/数量/时间）
    func searchCandidates() -> [(Element, InputCandidate)]
    func focus(_ e: Element) -> Bool
    /// 对元素中心点合成一次点击（仅在已授权时由编排调用）
    func click(_ e: Element) -> Bool
    func setSelectedText(_ e: Element, _ text: String) -> Bool
    func readValue(_ e: Element) -> String?
    /// 发送一次 ⌘V（实现方需先确认前台是来源应用）；返回是否已发送
    func sendCommandV() -> Bool
}

public enum ReplyInsertResult: Equatable, Sendable {
    case insertedAX              // AXSelectedText 并已校验
    case pasted                  // ⌘V
    case notFound                // 没找到输入框（英文已在剪贴板）
    case activationFailed        // 来源应用没回到前台（英文已在剪贴板）
    case insertFailed            // 找到了但插入和 ⌘V 都没成功
    case cancelled               // 用户又复制了别的英文：旧回复的填入被取消（英文已在剪贴板）

    public var inserted: Bool { self == .insertedAX || self == .pasted }
    public var feedback: String {
        if self == .cancelled { return "回复已取消（英文已复制）" }
        return inserted ? "已填入输入框（已同时复制）" : "未找到输入框，已复制，请 ⌘V"
    }
}

public struct ReplyInsertReport: Equatable, Sendable {
    public var result: ReplyInsertResult
    public var target: String          // focused / searched / none
    public var focusedBy: String       // already / ax / click / failed / -
    public var candidates: Int
    public var chosen: InputCandidate?
    /// 日志行（不含任何文字内容）
    public var logLine: String {
        let f = chosen.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-"
        return "reply result=\(result) target=\(target) focus=\(focusedBy) candidates=\(candidates) role=\(chosen?.role ?? "-") frame=\(f)"
    }
}

@MainActor
public final class ReplyInserter<D: ReplyTargetDriver> {
    private let driver: D
    private let pasteboard: PasteboardStore
    private let markOwn: (Int) -> Void
    private let isCancelled: () -> Bool

    public init(driver: D, pasteboard: PasteboardStore, markOwn: @escaping (Int) -> Void,
                isCancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.driver = driver; self.pasteboard = pasteboard; self.markOwn = markOwn; self.isCancelled = isCancelled
    }

    public func run(_ text: String, accessibilityTrusted: Bool) async -> ReplyInsertReport {
        // 1. 英文总是放到剪贴板并保留
        pasteboard.writeOwn(text)
        markOwn(pasteboard.changeCount)
        var report = ReplyInsertReport(result: .notFound, target: "none", focusedBy: "-", candidates: 0, chosen: nil)
        guard accessibilityTrusted else { return report }

        // 2. 回到来源应用
        guard await driver.activateSource() else { report.result = .activationFailed; return report }
        if isCancelled() { report.result = .cancelled; return report }

        // 3. 找输入框
        var element: D.Element?
        var needsFocus = false
        if let (e, c) = driver.focusedElement(), InputBoxFinder.isEditableInput(c) {
            element = e; report.chosen = c; report.target = "focused"; report.focusedBy = "already"
        } else {
            let found = driver.searchCandidates()
            report.candidates = found.count
            let window = driver.windowFrame() ?? found.map(\.1.frame).reduce(CGRect.null) { $0.union($1) }
            if let i = InputBoxFinder.best(found.map(\.1), window: window) {
                element = found[i].0; report.chosen = found[i].1; report.target = "searched"; needsFocus = true
            }
        }
        guard let el = element else { report.result = .notFound; return report }

        if isCancelled() { report.result = .cancelled; return report }
        // 4. 聚焦
        var focused = !needsFocus
        if needsFocus {
            if driver.focus(el) { focused = true; report.focusedBy = "ax" }
            else if driver.click(el) { focused = true; report.focusedBy = "click" }
            else { report.focusedBy = "failed" }
        }

        // 5. 插入：AXSelectedText → 校验 → ⌘V
        let before = driver.readValue(el)
        if driver.setSelectedText(el, text) {
            let after = driver.readValue(el)
            if after == nil && before == nil { report.result = .insertedAX; return report }   // 读不到值：相信 API 成功
            if let a = after, a != before, a.contains(text) { report.result = .insertedAX; return report }
        }
        // 只有确定焦点在这个输入框里才发 ⌘V（否则可能粘到别处）
        if isCancelled() { report.result = .cancelled; return report }
        if focused, driver.sendCommandV() { report.result = .pasted; return report }
        report.result = .insertFailed
        return report
    }
}
