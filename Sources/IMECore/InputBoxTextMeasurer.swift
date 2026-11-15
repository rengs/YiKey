import AppKit

/// 用与输入框**完全相同**的文字系统（同字体、同 NSLayoutManager/NSTextContainer 配置、同内边距）测量文本，
/// 给 InputBoxSizer 提供真实的单行宽度与折行高度。输入框（PanelTextView 里的 NSTextView）用同一组参数配置，
/// 因此“输入框高度 == 实测文本高度 + 上下内边距”，所有行都完整可见。
@MainActor
public final class InputBoxTextMeasurer {
    public let font: NSFont
    /// NSTextView.textContainerInset
    public let inset: NSSize
    /// NSTextContainer.lineFragmentPadding
    public let lineFragmentPadding: CGFloat
    /// 文字区额外余量，防止浮点误差导致提前折行
    public let slack: CGFloat = 2

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 1_000_000, height: 1_000_000))

    public init(font: NSFont, inset: NSSize = NSSize(width: 2, height: 3), lineFragmentPadding: CGFloat = 4) {
        self.font = font; self.inset = inset; self.lineFragmentPadding = lineFragmentPadding
        container.lineFragmentPadding = lineFragmentPadding
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    public var attributes: [NSAttributedString.Key: Any] { [.font: font] }
    public var lineHeight: CGFloat { layoutManager.defaultLineHeight(for: font) }
    public var cjkAdvance: CGFloat { ("中" as NSString).size(withAttributes: attributes).width }

    /// 输入框文字容器宽度（含 lineFragmentPadding）= 字形宽度 + 2×padding + 余量
    public func containerWidth(forTextWidth w: CGFloat) -> CGFloat { w + 2 * lineFragmentPadding + slack }

    public func makeSizer(minTextWidth: CGFloat = 260, maxLines: Int = 15) -> InputBoxSizer {
        InputBoxSizer(cjkAdvance: cjkAdvance, lineHeight: lineHeight, minTextWidth: minTextWidth,
                      horizontalPadding: 2 * inset.width + 2 * lineFragmentPadding + slack,
                      verticalPadding: 2 * inset.height, maxLines: maxLines)
    }

    /// 单行字形宽度
    public func singleLineWidth(_ text: NSAttributedString) -> CGFloat {
        text.size().width
    }

    /// 文字区宽度为 textWidth（不含 padding）时的真实排版高度（不含 inset）
    public func textHeight(_ text: NSAttributedString, textWidth: CGFloat) -> CGFloat {
        container.size = NSSize(width: containerWidth(forTextWidth: textWidth), height: 1_000_000)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        var used = layoutManager.usedRect(for: container).height
        if text.length == 0 { used = max(used, lineHeight) }
        return ceil(used)
    }

    /// 统计排版后的行数（测试与诊断用）
    public func lineCount(_ text: NSAttributedString, textWidth: CGFloat) -> Int {
        _ = textHeight(text, textWidth: textWidth)
        var count = 0, index = 0
        let glyphs = layoutManager.numberOfGlyphs
        while index < glyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range); count += 1
        }
        return max(count, 1)
    }

    /// 把输入框的 NSTextView 配成与测量完全一致（字体、内边距、lineFragmentPadding、按宽度折行）
    public func configure(_ tv: NSTextView) {
        tv.font = font
        tv.typingAttributes = attributes
        tv.isRichText = false
        tv.textContainerInset = inset
        tv.textContainer?.lineFragmentPadding = lineFragmentPadding
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    public func layout(for text: NSAttributedString, sizer: InputBoxSizer) -> InputBoxLayout {
        sizer.layout(singleLineWidth: singleLineWidth(text)) { textHeight(text, textWidth: $0) }
    }

    public func layout(for string: String, sizer: InputBoxSizer) -> InputBoxLayout {
        layout(for: NSAttributedString(string: string, attributes: attributes), sizer: sizer)
    }
}
