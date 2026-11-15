import CoreGraphics

/// 翻译面板输入框的尺寸计算（纯逻辑，可单测）。
/// 规则：文本单行宽度不超过“35 个汉字”的宽度时，输入框随文字横向变长、不换行；
/// 超过后宽度固定为 35 个汉字宽，开始换行，并按折行后的高度纵向变高（不裁切）。
public struct InputBoxLayout: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var wraps: Bool
    /// 文本超过 maxLines 行：输入框高度封顶，内部才允许滚动（其余情况绝不滚动）
    public var scrolls: Bool
    public init(width: CGFloat, height: CGFloat, wraps: Bool, scrolls: Bool = false) {
        self.width = width; self.height = height; self.wraps = wraps; self.scrolls = scrolls
    }
}

public struct InputBoxSizer: Equatable, Sendable {
    public static let wrapThresholdChineseChars = 35

    public var cjkAdvance: CGFloat          // 一个汉字的排版宽度（按实际字体测量）
    public var lineHeight: CGFloat          // 单行高度
    public var minTextWidth: CGFloat        // 文本区最小宽度（放得下占位文字）
    public var horizontalPadding: CGFloat   // 文本框左右内边距合计
    public var verticalPadding: CGFloat     // 文本框上下内边距合计
    public var maxLines: Int                // 超过后不再长高（文本框内部滚动）

    public init(cjkAdvance: CGFloat, lineHeight: CGFloat, minTextWidth: CGFloat = 260,
                horizontalPadding: CGFloat = 12, verticalPadding: CGFloat = 6, maxLines: Int = 15) {
        self.cjkAdvance = cjkAdvance; self.lineHeight = lineHeight; self.minTextWidth = minTextWidth
        self.horizontalPadding = horizontalPadding; self.verticalPadding = verticalPadding; self.maxLines = maxLines
    }

    /// 换行阈值：35 个汉字的宽度
    public var maxTextWidth: CGFloat { cjkAdvance * CGFloat(Self.wrapThresholdChineseChars) }

    public var singleLine: InputBoxLayout {
        InputBoxLayout(width: minTextWidth + horizontalPadding, height: (lineHeight + verticalPadding).rounded(.up), wraps: false)
    }

    /// - singleLineWidth: 整段文本（含正在组词的拼音）单行排版的字形宽度
    /// - wrappedHeight: 文字区宽度为 maxTextWidth 时，**真实排版**（同字体、同 layout manager）得到的文本总高度。
    ///   单行和多行都会调用：输入框高度 = 实测文本高度 + 上下内边距，所以不会裁切，也不会留空白。
    public func layout(singleLineWidth w: CGFloat, wrappedHeight: (CGFloat) -> CGFloat) -> InputBoxLayout {
        let tolerance: CGFloat = 0.5          // 浮点误差：恰好 35 个汉字不换行
        let wraps = w > maxTextWidth + tolerance
        let width = wraps ? maxTextWidth + horizontalPadding : max(minTextWidth, w) + horizontalPadding
        let measured = max(wrappedHeight(maxTextWidth), lineHeight)
        let cap = lineHeight * CGFloat(maxLines)
        let scrolls = measured > cap + 0.5
        let textHeight = min(measured, cap)
        return InputBoxLayout(width: width.rounded(.up), height: (textHeight + verticalPadding).rounded(.up),
                              wraps: wraps, scrolls: scrolls)
    }
}
