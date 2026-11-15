import CoreGraphics

/// 浮窗跟随输入光标的位置计算（纯函数，坐标系为 Cocoa 屏幕坐标：原点在左下，y 向上）。
///
/// 规则：
/// - 默认放在光标行**下方**（间隔 gap），左边与光标对齐；
/// - 下方放不下 → 放到光标行**上方**；
/// - 上下都放不下 → 放在空间更大的一侧并贴住屏幕边缘（此时面板比可用空间还高，只能尽量不挡光标行）；
/// - 水平方向始终限制在屏幕可见区域内（留 margin）。
public enum PanelPlacement {
    public enum Side: Equatable, Sendable { case below, above }

    public struct Result: Equatable, Sendable {
        /// 面板左上角（传给 NSWindow.setFrameTopLeftPoint）
        public var topLeft: CGPoint
        public var side: Side
        public var frame: CGRect
    }

    public static let gap: CGFloat = 6
    public static let margin: CGFloat = 8

    /// - Parameters:
    ///   - caret: 光标所在行的矩形（或输入框矩形），Cocoa 屏幕坐标
    ///   - size: 面板尺寸
    ///   - visible: 光标所在屏幕的 visibleFrame
    public static func place(caret: CGRect, size: CGSize, visible: CGRect,
                             gap: CGFloat = gap, margin: CGFloat = margin) -> Result {
        let c = caret.standardized
        // 水平：与光标左边对齐，夹在屏幕内
        let minX = visible.minX + margin
        let maxX = visible.maxX - margin - size.width
        let x = maxX < minX ? minX : min(max(c.minX, minX), maxX)

        let spaceBelow = (c.minY - gap) - (visible.minY + margin)
        let spaceAbove = (visible.maxY - margin) - (c.maxY + gap)
        let side: Side
        var top: CGFloat
        if size.height <= spaceBelow {
            side = .below; top = c.minY - gap
        } else if size.height <= spaceAbove {
            side = .above; top = c.maxY + gap + size.height
        } else if spaceAbove > spaceBelow {
            side = .above; top = visible.maxY - margin            // 贴顶
        } else {
            side = .below; top = visible.minY + margin + size.height   // 贴底
        }
        // 最终仍保证整体在屏幕内
        top = min(top, visible.maxY - margin)
        top = max(top, visible.minY + margin + min(size.height, visible.height - 2 * margin))
        let frame = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        return Result(topLeft: CGPoint(x: x, y: top), side: side, frame: frame)
    }

    /// AX 返回的是左上原点坐标（Quartz 全局坐标，以主屏左上为原点），转换为 Cocoa 坐标
    public static func cocoaRect(fromQuartz r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 光标矩形是否可信（AX/IMK 偶尔返回 0 或巨大的矩形）
    public static func isUsableCaret(_ r: CGRect, screens: [CGRect]) -> Bool {
        guard r.width >= 0, r.height > 0, r.height < 400, r.width < 4000 else { return false }
        if r.origin == .zero && r.size.height <= 1 { return false }
        let p = CGPoint(x: r.midX, y: r.midY)
        return screens.contains { $0.insetBy(dx: -2, dy: -2).contains(p) }
    }
}
