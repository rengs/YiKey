import Cocoa
import InputMethodKit
import Carbon.HIToolbox
import IMECore

/// 英文组词模式（↩ 上屏原文 · ⇥ 上屏译文 · ⎋ 取消 · 空格追加 · ⌫ 删除 · ⌘V 把剪贴板英文粘贴进组词并翻译）。
///
/// 流畅度设计：handle() 内（主线程、同步）只做
///   1) NSEvent → ComposeKey 映射 + CompositionBuffer 状态机（微秒级）
///   2) 一次 setMarkedText（对宿主应用的 IPC，原生输入法同样必须做）
///   3) 登记“稍后更新浮窗”（合并成一次主线程异步更新）
/// 其余全部延后：取光标矩形(IPC)、coordinator.update(查缓存/起后台任务)、SwiftUI 布局(节流 ≥16ms)、翻译(防抖+后台)。
/// 每次 handle() 的耗时都会记入 LatencyMonitor（keyHandling，预算 5ms），超预算写日志。
@objc(TranslateIMEInputController)
final class InputController: IMKInputController {
    private var composition = CompositionBuffer()
    private var cachedCaret: NSRect?
    private var applyScheduled = false
    private var lastKeyStamp: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    private var isOwnClient = false
    /// 当前客户端应用的 Bundle ID（激活时取一次）
    private(set) var clientBundleID: String?
    private let notFound = NSRange(location: NSNotFound, length: NSNotFound)
    private static let markedAttributes: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]

    private var textClient: IMKTextInput? { client() as? IMKTextInput }

    // MARK: IMK 生命周期

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // bundleIdentifier() 可能是 IPC，只在激活时取一次，不放在按键路径上
        clientBundleID = (sender as? IMKTextInput)?.bundleIdentifier()
        isOwnClient = clientBundleID == Bundle.main.bundleIdentifier
        MainActor.assumeIsolated { AppContext.shared.activeController = self }
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            self.commitOriginal(using: sender as? IMKTextInput)
            if AppContext.shared.activeController === self { AppContext.shared.activeController = nil }
        }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated { self.commitOriginal(using: sender as? IMKTextInput) }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        let t0 = LatencyMonitor.now()
        let handled = MainActor.assumeIsolated { self.process(event, sender, startedAt: t0) }
        LatencyMonitor.shared.record(.keyHandling, milliseconds: LatencyMonitor.ms(since: t0),
                                     note: handled ? "consumed" : "pass")
        return handled
    }

    // MARK: 按键路径（必须保持轻量）

    @MainActor
    private func process(_ event: NSEvent?, _ sender: Any?, startedAt t0: UInt64) -> Bool {
        guard !isOwnClient, let event, event.type == .keyDown,
              let client = sender as? IMKTextInput else { return false }

        let wasEmpty = composition.isEmpty
        var key = Self.key(from: event)
        if key == .modified, Self.isCommandV(event),
           IMESettings.flag(IMESettings.pasteIntoComposition, defaults: .standard) {
            // ⌘V：读剪贴板（通常 < 1ms）。英文 → 进入组词并翻译；组词中 → 追加；其它情况放行给应用正常粘贴。
            let io = LatencyMonitor.now()
            let pasted = NSPasteboard.general.string(forType: .string)
            LatencyMonitor.shared.record(.clientIPC, milliseconds: LatencyMonitor.ms(since: io), note: "pasteboard")
            if let pasted { key = .paste(pasted) }
        }
        switch composition.handle(key) {
        case .passThrough:
            return false
        case .flushThenPass:
            commitOriginal(using: client); return false
        case .update:
            if wasEmpty { cachedCaret = nil }
            let io = LatencyMonitor.now()
            client.setMarkedText(
                NSAttributedString(string: composition.text, attributes: Self.markedAttributes),
                selectionRange: NSRange(location: composition.text.utf16.count, length: 0),
                replacementRange: notFound)
            LatencyMonitor.shared.record(.clientIPC, milliseconds: LatencyMonitor.ms(since: io), note: "setMarkedText")
            scheduleApply(keyStamp: t0)
            return true
        case .commitOriginal:
            commitOriginal(using: client); return true
        case .commitTranslation:
            commitTranslation(using: client); return true
        case .cancel:
            cancelComposition(using: client); return true
        }
    }

    static func isCommandV(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "v" || Int(event.keyCode) == kVK_ANSI_V
    }

    private static func key(from event: NSEvent) -> ComposeKey {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.intersection([.command, .control, .option]).isEmpty { return .modified }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .returnKey
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        case kVK_Delete: return .delete
        default: break
        }
        if let s = event.characters, !s.isEmpty,
           s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            return .character(s)
        }
        return .other
    }

    // MARK: 延后的浮窗更新（合并 + 空闲刷新）

    @MainActor
    private func scheduleApply(keyStamp: UInt64) {
        lastKeyStamp = keyStamp

        // 停笔 250ms 后重新取一次光标位置（行折行等造成的位置变化），不在按键路径上做
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, !self.composition.isEmpty else { return }
            self.cachedCaret = nil
            self.scheduleApplyNow()
        }
        scheduleApplyNow()
    }

    @MainActor
    private func scheduleApplyNow() {
        guard !applyScheduled else { return }       // 连续按键合并成一次
        applyScheduled = true
        Task { @MainActor [weak self] in self?.applyNow() }
    }

    @MainActor
    private func applyNow() {
        applyScheduled = false
        guard !composition.isEmpty, let client = textClient else { return }
        if cachedCaret == nil {
            let io = LatencyMonitor.now()
            cachedCaret = caretRect(client)
            LatencyMonitor.shared.record(.clientIPC, milliseconds: LatencyMonitor.ms(since: io), note: "caret")
        }
        let ctx = AppContext.shared
        ctx.coordinator.update(text: composition.text)      // 命中缓存则同步出结果；否则防抖 + 后台翻译
        ctx.panel.showCandidate(
            caret: cachedCaret ?? .zero,
            onCommitOriginal: { [weak self] in self?.commitOriginal(using: nil) },
            onCommitTranslation: { [weak self] in self?.commitTranslation(using: nil) },
            onCancel: { [weak self] in self?.cancelComposition(using: nil) })
        LatencyMonitor.shared.record(.keyToPanel, milliseconds: LatencyMonitor.ms(since: lastKeyStamp))
    }

    // MARK: 上屏

    @MainActor
    private func commitOriginal(using explicit: IMKTextInput?) {
        guard !composition.isEmpty else { return }
        guard let client = explicit ?? textClient else { finish(); return }
        client.insertText(composition.text, replacementRange: notFound)
        finish()
    }

    @MainActor
    private func commitTranslation(using explicit: IMKTextInput?) {
        guard let client = explicit ?? textClient else { return }
        let trimmed = composition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .ready(let r) = AppContext.shared.coordinator.phase, r.original == trimmed else {
            NSSound.beep(); return        // 译文还没好（或已过期）
        }
        client.insertText(r.translated, replacementRange: notFound)
        finish()
    }

    @MainActor
    private func cancelComposition(using explicit: IMKTextInput?) {
        if let client = explicit ?? textClient {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        }
        finish()
    }

    @MainActor
    private func finish() {
        composition.clear()
        idleTask?.cancel(); idleTask = nil
        cachedCaret = nil
        AppContext.shared.panel.hideCandidate()
        AppContext.shared.coordinator.reset()
    }

    private func caretRect(_ client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        let marked = client.markedRange()
        let idx = marked.location == NSNotFound ? max(0, client.selectedRange().location) : marked.location
        _ = client.attributes(forCharacterIndex: idx, lineHeightRectangle: &rect)
        if rect == .zero {
            let p = NSEvent.mouseLocation
            rect = NSRect(x: p.x, y: p.y, width: 1, height: 16)
        }
        return rect
    }

    /// 当前客户端的光标行矩形（Cocoa 屏幕坐标）；拿不到返回 nil（不退回鼠标位置）。只在打开面板时调用，不在按键路径上。
    @MainActor func currentCaretRect() -> NSRect? {
        guard let c = textClient else { return nil }
        var rect = NSRect.zero
        let marked = c.markedRange()
        let idx = marked.location == NSNotFound ? max(0, c.selectedRange().location) : marked.location
        _ = c.attributes(forCharacterIndex: idx, lineHeightRectangle: &rect)
        return rect == .zero ? nil : rect
    }

    /// 回复模式自动填入：直接把文字插入客户端（不碰剪贴板，不发回车）
    @MainActor func insertIntoClient(_ text: String) -> Bool {
        guard let c = textClient else { return false }
        if !composition.isEmpty { commitOriginal(using: c) }
        c.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// 热键预填：当前 IME 激活的应用里的选中文本
    func currentSelectedText() -> String? {
        guard let c = textClient else { return nil }
        let r = c.selectedRange()
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        return c.attributedSubstring(from: r)?.string
    }

    // MARK: 状态栏菜单

    override func menu() -> NSMenu! {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            if on { i.state = .on }
            return i
        }
        m.addItem(item("打开翻译面板（⌃⌥T）", #selector(openPanel(_:))))
        m.addItem(.separator())
        m.addItem(item("查看单词本…", #selector(showVocabulary(_:))))
        m.addItem(item("导出单词本为 CSV…", #selector(exportCSV(_:))))
        m.addItem(item("导出单词本为 JSON…", #selector(exportJSON(_:))))
        m.addItem(item("在 Finder 中显示单词本文件", #selector(revealVocabulary(_:))))
        m.addItem(.separator())
        let g = MainActor.assumeIsolated { AppContext.shared.glossary }
        let gOn = IMESettings.flag(GlossaryManager.masterKey, defaults: .standard)
        m.addItem(item("术语保护（离线术语表）", #selector(toggleGlossary(_:)), on: gOn))
        let sels: [GlossaryDomain: Selector] = [.petroleum: #selector(toggleGPetroleum(_:)), .ai: #selector(toggleGAI(_:)),
                                                .software: #selector(toggleGSoftware(_:)), .instrument: #selector(toggleGInstrument(_:)),
                                                .embedded: #selector(toggleGEmbedded(_:))]
        for d in GlossaryDomain.builtIn {
            let i = item("    \(d.title)（\(g.store.count(d)) 条）", sels[d]!, on: IMESettings.flag(d.settingsKey, defaults: .standard))
            i.isEnabled = gOn
            m.addItem(i)
        }
        m.addItem(item("打开我的词表（\(g.store.count(.user)) 条）", #selector(openUserGlossary(_:))))
        m.addItem(item("导入词表…（CSV / TSV / XLSX）", #selector(importGlossary(_:))))
        m.addItem(item("重新加载词表", #selector(reloadGlossary(_:))))
        m.addItem(.separator())
        m.addItem(item("复制延迟报告", #selector(copyLatencyReport(_:))))
        m.addItem(item("打开延迟日志", #selector(openLatencyLog(_:))))
        m.addItem(.separator())
        m.addItem(item("启用在线备用翻译（需先配置）", #selector(toggleOnline(_:)),
                       on: UserDefaults.standard.bool(forKey: IMESettings.onlineFallbackEnabled)))
        m.addItem(item("⌘V 粘贴英文到组词并翻译", #selector(togglePaste(_:)),
                       on: IMESettings.flag(IMESettings.pasteIntoComposition, defaults: .standard)))
        m.addItem(item("翻译面板打开时自动切到简体拼音", #selector(toggleAutoPinyin(_:)),
                       on: IMESettings.flag(IMESettings.autoSwitchPinyin, defaults: .standard)))
        let watchOn = IMESettings.flag(IMESettings.clipboardWatch, defaults: .standard)
        m.addItem(item("监测剪贴板英文并自动翻译", #selector(toggleClipboardWatch(_:)), on: watchOn))
        if watchOn {
            let pausedTill = MainActor.assumeIsolated { AppContext.shared.clipboardPausedUntil }
            if let till = pausedTill {
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                m.addItem(item("恢复剪贴板监测（已暂停至 \(f.string(from: till))）", #selector(resumeClipboardWatch(_:))))
            } else {
                m.addItem(item("暂停剪贴板监测 1 小时", #selector(pauseClipboardWatch(_:))))
            }
        }
        m.addItem(item("回车后自动填入原输入框", #selector(toggleAutoInsert(_:)),
                       on: IMESettings.flag(IMESettings.autoInsertAfterReturn, defaults: .standard)))
        m.addItem(item("复制后自动关闭面板", #selector(toggleCloseAfterCopy(_:)),
                       on: IMESettings.flag(IMESettings.closeAfterCopy, defaults: .standard)))
        m.addItem(item("授予辅助功能权限（读取选中文本/自动粘贴）…", #selector(askAccessibility(_:))))
        return m
    }

    @objc private func openPanel(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.toggleTranslator() } }
    @objc private func showVocabulary(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.showVocabulary() } }
    @objc private func exportCSV(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.exportVocabulary(csv: true) } }
    @objc private func exportJSON(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.exportVocabulary(csv: false) } }
    @objc private func revealVocabulary(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.revealVocabularyFile() } }
    @objc private func copyLatencyReport(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.copyLatencyReport() } }
    @objc private func openLatencyLog(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.openLatencyLog() } }
    @objc private func askAccessibility(_ s: Any?) { MainActor.assumeIsolated { PasteCommitter.requestAccessibility() } }
    @objc private func togglePaste(_ s: Any?) {
        let d = UserDefaults.standard
        d.set(!IMESettings.flag(IMESettings.pasteIntoComposition, defaults: d), forKey: IMESettings.pasteIntoComposition)
    }
    @objc private func toggleAutoPinyin(_ s: Any?) {
        let d = UserDefaults.standard
        d.set(!IMESettings.flag(IMESettings.autoSwitchPinyin, defaults: d), forKey: IMESettings.autoSwitchPinyin)
    }
    @objc private func toggleCloseAfterCopy(_ s: Any?) {
        let d = UserDefaults.standard
        d.set(!IMESettings.flag(IMESettings.closeAfterCopy, defaults: d), forKey: IMESettings.closeAfterCopy)
    }
    @objc private func toggleAutoInsert(_ s: Any?) {
        let d = UserDefaults.standard
        d.set(!IMESettings.flag(IMESettings.autoInsertAfterReturn, defaults: d), forKey: IMESettings.autoInsertAfterReturn)
    }
    @objc private func toggleClipboardWatch(_ s: Any?) {
        let d = UserDefaults.standard
        let on = !IMESettings.flag(IMESettings.clipboardWatch, defaults: d)
        d.set(on, forKey: IMESettings.clipboardWatch)
        MainActor.assumeIsolated { AppContext.shared.clipboardWatchChanged() }
    }
    @objc private func pauseClipboardWatch(_ s: Any?) {
        MainActor.assumeIsolated { AppContext.shared.pauseClipboardWatch(seconds: 3600) }
    }
    @objc private func resumeClipboardWatch(_ s: Any?) {
        MainActor.assumeIsolated { AppContext.shared.pauseClipboardWatch(seconds: 0) }
    }
    @objc private func toggleGlossary(_ s: Any?) {
        let on = !IMESettings.flag(GlossaryManager.masterKey, defaults: .standard)
        MainActor.assumeIsolated { AppContext.shared.glossary.setMaster(on) }
    }
    private func toggleDomain(_ d: GlossaryDomain) {
        let on = !IMESettings.flag(d.settingsKey, defaults: .standard)
        MainActor.assumeIsolated { AppContext.shared.glossary.setDomain(d, on: on) }
    }
    @objc private func toggleGPetroleum(_ s: Any?) { toggleDomain(.petroleum) }
    @objc private func toggleGAI(_ s: Any?) { toggleDomain(.ai) }
    @objc private func toggleGSoftware(_ s: Any?) { toggleDomain(.software) }
    @objc private func toggleGInstrument(_ s: Any?) { toggleDomain(.instrument) }
    @objc private func toggleGEmbedded(_ s: Any?) { toggleDomain(.embedded) }
    @objc private func openUserGlossary(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.glossary.openUserFile() } }
    @objc private func importGlossary(_ s: Any?) { MainActor.assumeIsolated { AppContext.shared.glossary.importFile() } }
    @objc private func reloadGlossary(_ s: Any?) {
        MainActor.assumeIsolated {
            AppContext.shared.glossary.reloadAll { msg in
                let a = NSAlert(); a.messageText = "词表已重新加载"; a.informativeText = msg
                NSApp.activate(ignoringOtherApps: true); a.runModal()
            }
        }
    }
    @objc private func toggleOnline(_ s: Any?) {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: IMESettings.onlineFallbackEnabled), forKey: IMESettings.onlineFallbackEnabled)
        MainActor.assumeIsolated { AppContext.shared.reloadProviders() }
    }
}
