import CoreGraphics
import Foundation

// MARK: - 剪贴板面板的“锚点链”：决定面板出现在哪里
//
// 优先级（第一个可用的胜出）：
//   1. selection  焦点元素里选中文字的范围（刚复制的那段文字本身，网页/聊天记录里的只读文本也可以）
//   2. caret      焦点元素里的光标（可编辑输入框）/ IMK 光标
//   3. field      焦点输入框本身的矩形（只用于较矮的输入框）
//   4. mouse      检测到剪贴板变化那一刻的鼠标位置：面板放在鼠标右下方
//   5. window     前台应用焦点窗口：面板放在窗口下三分之一的中间
//   6. fallback   屏幕右上角（最后手段）
// 所有坐标都是 Cocoa 屏幕坐标（原点左下）。

public enum AnchorStrategy: String, Sendable, CaseIterable {
    case selection, caret, field, mouse, window, fallback
}

public enum PanelAnchor: Equatable, Sendable {
    case rect(CGRect, AnchorStrategy)     // selection / caret / field：贴着矩形上下放
    case mouse(CGPoint)
    case window(CGRect)
    case fallback

    public var strategy: AnchorStrategy {
        switch self {
        case .rect(_, let s): return s
        case .mouse: return .mouse
        case .window: return .window
        case .fallback: return .fallback
        }
    }
}

/// 读取 AX 信息的抽象（App 侧用真实 AX 实现，测试用 mock）。所有方法返回 Cocoa 坐标；拿不到返回 nil。
public protocol AXAnchorQuerying: Sendable {
    /// 每次调用都实时检查（不缓存启动时的授权状态）
    func isTrusted() -> Bool
    /// 焦点元素选中文字（length > 0）的范围矩形；含 WebKit/Chromium 的 TextMarker 方式
    func selectionBounds(pid: pid_t) -> CGRect?
    /// 焦点元素光标处（length == 0）的矩形
    func caretBounds(pid: pid_t) -> CGRect?
    /// 焦点元素（输入框）的矩形
    func focusedElementFrame(pid: pid_t) -> CGRect?
    /// 焦点窗口的矩形
    func focusedWindowFrame(pid: pid_t) -> CGRect?
}

public struct AnchorInputs: Equatable, Sendable {
    public var selection: CGRect?
    public var caret: CGRect?
    public var field: CGRect?
    public var mouse: CGPoint?
    public var window: CGRect?
    public var trusted: Bool
    public init(selection: CGRect? = nil, caret: CGRect? = nil, field: CGRect? = nil,
                mouse: CGPoint? = nil, window: CGRect? = nil, trusted: Bool = false) {
        self.selection = selection; self.caret = caret; self.field = field
        self.mouse = mouse; self.window = window; self.trusted = trusted
    }
}

public enum AnchorChain {
    public static let maxFieldHeight: CGFloat = 200

    /// 收集输入：AX 只在“当前已授权”时调用，并且按优先级短路（找到 selection 就不再问后面的，省 IPC）
    public static func gather(ax: AXAnchorQuerying, pid: pid_t?, imkCaret: CGRect?, mouse: CGPoint?,
                              screens: [CGRect]) -> AnchorInputs {
        var inputs = AnchorInputs(mouse: mouse)
        let usable = { (r: CGRect?) -> CGRect? in
            guard let r, PanelPlacement.isUsableCaret(r, screens: screens) else { return nil }
            return r
        }
        inputs.trusted = ax.isTrusted()
        if inputs.trusted, let pid {
            inputs.selection = usable(ax.selectionBounds(pid: pid))
            if inputs.selection == nil { inputs.caret = usable(ax.caretBounds(pid: pid)) }
            if inputs.selection == nil && inputs.caret == nil {
                if let f = usable(ax.focusedElementFrame(pid: pid)), f.height <= maxFieldHeight { inputs.field = f }
            }
        }
        if inputs.caret == nil { inputs.caret = usable(imkCaret) }
        if inputs.trusted, let pid, inputs.selection == nil, inputs.caret == nil, inputs.field == nil {
            // 鼠标总是有的；窗口只在鼠标不可用时才有意义，但顺便取一下方便诊断成本很低（一次 IPC）
            if mouse == nil || !screens.contains(where: { $0.contains(mouse!) }) {
                if let w = ax.focusedWindowFrame(pid: pid), w.width > 50, w.height > 50 { inputs.window = w }
            }
        }
        return inputs
    }

    public static func choose(_ i: AnchorInputs, screens: [CGRect]) -> PanelAnchor {
        if let r = i.selection { return .rect(r, .selection) }
        if let r = i.caret { return .rect(r, .caret) }
        if let r = i.field { return .rect(r, .field) }
        if let m = i.mouse, screens.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(m) }) { return .mouse(m) }
        if let w = i.window, screens.contains(where: { $0.intersects(w) }) { return .window(w) }
        return .fallback
    }

    /// 计算面板左上角。screens: (frame, visibleFrame)。fallback 返回 nil，由调用方使用原来的位置。
    public static func topLeft(for anchor: PanelAnchor, size: CGSize,
                               screens: [(frame: CGRect, visible: CGRect)]) -> CGPoint? {
        func visible(containing p: CGPoint) -> CGRect {
            (screens.first { $0.frame.contains(p) } ?? screens.first)?.visible ?? .zero
        }
        switch anchor {
        case .rect(let r, _):
            let v = visible(containing: CGPoint(x: r.midX, y: r.midY))
            return PanelPlacement.place(caret: r, size: size, visible: v).topLeft
        case .mouse(let m):
            // 鼠标右下方：把鼠标当作一个小“光标”，面板左边在鼠标右侧 12pt，顶边在鼠标下方 10pt
            let v = visible(containing: m)
            let pseudo = CGRect(x: m.x + 12, y: m.y - 4, width: 1, height: 8)
            return PanelPlacement.place(caret: pseudo, size: size, visible: v).topLeft
        case .window(let w):
            let v = visible(containing: CGPoint(x: w.midX, y: w.midY))
            let m = PanelPlacement.margin
            let centerY = w.minY + w.height / 6            // 下三分之一的中线
            var top = centerY + size.height / 2
            var x = w.midX - size.width / 2
            x = max(v.minX + m, min(x, v.maxX - m - size.width))
            top = min(top, v.maxY - m)
            top = max(top, v.minY + m + min(size.height, v.height - 2 * m))
            return CGPoint(x: x, y: top)
        case .fallback:
            return nil
        }
    }

    /// 诊断日志里的一行（不含任何用户文字）
    public static func describe(_ i: AnchorInputs, anchor: PanelAnchor, app: String?) -> String {
        func r(_ x: CGRect?) -> String { x.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? "-" }
        let m = i.mouse.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"
        return "app=\(app ?? "-") trusted=\(i.trusted) strategy=\(anchor.strategy.rawValue) selection=\(r(i.selection)) caret=\(r(i.caret)) field=\(r(i.field)) mouse=\(m) window=\(r(i.window))"
    }
}
