import SwiftUI
import AppKit
import IMECore

@MainActor
final class PanelViewModel: ObservableObject {
    /// candidate：组词候选；translator：⌃⌥T / 回复输入；reading：剪贴板英文自动翻译（只读，↩ 转回复）
    enum Mode { case candidate, translator, reading }
    @Published var mode: Mode = .candidate
    @Published var inputText = ""
    /// 回复模式里显示在输入框上方的英文原文（小字）
    @Published var context: String?
    /// 翻译面板输入框尺寸（随文字变长，超过 35 个汉字换行后变高）
    @Published var inputLayout = PanelViewModel.defaultInputLayout
    static var defaultInputLayout: InputBoxLayout { ComposingTextField.sizer.singleLine }
    /// 输入源提示（如未启用简体拼音）
    @Published var hint: String?
    /// 短暂反馈（如“已复制”）
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    var onCommitOriginal: () -> Void = {}
    var onCommitTranslation: () -> Void = {}
    var onCopyTranslation: (_ clearAndStay: Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onStartReply: () -> Void = {}
    func startReply() { onStartReply() }

    // 纠正译法（面板内两栏小编辑器：原词 / 正确译法 → 存入我的词表并重新翻译）
    @Published var correcting = false
    @Published var correctionSource = ""
    @Published var correctionTarget = ""
    @Published var correctionError: String?
    /// true：打开编辑器时把光标放在“正确译法”栏（原词已预填）
    var correctionFocusTarget = false
    let correctionFields = CorrectionFieldRegistry()
    var onBeginCorrection: () -> Void = {}
    var onSaveCorrection: () -> Void = {}
    var onEndCorrection: () -> Void = {}

    func commitOriginal() { onCommitOriginal() }
    func commitTranslation() { onCommitTranslation() }
    func copyTranslation(clearAndStay: Bool = false) { onCopyTranslation(clearAndStay) }
    /// ⎋ / 关闭：纠正编辑器开着时只关编辑器，不关面板
    func cancel() { if correcting { onEndCorrection() } else { onCancel() } }

    func showToast(_ text: String, seconds: Double = 1.6) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func resetTransient() {
        toastTask?.cancel(); toastTask = nil
        toast = nil; hint = nil
        correcting = false; correctionError = nil
    }
}

/// 翻译面板里 ↩ 的含义（见 IMECore.PanelSubmitPolicy）
typealias SubmitKind = PanelSubmitAction

struct PanelRootView: View {
    @ObservedObject var vm: PanelViewModel
    @ObservedObject var coordinator: TranslationCoordinator
    let host: AnyView   // 放 Apple Translation 的宿主视图

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            resultRow
            if vm.correcting { correctionEditor }
            footer
        }
        .padding(14)
        .frame(width: panelWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .background(host)
        // 宿主视图比内容大（尺寸更新还没跟上）时也贴顶显示，绝不把顶部挤出去
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static let readingWidth: CGFloat = 440

    /// 候选模式固定 380；阅读模式 440；翻译面板随输入框变宽（输入框 + 🔊 + 内边距）
    private var panelWidth: CGFloat {
        switch vm.mode {
        case .translator: return max(vm.context == nil ? 380 : Self.readingWidth, vm.inputLayout.width + 28 + 28)
        case .reading: return Self.readingWidth
        case .candidate: return 380
        }
    }

    @ViewBuilder private var header: some View {
        if vm.mode == .reading {
            VStack(alignment: .leading, spacing: 4) {
                Text("📋 剪贴板英文").font(.caption2).foregroundStyle(.tertiary)
                HStack(alignment: .top, spacing: 8) {
                    Text(coordinator.sourceText)
                        .font(.system(size: 14))
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    sourceSpeaker
                }
            }
        } else if vm.mode == .translator {
            VStack(alignment: .leading, spacing: 4) {
                if let ctx = vm.context {
                    // 回复模式：保留对方的英文原文作参考
                    Text(ctx)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                HStack(alignment: .top, spacing: 8) {
                    ComposingTextField(
                        text: $vm.inputText,
                        placeholder: vm.context == nil ? "输入中文或英文，自动翻译…" : "用中文输入回复，自动译成英文…",
                        onSettled: { coordinator.update(text: $0) },
                        onSubmit: { kind in
                            switch kind {
                            case .copyTranslation: vm.copyTranslation()
                            case .copyAndClear: vm.copyTranslation(clearAndStay: true)
                            case .commitTranslation: vm.commitTranslation()
                            case .commitOriginal: vm.commitOriginal()
                            }
                        },
                        onCancel: { vm.cancel() },
                        onLayout: { layout in if vm.inputLayout != layout { vm.inputLayout = layout } })
                    .frame(width: vm.inputLayout.width, height: vm.inputLayout.height, alignment: .topLeading)
                    sourceSpeaker
                }
                if let hint = vm.hint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text(coordinator.sourceText)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                sourceSpeaker
            }
        }
    }

    /// 英→中：英文原文旁的 🔊。仅点击才读英文原文（en-US）并记入单词本；中文译文不发音。
    @ViewBuilder private var sourceSpeaker: some View {
        if coordinator.canPronounceSource {
            SpeakerButton(help: "点击播放英文原文的美式发音") { coordinator.pronounceTapped() }
        }
    }

    @ViewBuilder private var resultRow: some View {
        switch coordinator.phase {
        case .idle:
            Text("等待输入…").foregroundStyle(.tertiary)
        case .loading:
            // 不用转圈动画：持续动画会在打字时白白占用主线程/GPU
            Text("翻译中…").foregroundStyle(.secondary)
        case .ready(let r):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(r.translated)
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(vm.mode == .reading ? 12 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if coordinator.canPronounceTranslation {
                        // 中→英：仅点击才读英文译文；译文为中文时这里不显示按钮（中文不发音）
                        SpeakerButton(help: "点击播放美式发音") { coordinator.pronounceTapped() }
                    }
                }
                HStack(spacing: 6) {
                    Text(providerLabel(r.providerID) + (r.glossaryTerms > 0 ? " · 术语 \(r.glossaryTerms) 个" : ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if vm.mode != .candidate && !vm.correcting {
                        Button("纠正译法") { vm.onBeginCorrection() }
                            .buttonStyle(.link).font(.caption)
                            .help("把某个词的正确译法存进“我的词表”，以后自动使用")
                    }
                }
            }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var correctionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("纠正译法：保存到“我的词表”，以后翻译自动使用").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                CorrectionField(text: $vm.correctionSource, placeholder: "原词（中文或英文）", tag: 0,
                                autoFocus: !vm.correctionFocusTarget, registry: vm.correctionFields,
                                onSubmit: { vm.onSaveCorrection() }, onCancel: { vm.onEndCorrection() })
                Text("→").foregroundStyle(.secondary)
                CorrectionField(text: $vm.correctionTarget, placeholder: "正确译法", tag: 1,
                                autoFocus: vm.correctionFocusTarget, registry: vm.correctionFields,
                                onSubmit: { vm.onSaveCorrection() }, onCancel: { vm.onEndCorrection() })
            }
            .frame(height: 24)
            HStack(spacing: 8) {
                Button("保存并重译") { vm.onSaveCorrection() }
                Button("取消") { vm.onEndCorrection() }
                if let err = vm.correctionError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("↩ 保存 · ⇥ 切换 · ⎋ 取消").font(.caption2).foregroundStyle(.tertiary)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if vm.mode == .reading {
                Button("用中文回复") { vm.startReply() }
                Button("关闭") { vm.cancel() }
            } else {
                if vm.mode == .translator {
                    Button("复制译文") { vm.copyTranslation() }
                }
                Button("上屏原文") { vm.commitOriginal() }
                Button("上屏译文") { vm.commitTranslation() }.disabled(!coordinator.isReady)
            }
            if let toast = vm.toast {
                Text(toast).font(.caption).foregroundStyle(.green)
            }
            Spacer()
            Text(footerHint)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).fixedSize()
        }
        .controlSize(.small)
    }

    private var footerHint: String {
        switch vm.mode {
        case .candidate: return "↩ 原文 · ⇥ 译文 · ⌘V 粘贴 · ⎋ 取消"
        case .reading: return ReadingPanelPolicy.hint
        case .translator:
            let auto = IMESettings.flag(IMESettings.autoInsertAfterReturn, defaults: .standard)
            if vm.context != nil { return ReadingPanelPolicy.replyHint(autoInsert: auto) }
            return PanelSubmitPolicy.hint(closeAfterCopy: IMESettings.flag(IMESettings.closeAfterCopy, defaults: .standard),
                                          autoInsert: auto)
        }
    }

    private func providerLabel(_ id: String) -> String {
        switch id {
        case "apple": return "Apple 本地翻译（离线）"
        case "baidu": return "百度翻译（在线）"
        case "libretranslate": return "LibreTranslate（在线）"
        default: return id
        }
    }
}

/// 翻译面板输入框（2026-11-14 重写，修复“换行后第一行被遮挡”）：
/// 以前用 NSTextField：编辑时它的 field editor 放在一个按“开始编辑时的单行高度”建立的内部裁剪视图里，
/// 文字折到第二行时 field editor 会滚动到光标所在的最后一行 → 第一行被推出顶部；外框随后变高，下面留出空白。
/// 现在改为 NSScrollView + NSTextView：
/// - 输入框高度 = 用同一套 NSLayoutManager 实测的文本高度（含拼音组词的 marked text）+ textContainerInset；
/// - TopPinnedClipView：只要文本放得下，滚动位置永远钉在顶部（不可能出现“只露出下半截”）；
///   只有超过 maxLines 行时才允许内部滚动；
/// - 宽度随文字变长，超过 35 个汉字才换行（InputBoxSizer）。
/// 按键：↩ 复制译文（默认随后关闭面板）；⇧⌥↩ 复制并清空；⌥↩ 上屏译文；⌘↩/⇧↩ 上屏原文；⎋ 关闭；组词期间的 ↩ 交给拼音输入法。支持 ⌘V/⌘C/⌘X/⌘A/⌘Z。
struct ComposingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSettled: (String) -> Void
    var onSubmit: (SubmitKind) -> Void
    var onCancel: () -> Void
    var onLayout: (InputBoxLayout) -> Void

    static let font = NSFont.systemFont(ofSize: 16)
    @MainActor static let measurer = InputBoxTextMeasurer(font: font)
    @MainActor static let sizer = measurer.makeSizer()

    func makeNSView(context: Context) -> PanelInputScrollView {
        let m = Self.measurer
        let scroll = PanelInputScrollView()
        scroll.contentView = TopPinnedClipView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        let tv = PanelInputTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 25))
        tv.placeholder = placeholder
        m.configure(tv)                     // 与测量器完全相同的排版参数
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.focusRingType = .none
        tv.autoresizingMask = []            // 宽度/原点由 PanelInputScrollView.tile() 显式同步，不用自动伸缩（会算错）
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = text
        tv.delegate = context.coordinator
        tv.onMarkedTextChange = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            coordinator.relayout(tv)
        }
        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.relayout(tv) }
        return scroll
    }

    func updateNSView(_ scroll: PanelInputScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
            context.coordinator.relayout(tv)
        }
        scroll.syncDocumentFrame()
        scroll.pinToTopIfFits()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposingTextField
        weak var textView: PanelInputTextView?
        init(_ p: ComposingTextField) { parent = p }

        /// 用真实文字系统测量（含正在组词的拼音）→ 计算输入框尺寸
        func relayout(_ tv: NSTextView) {
            let m = ComposingTextField.measurer
            let shown = NSAttributedString(string: tv.string, attributes: m.attributes)
            let layout = m.layout(for: shown, sizer: ComposingTextField.sizer)
            parent.onLayout(layout)          // 调用方只在尺寸变化时才更新 @Published
            if let scroll = tv.enclosingScrollView as? PanelInputScrollView {
                scroll.allowsScrolling = layout.scrolls
                scroll.syncDocumentFrame()
                scroll.pinToTopIfFits()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            relayout(tv)
            if tv.hasMarkedText() { return }
            parent.text = tv.string
            parent.onSettled(tv.string)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }   // 回车用于确认拼音，交给输入法
            if selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                let m = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift, .option, .control]) ?? []
                parent.onSubmit(PanelSubmitPolicy.action(command: m.contains(.command), shift: m.contains(.shift),
                                                         option: m.contains(.option)))
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) { return true }   // 不插入制表符
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

/// 文本放得下时，滚动位置永远钉在顶部
final class TopPinnedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        let allows = (superview as? PanelInputScrollView)?.allowsScrolling ?? false
        if let doc = documentView, !allows || doc.frame.height <= r.height + 0.5 { r.origin.y = 0 }
        return r
    }
}

final class PanelInputScrollView: NSScrollView {
    /// 只有文本超过最大行数时才允许滚动
    var allowsScrolling = false {
        didSet { if allowsScrolling != oldValue { pinToTopIfFits() } }
    }

    func pinToTopIfFits() {
        guard !allowsScrolling, contentView.bounds.origin.y != 0 else { return }
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    override func tile() {
        super.tile()
        syncDocumentFrame()
        pinToTopIfFits()
    }

    /// 文档视图（NSTextView）宽度必须等于可见宽度、原点在 (0,0)：
    /// 用 autoresizingMask 时，滚动视图从 0 尺寸长大的过程中文本视图会被算成更宽（实测 850pt）且原点上移（-35pt），
    /// 结果是折行宽度不对、第一行被推出顶部——这正是“中文遮挡”的成因之一。
    func syncDocumentFrame() {
        guard let doc = documentView as? NSTextView else { return }
        let w = contentSize.width
        if abs(doc.frame.width - w) > 0.25 { doc.setFrameSize(NSSize(width: w, height: doc.frame.height)) }
        if doc.frame.origin != .zero { doc.setFrameOrigin(.zero) }
        doc.sizeToFit()                    // 按新宽度重新折行并更新高度
        if doc.frame.origin != .zero { doc.setFrameOrigin(.zero) }
    }

    override func scrollWheel(with event: NSEvent) {
        if allowsScrolling { super.scrollWheel(with: event) }
    }
}

final class PanelInputTextView: NSTextView {
    var placeholder = ""
    var onMarkedTextChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    // 拼音组词（marked text）变化也要重新量尺寸
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange?()
    }
    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?()
    }

    // 不滚动：除非外层允许（超过最大行数）
    override func scrollRangeToVisible(_ range: NSRange) {
        if (enclosingScrollView as? PanelInputScrollView)?.allowsScrolling == true { super.scrollRangeToVisible(range) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() && !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 16),
                                                        .foregroundColor: NSColor.placeholderTextColor]
            let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
            (placeholder as NSString).draw(at: NSPoint(x: x, y: textContainerInset.height), withAttributes: attrs)
        }
    }

    /// IME 进程没有主菜单，⌘V 等快捷键不会自动生效，这里直接处理。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.firstResponder === self, mods == .command || mods == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        if hasMarkedText() { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            // 粘贴纯文本：换行/制表符变空格，然后像打字一样触发翻译
            guard let raw = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return true }
            let s = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            insertText(s, replacementRange: selectedRange())
            return true
        case "c": copy(nil); return true
        case "x": cut(nil); return true
        case "a": selectAll(nil); return true
        case "z":
            if mods.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// 🔊 按钮：用 AppKit NSButton 实现，保证
/// - 在不能成为 key 的候选浮窗（nonactivatingPanel）里第一次点击就生效（acceptsFirstMouse）；
/// - 不抢焦点：不会成为第一响应者、不会让浮窗变 key，所以宿主应用里的组词（marked text）不会被提交，
///   翻译器模式下输入框也保持焦点；
/// - 动作只调用 coordinator.pronounceTapped()，不会上屏任何文字。
struct SpeakerButton: NSViewRepresentable {
    let help: String
    let action: () -> Void

    func makeNSView(context: Context) -> NoFocusButton {
        let b = NoFocusButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        b.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "美式发音")
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.setButtonType(.momentaryChange)
        b.refusesFirstResponder = true
        b.focusRingType = .none
        b.contentTintColor = .controlAccentColor
        b.toolTip = help
        b.setAccessibilityLabel("美式发音")
        b.target = context.coordinator
        b.action = #selector(Coordinator.fire(_:))
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    func updateNSView(_ b: NoFocusButton, context: Context) {
        context.coordinator.action = action
        if b.toolTip != help { b.toolTip = help }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire(_ sender: Any?) { action() }
    }
}

final class NoFocusButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
}

/// 纠正译法的两个输入框（弱引用登记，⇥ 在两栏之间切换）
@MainActor
final class CorrectionFieldRegistry {
    private var fields: [Int: WeakField] = [:]
    private final class WeakField { weak var field: NSTextField?; init(_ f: NSTextField) { field = f } }
    func register(_ f: NSTextField, tag: Int) { fields[tag] = WeakField(f) }
    func field(_ tag: Int) -> NSTextField? { fields[tag]?.field }
    func focus(_ tag: Int) {
        guard let f = field(tag), let w = f.window else { return }
        w.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }
}

/// 单行输入框（AppKit）：↩ 保存、⎋ 取消、⇥ 切到另一栏；支持拼音等输入法组词（组词期间的 ↩/⎋ 交给输入法）
struct CorrectionField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var tag: Int
    var autoFocus: Bool
    var registry: CorrectionFieldRegistry
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 13)
        f.bezelStyle = .roundedBezel
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        registry.register(f, tag: tag)
        if autoFocus {
            DispatchQueue.main.async { [registry, tag] in registry.focus(tag) }
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CorrectionField
        init(_ p: CorrectionField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if textView.hasMarkedText() { return false }       // 组词中：交给输入法
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                parent.registry.focus(parent.tag == 0 ? 1 : 0); return true
            default:
                return false
            }
        }
    }
}
