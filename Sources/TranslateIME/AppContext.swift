import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox
import IMECore

/// 进程级单例：所有 InputController 共享同一个翻译服务、浮窗、热键、单词本、延迟监控。
/// 必须在启动时（applicationDidFinishLaunching）创建并预热，不能等到第一次按键。
@MainActor
final class AppContext {
    static let shared = AppContext()

    let monitor = LatencyMonitor.shared
    let speaker: SpeechService
    let service: TranslationService
    let coordinator: TranslationCoordinator
    let panel: PanelController
    let book: VocabularyBook
    let glossary: GlossaryManager
    let hotKey = HotKeyManager()
    weak var activeController: InputController?
    private(set) var clipboardWatcher: ClipboardWatcher?
    private var clipboardTimer: Timer?
    private lazy var vocabularyWindow = VocabularyWindowController(book: book)

    private let localProviders: [TranslationProvider]

    private init() {
        let defaults = UserDefaults.standard
        let monitor = LatencyMonitor.shared
        monitor.addSink(OSLogLatencySink())
        if defaults.bool(forKey: IMESettings.latencyFileLog) { monitor.addSink(FileLatencySink()) }
        monitor.verbose = defaults.bool(forKey: IMESettings.latencyVerbose)

        var local: [TranslationProvider] = []
        var host = AnyView(EmptyView())
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let bridge = AppleTranslationBridge()
            local.append(AppleTranslationProvider(bridge: bridge))
            host = AnyView(AppleTranslationHostView(bridge: bridge))
        }
        #endif
        // 术语表（离线）：翻译前保护术语、翻译后换成标准译法
        let glossary = GlossaryManager()
        self.glossary = glossary
        // 顺序即优先级：Apple 本地 → （若已启用）在线备用
        let svc = TranslationService(providers: local + OnlineProviderFactory.make(defaults: defaults),
                                     glossary: glossary.store)
        let cache = svc.cache
        glossary.store.onChange = { cache.removeAll() }      // 词表变了：旧译文作废
        let spk = SpeechService()
        let book = VocabularyBook(monitor: monitor)
        let coord = TranslationCoordinator(service: svc, speaker: spk,
                                           debounce: IMESettings.debounce(defaults: defaults),
                                           vocabulary: book, monitor: monitor)
        localProviders = local
        speaker = spk
        service = svc
        coordinator = coord
        self.book = book
        panel = PanelController(coordinator: coord, host: host, monitor: monitor)
        panel.correctionSaver = { [glossary] src, dst in try await glossary.saveCorrection(source: src, translation: dst) }
    }

    func start() {
        hotKey.onTrigger = { [weak self] in self?.toggleTranslator() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))   // ⌃⌥T

        // 预热：把“第一次”的成本全部挪到启动时，保证第一次按键也不卡
        panel.prewarm()
        speaker.prewarm()
        startClipboardWatch()
        glossary.start()
        let svc = service, book = book
        Task.detached(priority: .utility) {
            await svc.prewarm()               // Apple 语言可用性查询
            _ = await book.entries()          // 预读单词本文件
        }
    }

    func toggleTranslator() {
        if panel.isTranslatorVisible { panel.hide(); return }
        if panel.isReadingVisible { panel.startReply(); return }    // 剪贴板英文面板上按 ⌃⌥T = 用中文回复
        let prefill = activeController?.currentSelectedText() ?? SelectionReader.selectedText() ?? ""
        panel.showTranslator(prefill: prefill)
    }

    // MARK: 剪贴板英文监测（兼任翻译软件）

    func startClipboardWatch() {
        let defaults = UserDefaults.standard
        let panel = panel
        let watcher = ClipboardWatcher(
            pasteboard: SystemPasteboardReader(),
            isEnabled: { IMESettings.flag(IMESettings.clipboardWatch, defaults: defaults) },
            // 正在组词 / TranslateIME 自己的窗口在前台：不打扰；阅读面板换新英文；回复模式被新的外部英文覆盖
            panelState: { panel.clipboardPanelState })
        let until = defaults.double(forKey: IMESettings.clipboardPausedUntil)
        if until > Date().timeIntervalSince1970 { watcher.pausedUntil = Date(timeIntervalSince1970: until) }
        watcher.onTrigger = { [weak self] text, kind in self?.showClipboardPanel(text, kind: kind) }
        OwnPasteboard.onOwnChange = { [weak watcher] cc in watcher?.markOwnChange(cc) }
        clipboardWatcher = watcher

        // 0.5s 轮询 changeCount：tolerance 让系统合并唤醒；只读一个整数，CPU 可忽略。不在按键路径上。
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t0 = LatencyMonitor.now()
                let decision = AppContext.shared.clipboardWatcher?.poll()
                if decision != .ignore(.unchanged) {
                    AppContext.shared.monitor.record(.clipboardPoll, milliseconds: LatencyMonitor.ms(since: t0))
                }
            }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        clipboardTimer = t
    }

    /// 剪贴板英文 → 先在后台用锚点链找位置（选中文字 → 光标 → 输入框 → 鼠标 → 窗口 → 右上角），再显示面板
    private func showClipboardPanel(_ text: String, kind: ClipboardTriggerKind = .fresh) {
        let front = NSWorkspace.shared.frontmostApplication
        let own = ProcessInfo.processInfo.processIdentifier
        let pid: pid_t? = (front?.processIdentifier == own) ? nil : front?.processIdentifier
        let mouse = NSEvent.mouseLocation                     // 检测到变化那一刻的鼠标位置
        let imk = CaretLocator.imkCaret(for: front)
        let frames = NSScreen.screens.map(\.frame)
        let query = SystemAXAnchorQuery.current()
        let bundle = front?.bundleIdentifier
        Task.detached(priority: .userInitiated) {
            let t0 = LatencyMonitor.now()
            let inputs = AnchorChain.gather(ax: query, pid: pid, imkCaret: imk, mouse: mouse, screens: frames)
            let anchor = AnchorChain.choose(inputs, screens: frames)
            let source = pid.map { ReplySource.capture(pid: $0, bundleID: bundle) }   // 记下来源应用和焦点窗口
            let ms = LatencyMonitor.ms(since: t0)
            await MainActor.run {
                let ctx = AppContext.shared
                ctx.panel.showReading(english: text, anchor: anchor, source: source)
                let f = ctx.panel.panelFrame
                let o = ctx.panel.lastOverride
                PlacementLog.write("clipboard kind=\(kind)"
                    + (o?.leftReply == true ? " leftReply=1 draftStashed=\(o?.stashedDraft == true ? 1 : 0)" : "") + " " + AnchorChain.describe(inputs, anchor: anchor, app: bundle)
                    + String(format: " axMs=%.1f", ms)
                    + " panel=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))")
            }
        }
    }

    var clipboardPausedUntil: Date? {
        guard let w = clipboardWatcher, w.isPaused else { return nil }
        return w.pausedUntil
    }

    func pauseClipboardWatch(seconds: TimeInterval) {
        let until = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        clipboardWatcher?.pausedUntil = until
        UserDefaults.standard.set(until?.timeIntervalSince1970 ?? 0, forKey: IMESettings.clipboardPausedUntil)
        clipboardWatcher?.resync()
    }

    func clipboardWatchChanged() {
        clipboardWatcher?.resync()     // 重新开启时不弹出“开启前”复制的内容
        if !IMESettings.flag(IMESettings.clipboardWatch, defaults: .standard) { panel.hideReading() }
    }

    func reloadProviders() {
        let all = localProviders + OnlineProviderFactory.make(defaults: .standard)
        Task { await service.setProviders(all) }
    }

    // MARK: 单词本

    func showVocabulary() { vocabularyWindow.show() }

    func exportVocabulary(csv: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let sp = NSSavePanel()
        sp.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        sp.nameFieldStringValue = csv ? "vocabulary.csv" : "vocabulary.json"
        guard sp.runModal() == .OK, let url = sp.url else { return }
        let book = book
        Task.detached(priority: .utility) {
            do {
                if csv { try await book.exportCSV(to: url) } else { try await book.exportJSON(to: url) }
            } catch {
                await MainActor.run {
                    let a = NSAlert(); a.messageText = "导出失败"; a.informativeText = "\(error)"; a.runModal()
                }
            }
        }
    }

    func revealVocabularyFile() {
        let url = VocabularyBook.defaultFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: 延迟报告

    func copyLatencyReport() {
        OwnPasteboard.write(monitor.report())
    }

    func openLatencyLog() {
        let url = FileLatencySink.defaultURL
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else {
            let a = NSAlert()
            a.messageText = "尚未开启文件延迟日志"
            a.informativeText = "运行：defaults write com.example.inputmethod.TranslateIME latencyFileLog -bool true，然后重新选择输入法。也可用“复制延迟报告”，或：log stream --predicate 'subsystem == \"com.example.inputmethod.TranslateIME\"' --level debug"
            a.runModal()
        }
    }

    /// 退出前尽力落盘（IME 进程常被系统直接结束，所以平时靠 0.3s 防抖写入把丢失窗口压到最小）
    func flushBlocking() {
        let book = book
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await book.flush(); sem.signal() }
        _ = sem.wait(timeout: .now() + 1)
    }
}
