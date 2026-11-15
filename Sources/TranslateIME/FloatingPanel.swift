import AppKit
import SwiftUI
import Combine
import IMECore

/// 候选浮窗不会成为 key：让第一次点击直接送达按钮（🔊、上屏），而不是被当成“激活窗口”的点击吞掉。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 剪贴板“英文阅读”模式下接收 ↩ / ⎋ 等按键；返回 true 表示已处理
    var keyHandler: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { keyHandler != nil || super.acceptsFirstResponder }
    override func keyDown(with event: NSEvent) {
        if let h = keyHandler, h(event) { return }
        super.keyDown(with: event)
    }
}

final class FloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class PanelController {
    let vm: PanelViewModel
    private let coordinator: TranslationCoordinator
    private let monitor: LatencyMonitor
    private let panel = FloatingPanel()
    private let hosting: FirstMouseHostingView<PanelRootView>
    private var cancellables = Set<AnyCancellable>()
    private var anchorTopLeft = NSPoint.zero
    private var lastAnchor: NSPoint?
    private var lastSize = NSSize.zero
    private var caretRect: NSRect?
    private var previousApp: NSRunningApplication?
    private var relayoutTask: Task<Void, Never>?
    private var translatorScreenFrame: NSRect?
    private let copier: TranslationCopier
    private let inputSwitcher: InputSourceSwitcher
    private var reassertTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// 每次打开翻译面板 +1；延迟关闭前核对，防止关掉“下一次”打开的面板
    private var session = 0
    /// 剪贴板触发的英文原文（阅读模式 / 回复模式的上下文）
    private var readingText: String?
    /// 原应用的光标行矩形（Cocoa 坐标）：⌃⌥T 面板与剪贴板面板跟随它
    private var targetAnchor: PanelAnchor?
    /// 回复要落回的来源应用 + 焦点窗口（剪贴板触发 / ⌃⌥T 打开时记下）
    private var replySource: ReplySource?
    /// 阅读 ⇄ 回复 会话：来源更新、被新复制打断时暂存草稿、同一来源再回复时恢复
    private(set) var flow = ReplySession<ReplySourceKey>()
    /// 正在进行的“等译文 → 填入”任务：新的英文复制到来时取消
    private var replyTask: Task<Void, Never>?
    /// 自测用：不切换系统输入源（避免改动用户当前输入法）
    var skipInputSourceSwitch = false
    private(set) var lastCaretSource: CaretLocator.Source = .none
    /// 回车自动填入：只等待译文、不写剪贴板的复制器 + 插入器
    private let translationWaiter: TranslationCopier
    private let pasteSender = CGEventPasteSender()
    private let clientInserter = IMKClientInserter()
    private lazy var inserter = AutoInserter(pasteboard: SystemPasteboardStore(), keys: pasteSender,
                                             client: clientInserter,
                                             markOwn: { cc in OwnPasteboard.onOwnChange?(cc) })

    init(coordinator: TranslationCoordinator, host: AnyView, monitor: LatencyMonitor = .shared,
         clipboard: ClipboardWriting = SystemClipboard(),
         inputSources: InputSourceSystem? = nil) {
        self.coordinator = coordinator
        self.monitor = monitor
        self.copier = TranslationCopier(coordinator: coordinator, clipboard: clipboard)
        self.inputSwitcher = InputSourceSwitcher(system: inputSources ?? TISInputSourceSystem())
        self.translationWaiter = TranslationCopier(coordinator: coordinator, clipboard: NullClipboard())
        let vm = PanelViewModel()
        self.vm = vm
        hosting = FirstMouseHostingView(rootView: PanelRootView(vm: vm, coordinator: coordinator, host: host))
        panel.contentView = hosting
        vm.onCancel = { [weak self] in self?.hide() }
        vm.onStartReply = { [weak self] in self?.startReply() }
        vm.onBeginCorrection = { [weak self] in self?.beginCorrection() }
        vm.onSaveCorrection = { [weak self] in self?.saveCorrection() }
        vm.onEndCorrection = { [weak self] in self?.endCorrection() }
        // ⎋（窗口级）：纠正编辑器开着时只关编辑器
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.vm.correcting { self.endCorrection() } else { self.hide() }
        }
        hosting.keyHandler = { [weak self] event in
            MainActor.assumeIsolated { self?.handleReadingKey(event) ?? false }
        }

        // 状态变化 → 节流后再布局（≥16ms 合并），避免每次按键都做一遍 SwiftUI 布局
        coordinator.objectWillChange.merge(with: vm.objectWillChange)
            .sink { [weak self] _ in self?.scheduleRelayout() }
            .store(in: &cancellables)
        // 输入框尺寸变化（换行/变高）不走 16ms 节流：下一轮主循环立即重新布局面板，避免内容比窗口大被裁切
        vm.$inputLayout.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.relayout() } }
            .store(in: &cancellables)
    }

    /// 启动时调用：提前创建 SwiftUI 视图树并做一次布局，避免第一次按键时才付出初始化成本
    func prewarm() {
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
    }

    var isTranslatorVisible: Bool { panel.isVisible && vm.mode == .translator }
    var isReadingVisible: Bool { panel.isVisible && vm.mode == .reading }
    /// 用户正在用翻译面板或正在组词：剪贴板监测不打断
    var isBusyForClipboard: Bool { panel.isVisible && vm.mode == .candidate }

    /// 给剪贴板监测用：此刻能否弹出 / 覆盖
    var clipboardPanelState: ClipboardPanelState {
        // 用前台应用判断（NSApp.isActive 在切走的瞬间可能还没更新）
        let ownFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        // TranslateIME 自己的其他窗口（单词本、保存面板）在前台：复制来自那里，不打扰
        if ownFront, let kw = NSApp.keyWindow, kw !== panel { return .busy }
        guard panel.isVisible else { return ownFront ? .busy : .idle }
        // 正在纠正译法（可能在编辑框里复制/粘贴）：不打断
        if vm.correcting { return .busy }
        switch vm.mode {
        case .reading: return .reading(current: readingText)
        case .translator:
            // 本应用在前台（用户还在面板里打字）：复制来自面板自己的输入框，不打断
            if ownFront { return .busy }
            return .replying(current: readingText)
        case .candidate: return .busy
        }
    }

    // MARK: 剪贴板英文阅读模式（自动弹出，↩ 转中文回复）

    var panelFrame: NSRect { panel.frame }

    /// anchor 由 AppContext 在后台用锚点链算好（AX 不在主线程/按键路径上）
    func showReading(english: String, anchor: PanelAnchor = .fallback, source: ReplySource? = nil) {
        guard !isBusyForClipboard else { return }
        // 正在中→英回复（或 ⌃⌥T 中文输入）时复制了别的英文：收起拼音组词、暂存草稿、取消旧回复、恢复输入源
        let wasReplying = panel.isVisible && vm.mode == .translator
        let draft = wasReplying ? finishCompositionForSwitch() : ""
        let transition = flow.clipboardEnglish(english, from: source?.key, draft: draft)
        if transition.cancelPending { replyTask?.cancel(); replyTask = nil }
        if transition.leftReply {
            reassertTask?.cancel(); reassertTask = nil
            if !skipInputSourceSwitch { inputSwitcher.restore() }    // 离开回复模式：恢复原输入源
            vm.hint = nil
        }
        lastOverride = transition
        if let source { replySource = source }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        targetAnchor = anchor == .fallback ? nil : anchor
        // 从回复模式切过来且没有新位置：按首次显示处理（右上角），不停在旧的输入位置
        let first = !panel.isVisible || (transition.leftReply && targetAnchor == nil)
        if targetAnchor != nil { lastAnchor = nil; lastSize = .zero }
        readingText = english
        vm.mode = .reading
        vm.context = nil
        vm.inputText = ""
        vm.inputLayout = PanelViewModel.defaultInputLayout
        vm.resetTransient()
        session &+= 1
        closeTask?.cancel(); closeTask = nil
        coordinator.reset()
        coordinator.update(text: english)
        caretRect = nil
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        translatorScreenFrame = vf
        if first {
            // 右上角，像通知一样，不挡住正在看的内容
            anchorTopLeft = NSPoint(x: vf.maxX - PanelRootView.readingWidth - 24, y: vf.maxY - 16)
            lastAnchor = nil; lastSize = .zero
        }
        // 非激活面板成为 key：原应用仍在前台（不切换应用、不改输入法），但 ↩ / ⎋ 会先到面板。
        panel.allowsKey = true
        panel.alphaValue = (first && !transition.leftReply) ? 0 : 1
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(hosting)
        relayout()
        panel.alphaValue = 1
    }

    /// 在激活本应用之前调用：此时前台仍是用户的应用
    private func locateCaret(in app: NSRunningApplication?) {
        let t0 = LatencyMonitor.now()
        let found = CaretLocator.locate(in: app)
        targetAnchor = found.map { .rect($0.rect, .caret) }
        lastCaretSource = found?.source ?? .none
        monitor.record(.clientIPC, milliseconds: LatencyMonitor.ms(since: t0), note: "caret-\(lastCaretSource.rawValue)")
    }

    func hideReading() { if isReadingVisible { hide() } }

    /// 最近一次 showReading 的切换信息（日志/自测用）
    private(set) var lastOverride: ReplySession<ReplySourceKey>.Transition?

    /// 面板里的中文输入框
    private var inputTextView: PanelInputTextView? {
        func find(_ v: NSView) -> PanelInputTextView? {
            if let t = v as? PanelInputTextView { return t }
            for sub in v.subviews { if let t = find(sub) { return t } }
            return nil
        }
        return find(hosting)
    }

    /// 被新复制打断时：取消正在组词的拼音（只在本面板的输入框里，绝不插入到别的应用），返回已上屏的草稿
    private func finishCompositionForSwitch() -> String {
        guard let tv = inputTextView else { return vm.inputText }
        if tv.hasMarkedText() {
            let marked = tv.markedRange()
            let ns = tv.string as NSString
            let committed = (marked.location != NSNotFound && NSMaxRange(marked) <= ns.length)
                ? ns.replacingCharacters(in: marked, with: "") : vm.inputText
            tv.inputContext?.discardMarkedText()        // 让拼音输入法取消本次组词
            if tv.hasMarkedText() { tv.unmarkText() }
            tv.string = committed                        // 丢掉未确认的拼音字母
            return committed
        }
        return tv.string.isEmpty ? vm.inputText : tv.string
    }

    /// 自测：在面板输入框里模拟“已输入的中文 + 正在组词的拼音”
    func selfTestType(committed: String, marked: String) {
        vm.inputText = committed
        guard let tv = inputTextView else { return }
        tv.string = committed
        tv.setSelectedRange(NSRange(location: (committed as NSString).length, length: 0))
        tv.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 自测：当前状态（不含用户文字以外的隐私；只用于本地自测输出）
    var selfTestState: (mode: String, reading: String?, input: String, marked: Bool) {
        let mode: String
        switch (panel.isVisible, vm.mode) {
        case (false, _): mode = "hidden"
        case (true, .reading): mode = "reading"
        case (true, .translator): mode = "replying"
        case (true, .candidate): mode = "candidate"
        }
        return (mode, readingText, inputTextView?.string ?? vm.inputText, inputTextView?.hasMarkedText() ?? false)
    }

    /// 阅读模式按键：↩ 回复、⎋ 关闭、⌘ 快捷键放行、其他键 → 关闭面板并把这个键还给原应用
    private func handleReadingKey(_ event: NSEvent) -> Bool {
        guard isReadingVisible, !vm.correcting else { return false }
        let key: ReadingPanelKey
        switch Int(event.keyCode) {
        case 36, 76: key = .returnKey            // Return / 小键盘 Enter
        case 53: key = .escape
        default:
            key = event.modifierFlags.intersection([.command, .control]).isEmpty ? .other : .commandShortcut
        }
        switch ReadingPanelPolicy.command(for: key) {
        case .startReply: startReply(); return true
        case .close: hide(); return true
        case .passThrough: return false
        case .dismissAndForward: dismissAndForward(event); return true
        }
    }

    // MARK: 纠正译法（存入我的词表 → 重建术语索引 → 重新翻译；焦点回到原输入框）

    /// AppContext 注入：写入用户词表并重新加载（后台），完成后返回
    var correctionSaver: ((String, String) async throws -> UserGlossaryRow)?

    func beginCorrection() {
        guard panel.isVisible, vm.mode != .candidate, !vm.correcting else { return }
        var selection = ""
        if vm.mode == .translator, let tv = inputTextView, !tv.hasMarkedText() {
            let r = tv.selectedRange(), ns = tv.string as NSString
            if r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length { selection = ns.substring(with: r) }
        }
        let whole = vm.mode == .reading ? (readingText ?? "") : (inputTextView?.string ?? vm.inputText)
        var translation: String?
        if case .ready(let r) = coordinator.phase { translation = r.translated }
        let prefill = CorrectionPrefill.make(selection: selection, whole: whole, translation: translation)
        vm.correctionSource = prefill.source
        vm.correctionTarget = prefill.target
        vm.correctionFocusTarget = !prefill.source.isEmpty
        vm.correctionError = nil
        vm.correcting = true
        panel.allowsKey = true
        if !panel.isKeyWindow { panel.makeKey() }
    }

    func endCorrection() {
        guard vm.correcting else { return }
        vm.correcting = false
        vm.correctionError = nil
        restorePanelFocus()
    }

    func saveCorrection() {
        guard vm.correcting else { return }
        let src = vm.correctionSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = vm.correctionTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !dst.isEmpty else { vm.correctionError = "原词和正确译法都要填写"; return }
        guard src != dst else { vm.correctionError = "译法与原词相同"; return }
        guard let saver = correctionSaver else { vm.correctionError = "词表未就绪"; return }
        let sess = session
        Task { @MainActor [weak self] in
            do {
                let row = try await saver(src, dst)
                guard let self, sess == self.session, self.panel.isVisible else { return }
                self.vm.correcting = false
                self.restorePanelFocus()
                self.retranslate()
                self.vm.showToast("已存入我的词表：\(row.zh) → \(row.en)", seconds: 2.4)
            } catch {
                self?.vm.correctionError = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// 词表变化后用同一段原文重新翻译（缓存已在词表变化时清空）
    func retranslate() {
        let text = vm.mode == .reading ? (readingText ?? "") : (inputTextView?.string ?? vm.inputText)
        guard !text.isEmpty else { return }
        coordinator.reset()
        coordinator.update(text: text)
    }

    private func restorePanelFocus() {
        if vm.mode == .translator, let tv = inputTextView {
            panel.makeFirstResponder(tv)
        } else {
            panel.makeFirstResponder(hosting)
        }
    }

    /// 自测：模拟“纠正译法”（不经过界面输入）
    func selfTestCorrection(source: String, target: String) {
        beginCorrection()
        vm.correctionSource = source
        vm.correctionTarget = target
        saveCorrection()
    }
    func selfTestSelect(_ word: String) {
        guard let tv = inputTextView else { return }
        let r = (tv.string as NSString).range(of: word)
        if r.location != NSNotFound { tv.setSelectedRange(r) }
    }
    var selfTestFirstResponderIsInput: Bool {
        guard let tv = inputTextView else { return false }
        return panel.firstResponder === tv
    }
    var selfTestTranslation: String? {
        if case .ready(let r) = coordinator.phase { return r.translated }
        return nil
    }

    /// 切换到中→英回复：清空输入、切到简体拼音、聚焦输入框；英文原文作为小字上下文保留
    func startReply() {
        guard isReadingVisible else { return }
        let draft = flow.startReply()          // 同一来源：恢复被打断时暂存的中文草稿
        showTranslator(prefill: draft ?? "", context: readingText, returnTo: previousApp, keepPosition: true)
    }

    private func dismissAndForward(_ event: NSEvent) {
        hide()
        // 把按键补发给原应用（需要辅助功能授权；没授权时这个键会丢失，面板仍会关闭）
        guard AXIsProcessTrusted(), let down = event.cgEvent?.copy() else { return }
        let up = down.copy()
        up?.type = .keyUp
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)    // 等原应用窗口重新成为 key
            down.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 候选模式（IME 组词时，跟随光标，不抢焦点）

    func showCandidate(caret: NSRect,
                       onCommitOriginal: @escaping () -> Void,
                       onCommitTranslation: @escaping () -> Void,
                       onCancel: @escaping () -> Void) {
        if isReadingVisible { hide() }
        let first = !panel.isVisible || vm.mode != .candidate
        vm.mode = .candidate
        panel.allowsKey = false
        vm.onCommitOriginal = onCommitOriginal
        vm.onCommitTranslation = onCommitTranslation
        vm.onCancel = onCancel
        caretRect = caret
        if first {
            // 首次显示：同步布局一次再显示，避免闪到旧位置
            lastAnchor = nil; lastSize = .zero
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            relayout()
            panel.alphaValue = 1
        } else {
            scheduleRelayout()
        }
    }

    func hideCandidate() {
        if vm.mode == .candidate { hide() }
    }

    // MARK: 翻译器模式（热键唤起，可输入）

    func showTranslator(prefill: String, context: String? = nil,
                        returnTo: NSRunningApplication? = nil, keepPosition: Bool = false) {
        let wasVisible = panel.isVisible
        previousApp = returnTo ?? NSWorkspace.shared.frontmostApplication
        if !(keepPosition && wasVisible) {
            locateCaret(in: previousApp)
            if let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                replySource = ReplySource.capture(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
            } else {
                replySource = nil
            }
            flow.openTranslator(source: replySource?.key)
        }
        vm.mode = .translator
        vm.context = context
        vm.inputText = prefill
        panel.allowsKey = true
        vm.onCancel = { [weak self] in self?.hide() }
        vm.onCommitOriginal = { [weak self] in self?.commitFromTranslator(original: true) }
        vm.onCommitTranslation = { [weak self] in self?.commitFromTranslator(original: false) }
        vm.onCopyTranslation = { [weak self] clear in self?.copyTranslation(clearAndStay: clear) }
        session &+= 1
        vm.resetTransient()
        coordinator.reset()
        coordinator.update(text: prefill)
        caretRect = nil

        if !(keepPosition && wasVisible && translatorScreenFrame != nil) {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main ?? NSScreen.screens[0]
            let vf = screen.visibleFrame
            translatorScreenFrame = vf
            anchorTopLeft = NSPoint(x: vf.midX - 190, y: vf.minY + vf.height * 0.68)
            lastAnchor = nil; lastSize = .zero
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        relayout()
        switchToPinyin()
    }

    // MARK: 输入源：打开面板切到简体拼音，关闭时恢复

    private func switchToPinyin() {
        guard !skipInputSourceSwitch else { return }
        guard IMESettings.flag(IMESettings.autoSwitchPinyin, defaults: .standard) else { return }
        switch inputSwitcher.activatePinyin() {
        case .switched, .alreadyActive:
            vm.hint = nil
            // 应用激活是异步的：焦点稳定后再确认一次，防止被激活过程切回去
            reassertTask?.cancel()
            reassertTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled, self.isTranslatorVisible else { return }
                self.inputSwitcher.reassertIfNeeded()
            }
        case .noPinyin:
            vm.hint = "未找到已启用的“拼音 – 简体”输入法：可在 系统设置 › 键盘 › 输入法 中添加，或手动切换输入法。"
        case .selectFailed:
            vm.hint = "无法自动切换到简体拼音，请手动切换输入法。"
        }
    }

    // MARK: ↩ 复制译文（默认随后关闭面板）/ ⇧⌥↩ 复制并清空

    private func copyTranslation(clearAndStay: Bool) {
        let text = vm.inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        if !clearAndStay, IMESettings.flag(IMESettings.autoInsertAfterReturn, defaults: .standard) {
            submitAndInsert(text); return
        }
        let action: PanelSubmitAction = clearAndStay ? .copyAndClear : .copyTranslation
        let mySession = session
        closeTask?.cancel(); closeTask = nil
        if !coordinator.isReady { vm.showToast("翻译中…", seconds: 30) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.copier.copyTranslation(of: text)
            guard self.session == mySession, self.isTranslatorVisible else { return }   // 面板已关闭/重开
            let closeAfter = IMESettings.flag(IMESettings.closeAfterCopy, defaults: .standard)
            switch PanelSubmitPolicy.afterCopy(outcome, action: action, closeAfterCopy: closeAfter) {
            case .closeAfter(let delay):
                self.vm.showToast("已复制 ✓", seconds: delay + 1)
                self.closeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, !Task.isCancelled, self.session == mySession, self.isTranslatorVisible else { return }
                    self.hide()          // 清空输入、恢复输入源、回到原应用，可直接 ⌘V
                }
            case .clearAndStay:
                self.vm.showToast("已复制 ✓，请输入下一句")
                self.vm.inputText = ""
                self.coordinator.reset()
            case .stay:
                self.vm.showToast("已复制 ✓")
            case .showError(let message):
                self.vm.showToast("翻译失败，未复制：\(message)", seconds: 5)
            case .nothing:
                if case .nothingToCopy = outcome { NSSound.beep() }
                self.vm.toast = nil
            }
        }
    }

    // MARK: ↩ 自动填入原应用输入框（只插入文字，绝不发送回车）

    private var ownInputSourcePrefix: String { Bundle.main.bundleIdentifier ?? "com.example.inputmethod.TranslateIME" }

    private func submitAndInsert(_ text: String) {
        let mySession = session
        closeTask?.cancel(); closeTask = nil
        if !coordinator.isReady { vm.showToast("翻译中…", seconds: 30) }
        replyTask?.cancel()
        replyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.translationWaiter.copyTranslation(of: text)   // 只等译文，不写剪贴板
            guard self.session == mySession, self.isTranslatorVisible else { return }
            let result: String
            switch outcome {
            case .copied(let r): result = r
            case .failed(let message): self.vm.showToast("翻译失败，未填入：\(message)", seconds: 5); return
            case .nothingToCopy: NSSound.beep(); self.vm.toast = nil; return
            case .superseded: self.vm.toast = nil; return
            }
            let target = self.previousApp
            let source = self.replySource
                ?? target.map { ReplySource(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, window: nil) }
            let trusted = AXIsProcessTrusted()               // 每次实时检查
            let sourceAfter = self.inputSwitcher.savedSourceID ?? TISInputSourceSystem().currentSourceID()
            let imeInTarget = (sourceAfter?.hasPrefix(self.ownInputSourcePrefix) ?? false)
            let panelRect = self.panel.frame
            self.vm.showToast("已翻译 ✓ 正在填入…", seconds: 3)
            // 等 ↩ 松开：长按回车的连发绝不能落到原应用（那会变成“发送”）
            var waited = 0
            while KeyState.returnIsDown && waited < 40 { try? await Task.sleep(nanoseconds: 25_000_000); waited += 1 }
            guard self.session == mySession, self.isTranslatorVisible else { return }
            self.hide()                                   // 恢复输入源 → 回到原应用
            let own = ProcessInfo.processInfo.processIdentifier
            guard let src = source, src.pid != own else {
                OwnPasteboard.write(result)
                FeedbackHUD.show(ReplyInsertResult.notFound.feedback, near: panelRect)
                PlacementLog.write("reply result=notFound target=none reason=noSource")
                return
            }
            if trusted {
                // 英文总是复制并保留 → 回到来源窗口 → 找输入框 → AXSelectedText / ⌘V（绝不发回车）
                let driver = SystemReplyDriver(source: src)
                let inserter = ReplyInserter(driver: driver, pasteboard: SystemPasteboardStore(),
                                             markOwn: { cc in OwnPasteboard.onOwnChange?(cc) })
                let t0 = LatencyMonitor.now()
                let report = await inserter.run(result, accessibilityTrusted: true)
                if report.result == .cancelled {
                    PlacementLog.write(report.logLine + " app=\(src.bundleID ?? "-")")
                    return
                }
                FeedbackHUD.show(report.result.feedback, near: report.chosen?.frame ?? panelRect)
                PlacementLog.write(report.logLine + " app=\(src.bundleID ?? "-") window=\(src.window != nil)"
                                   + String(format: " ms=%.0f", LatencyMonitor.ms(since: t0)))
                return
            }
            // 未授权辅助功能：英文已复制；TranslateIME 正是来源应用的输入法时，用 IMK 插到它的焦点处
            OwnPasteboard.write(result)
            var inserted = false
            if imeInTarget, let app = target {
                for _ in 0..<32 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                for _ in 0..<24 where AppContext.shared.activeController?.clientBundleID != app.bundleIdentifier {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                self.clientInserter.expectedBundleID = app.bundleIdentifier
                inserted = self.clientInserter.insertIntoClient(result)
            }
            FeedbackHUD.show(inserted ? ReplyInsertResult.insertedAX.feedback : InsertionPlanner.copyOnlyHint, near: panelRect)
            PlacementLog.write("reply result=\(inserted ? "imk" : "copyOnly") target=none trusted=false app=\(src.bundleID ?? "-")")
        }
    }

    func hide() {
        let wasTranslator = panel.isVisible && vm.mode == .translator
        relayoutTask?.cancel(); relayoutTask = nil
        reassertTask?.cancel(); reassertTask = nil
        closeTask?.cancel(); closeTask = nil
        panel.orderOut(nil)
        coordinator.reset()
        vm.inputText = ""
        vm.inputLayout = PanelViewModel.defaultInputLayout
        vm.resetTransient()
        vm.mode = .candidate
        vm.context = nil
        readingText = nil
        targetAnchor = nil
        replySource = nil
        flow.hide()                        // ⎋ / 关闭：丢弃暂存的草稿
        caretRect = nil
        translatorScreenFrame = nil
        if wasTranslator {
            inputSwitcher.restore()          // 先恢复输入源，再回到原应用
            previousApp?.activate()
            previousApp = nil
        }
    }

    private func commitFromTranslator(original: Bool) {
        let text: String
        if original {
            text = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let r = coordinator.result else { NSSound.beep(); return }
            text = r.translated
        }
        guard !text.isEmpty else { return }
        hide()
        PasteCommitter.commit(text)
    }

    // MARK: 布局（节流 + 仅在变化时更新窗口几何）

    private func scheduleRelayout() {
        guard relayoutTask == nil, panel.isVisible else { return }
        relayoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self, !Task.isCancelled else { return }
            self.relayoutTask = nil
            let t0 = LatencyMonitor.now()
            self.relayout()
            self.monitor.record(.panelUpdate, milliseconds: LatencyMonitor.ms(since: t0))
        }
    }

    private func relayout() {
        guard panel.isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        if vm.mode == .candidate, let c = caretRect {
            let screen = NSScreen.screens.first { $0.frame.contains(c.origin) } ?? NSScreen.main ?? NSScreen.screens[0]
            let vf = screen.visibleFrame
            let x = min(max(c.minX, vf.minX + 8), vf.maxX - size.width - 8)
            var topY = c.minY - 6
            if topY - size.height < vf.minY { topY = c.maxY + 6 + size.height }   // 下方放不下 → 放到光标上方
            anchorTopLeft = NSPoint(x: x, y: topY)
        } else if vm.mode != .candidate, let a = targetAnchor,
                  let tl = AnchorChain.topLeft(for: a, size: size,
                                               screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }) {
            // 跟随原应用：选中文字/光标/输入框（贴着上下放）、鼠标右下方、或焦点窗口下三分之一；始终在屏幕内
            anchorTopLeft = tl
        } else if vm.mode != .candidate, let vf = translatorScreenFrame {
            // 面板随输入框变宽/变高：保持在屏幕内（向左、向上让位）
            anchorTopLeft.x = max(vf.minX + 8, min(anchorTopLeft.x, vf.maxX - size.width - 8))
            if anchorTopLeft.y - size.height < vf.minY + 8 {
                anchorTopLeft.y = min(vf.maxY - 8, vf.minY + 8 + size.height)
            }
        }

        var needAnchor = lastAnchor != anchorTopLeft
        if size != lastSize {
            panel.setContentSize(size)
            lastSize = size
            needAnchor = true
        }
        if needAnchor {
            panel.setFrameTopLeftPoint(anchorTopLeft)
            lastAnchor = anchorTopLeft
        }
    }
}
