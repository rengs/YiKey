import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IMECore

// MARK: - 找到当前应用的输入光标位置（面板跟随）

@MainActor
enum CaretLocator {
    enum Source: String { case imk, axRange, axField, none }

    /// ⌃⌥T 面板用：返回 Cocoa 屏幕坐标的光标行矩形（或输入框矩形）。
    /// 1) TranslateIME 正是该应用的当前输入法 → IMK；2) 当前已授权辅助功能（每次实时检查）→ AX 光标 / 输入框；3) nil
    static func locate(in app: NSRunningApplication?, useIMK: Bool = true) -> (rect: NSRect, source: Source)? {
        let screens = NSScreen.screens.map(\.frame)
        if useIMK, let r = imkCaret(for: app), PanelPlacement.isUsableCaret(r, screens: screens) {
            return (r, .imk)
        }
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let ax = SystemAXAnchorQuery.current()
        guard ax.isTrusted() else { return nil }
        if let r = ax.caretBounds(pid: app.processIdentifier) ?? ax.selectionBounds(pid: app.processIdentifier),
           PanelPlacement.isUsableCaret(r, screens: screens) { return (r, .axRange) }
        if let r = ax.focusedElementFrame(pid: app.processIdentifier), r.height <= AnchorChain.maxFieldHeight,
           PanelPlacement.isUsableCaret(r, screens: screens) { return (r, .axField) }
        return nil
    }

    /// TranslateIME 是该应用当前输入法时的 IMK 光标
    static func imkCaret(for app: NSRunningApplication?) -> NSRect? {
        guard let app, let c = AppContext.shared.activeController,
              let bid = c.clientBundleID, bid == app.bundleIdentifier, bid != Bundle.main.bundleIdentifier else { return nil }
        return c.currentCaretRect()
    }
}

/// 真实 AX 查询。可在后台线程调用（AX API 线程安全）；每个元素都设 0.15s 超时；坐标转换为 Cocoa。
struct SystemAXAnchorQuery: AXAnchorQuerying {
    let primaryScreenHeight: CGFloat
    static let timeout: Float = 0.15

    @MainActor static func current() -> SystemAXAnchorQuery {
        SystemAXAnchorQuery(primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    func isTrusted() -> Bool { AXIsProcessTrusted() }      // 每次实时检查，不缓存

    private func cocoa(_ q: CGRect) -> CGRect {
        PanelPlacement.cocoaRect(fromQuartz: q, primaryScreenHeight: primaryScreenHeight)
    }
    private func appElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, Self.timeout)
        return el
    }
    private func element(_ parent: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attr as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, Self.timeout)
        return el
    }
    private func focused(_ pid: pid_t) -> AXUIElement? { element(appElement(pid), kAXFocusedUIElementAttribute) }

    private func selectedRange(_ el: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }
    private func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        return rectParam(el, kAXBoundsForRangeParameterizedAttribute, param)
    }
    private func rectParam(_ el: AXUIElement, _ attr: String, _ param: CFTypeRef) -> CGRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, param, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var q = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &q), q.height > 0 else { return nil }
        return cocoa(q)
    }
    private func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz),
              sz.height > 0, sz.width > 0 else { return nil }
        return cocoa(CGRect(origin: pt, size: sz))
    }

    func selectionBounds(pid: pid_t) -> CGRect? {
        guard let el = focused(pid) else { return nil }
        if let range = selectedRange(el), range.location != kCFNotFound, range.length > 0 {
            if let r = bounds(el, range), r.height < 400, r.width > 0 { return r }
            // 选区太大（多行）：用选区最后一个字符所在行
            if let r = bounds(el, CFRange(location: range.location + range.length - 1, length: 1)) { return r }
        }
        // WebKit / Chromium：TextMarker 方式（网页里的只读文本）
        var marker: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let m = marker {
            if let r = rectParam(el, "AXBoundsForTextMarkerRange", m), r.width > 0 {
                if r.height < 400 { return r }
                return CGRect(x: r.minX, y: r.minY, width: min(r.width, 400), height: 20)   // 取选区底部一行
            }
        }
        return nil
    }

    func caretBounds(pid: pid_t) -> CGRect? {
        guard let el = focused(pid), let range = selectedRange(el), range.location != kCFNotFound else { return nil }
        if let r = bounds(el, CFRange(location: range.location, length: 0)) { return r }
        if range.location > 0, var r = bounds(el, CFRange(location: range.location - 1, length: 1)) {
            r.origin.x = r.maxX; r.size.width = 1          // 光标在这个字符之后
            return r
        }
        return nil
    }

    func focusedElementFrame(pid: pid_t) -> CGRect? {
        guard let el = focused(pid) else { return nil }
        return frame(el)
    }

    func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard let w = element(appElement(pid), kAXFocusedWindowAttribute) else { return nil }
        return frame(w)
    }
}

/// 面板定位诊断日志：~/Library/Logs/TranslateIME/placement.log（只记录策略和坐标，不记录任何文字）
enum PlacementLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TranslateIME/placement.log")
    private static let queue = DispatchQueue(label: "TranslateIME.placementlog", qos: .utility)

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256_000 {
                try? fm.removeItem(at: url.appendingPathExtension("1"))
                try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - 自动填入的系统实现

/// 剪贴板快照/恢复/自写
@MainActor
final class SystemPasteboardStore: PasteboardStore {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func snapshot() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [String: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t.rawValue] = data } }
            return d
        }
    }
    func restore(_ items: [[String: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let objs: [NSPasteboardItem] = items.map { d in
            let it = NSPasteboardItem()
            for (k, v) in d { it.setData(v, forType: NSPasteboard.PasteboardType(k)) }
            return it
        }
        if !objs.isEmpty { pb.writeObjects(objs) }
    }
    func writeOwn(_ text: String) { OwnPasteboard.write(text, notify: false) }
}

/// 只会发送 ⌘V；发送前确认前台应用就是目标应用，否则不发（宁可不粘贴也不粘错地方）。从不发送回车。
@MainActor
final class CGEventPasteSender: PasteKeystrokeSender {
    var expectedPID: pid_t?
    private(set) var lastSkipped = false
    func sendCommandV() {
        lastSkipped = false
        if let pid = expectedPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            lastSkipped = true
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// IMK 客户端插入：只有当前激活的 InputController 的客户端正是目标应用时才插入
@MainActor
final class IMKClientInserter: ClientTextInserter {
    var expectedBundleID: String?
    func insertIntoClient(_ text: String) -> Bool {
        guard let bid = expectedBundleID, bid != Bundle.main.bundleIdentifier,
              let c = AppContext.shared.activeController, c.clientBundleID == bid else { return false }
        return c.insertIntoClient(text)
    }
}

enum KeyState {
    /// ↩ / 小键盘 Enter 是否仍按着（自动填入前等它松开，避免长按回车的连发落到原应用里变成“发送”）
    static var returnIsDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Return))
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_KeypadEnter))
    }
}

// MARK: - 诊断：自动填入自检（只允许对 TextEdit 操作）
//   TranslateIME --ax-status <out.txt>
//   TranslateIME --selftest-insert <out.txt> <text>
@MainActor
enum InsertSelfTest {
    static func axStatus(_ args: [String]) -> Int32 {
        let line = "AXIsProcessTrusted=\(AXIsProcessTrusted())\n"
        if let i = args.firstIndex(of: "--ax-status"), i + 1 < args.count {
            try? line.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        print(line, terminator: "")
        return 0
    }

    static func run(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--selftest-insert"), i + 2 < args.count else { return 2 }
        let out = args[i + 1], text = args[i + 2]
        var log: [String] = []
        func emit() { try? (log.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared
        log.append("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        // 安全限制：只对 TextEdit 操作
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            log.append("TextEdit not running"); emit(); return 1
        }
        app.activate()
        pump(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }, timeout: 2)
        pump(seconds: 0.3)
        log.append("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        if let c = CaretLocator.locate(in: app, useIMK: false) {
            log.append("caret=\(NSStringFromRect(c.rect)) source=\(c.source.rawValue)")
            let mid = NSPoint(x: c.rect.midX, y: c.rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.screens[0]
            let r = PanelPlacement.place(caret: c.rect, size: CGSize(width: 440, height: 183), visible: screen.visibleFrame)
            log.append("panelFrame=\(NSStringFromRect(r.frame)) side=\(r.side) visible=\(NSStringFromRect(screen.visibleFrame))")
        } else {
            log.append("caret=nil")
        }
        let store = SystemPasteboardStore()
        let beforeCount = store.changeCount
        let beforeTypes = (NSPasteboard.general.types ?? []).map(\.rawValue)
        let beforeString = NSPasteboard.general.string(forType: .string)
        let sender = CGEventPasteSender(); sender.expectedPID = app.processIdentifier
        let client = IMKClientInserter()
        var owned: [Int] = []
        let inserter = AutoInserter(pasteboard: store, keys: sender, client: client, markOwn: { owned.append($0) })
        let strategy = InsertionPlanner.strategy(autoInsert: true, imeClientAvailable: false,
                                                 accessibilityTrusted: AXIsProcessTrusted())
        var outcome: InsertOutcome?
        Task { @MainActor in outcome = await inserter.insert(text, strategy: strategy, accessibilityTrusted: AXIsProcessTrusted()) }
        pump(until: { outcome != nil }, timeout: 5)
        pump(seconds: 0.3)
        log.append("strategy=\(strategy) outcome=\(outcome.map { "\($0)" } ?? "timeout") commandVSkipped=\(sender.lastSkipped)")
        log.append("ownChangeCounts=\(owned) before=\(beforeCount) after=\(store.changeCount)")
        let afterTypes = (NSPasteboard.general.types ?? []).map(\.rawValue)
        log.append("clipboardRestored=\(NSPasteboard.general.string(forType: .string) == beforeString && Set(afterTypes) == Set(beforeTypes))")
        // 读 TextEdit 当前输入框内容确认已插入
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var f: CFTypeRef?, v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
           AXUIElementCopyAttributeValue(f as! AXUIElement, kAXValueAttribute as CFString, &v) == .success,
           let value = v as? String {
            log.append("fieldContainsText=\(value.contains(text)) fieldLength=\(value.count)")
        } else {
            log.append("fieldValue=unreadable")
        }
        emit()
        return 0
    }

    /// --selftest-reply <out.txt> <pid> <text>：对指定进程跑一遍“回复落到输入框”（仅供自检用的假聊天应用）
    static func runReply(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--selftest-reply"), i + 3 < args.count, let pid = pid_t(args[i + 2]) else { return 2 }
        let out = args[i + 1], text = args[i + 3]
        _ = NSApplication.shared
        var log = ["AXIsProcessTrusted=\(AXIsProcessTrusted())"]
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            log.append("no such pid"); try? log.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8); return 1
        }
        // 模拟“复制时”记下来源，然后切走（模拟用户在面板里输入）
        let source = ReplySource.capture(pid: pid, bundleID: app.bundleIdentifier)
        log.append("sourceWindow=\(source.window != nil)")
        let driver = SystemReplyDriver(source: source)
        let before = driver.focusedElement()
        log.append("focusedBefore=\(before?.1.role ?? "nil") editable=\(before.map { InputBoxFinder.isEditableInput($0.1) } ?? false)")
        var owned: [Int] = []
        let inserter = ReplyInserter(driver: driver, pasteboard: SystemPasteboardStore(), markOwn: { owned.append($0) })
        var report: ReplyInsertReport?
        Task { @MainActor in report = await inserter.run(text, accessibilityTrusted: AXIsProcessTrusted()) }
        pump(until: { report != nil }, timeout: 6)
        pump(seconds: 0.4)
        log.append(report?.logLine ?? "timeout")
        log.append("feedback=\(report?.result.feedback ?? "-")")
        log.append("clipboardHasText=\(NSPasteboard.general.string(forType: .string) == text) ownMarked=\(!owned.isEmpty) ownType=\(NSPasteboard.general.types?.contains(OwnPasteboard.ownType) ?? false)")
        if let f = driver.focusedElement() {
            log.append("focusedAfter=\(f.1.role) valueContainsText=\(driver.readValue(f.0)?.contains(text) ?? false)")
        }
        try? (log.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        return 0
    }


    /// --selftest-override <out> <scratchPid> <firstEnglish>
    /// 回复模式中复制别的英文 → 立即切回英文阅读。外部复制由 shell 用 pbcopy 完成：
    ///   等 <out>.ready → pbcopy 相同英文 → touch <out>.same → 等 1.5s → pbcopy 新英文。
    /// 本自测不切换系统输入源、不向任何应用发送按键。
    static func runOverride(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--selftest-override"), i + 3 < args.count, let pid = pid_t(args[i + 2]) else { return 2 }
        let out = args[i + 1], first = args[i + 3]
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var log = ["AXIsProcessTrusted=\(AXIsProcessTrusted())"]
        func flush() { try? (log.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        guard let app = NSRunningApplication(processIdentifier: pid) else { log.append("no such pid"); flush(); return 1 }
        let ctx = AppContext.shared
        let panel = ctx.panel
        panel.skipInputSourceSwitch = true
        ctx.startClipboardWatch()
        let src = ReplySource.capture(pid: pid, bundleID: app.bundleIdentifier)
        // 1. 来自 scratch 的英文 → ↩ 回复 → 输入半截中文 + 正在组词的拼音
        panel.showReading(english: first, anchor: .fallback, source: src)
        pump(seconds: 0.3)
        panel.startReply()
        pump(seconds: 0.4)
        panel.selfTestType(committed: "我明天会", marked: "fa")
        pump(seconds: 0.2)
        var st = panel.selfTestState
        log.append("step1 mode=\(st.mode) marked=\(st.marked) inputLen=\(st.input.count)")
        // 2. TranslateIME 自己写剪贴板：必须忽略
        OwnPasteboard.write("This is my own reply text, ignore it")
        pump(seconds: 1.2)
        st = panel.selfTestState
        log.append("selfCopy mode=\(st.mode) decision=ignored:\(st.mode == "replying")")
        // 3. 用户回到原应用（scratch）；shell 用 pbcopy 复制
        app.activate()
        pump(seconds: 0.5)
        try? "ready".write(toFile: out + ".ready", atomically: true, encoding: .utf8)
        flush()
        pump(until: { FileManager.default.fileExists(atPath: out + ".same") }, timeout: 15)
        log.append("frontAtCopy=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
        pump(seconds: 1.2)
        st = panel.selfTestState
        func diag() -> String {
            "state=\(panel.clipboardPanelState) appActive=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) decision=\(ctx.clipboardWatcher?.lastDecision.map { "\($0)" } ?? "-")"
        }
        log.append("diag1 " + diag())
        log.append("sameText mode=\(st.mode) ignored=\(st.mode == "replying") lastKind=\(ctx.clipboardWatcher?.lastTriggerKind.map { "\($0)" } ?? "-")")
        pump(until: { panel.selfTestState.mode == "reading" }, timeout: 15)
        pump(seconds: 0.6)
        st = panel.selfTestState
        let o = panel.lastOverride
        log.append("override mode=\(st.mode) kind=\(ctx.clipboardWatcher?.lastTriggerKind.map { "\($0)" } ?? "-") readingChanged=\(st.reading != first) markedLeft=\(st.marked) inputCleared=\(st.input.isEmpty)")
        log.append("diag2 " + diag())
        log.append("transition leftReply=\(o?.leftReply ?? false) stashed=\(o?.stashedDraft ?? false) cancelPending=\(o?.cancelPending ?? false)")
        log.append("stash draftOK=\(panel.flow.stashedDraft == "我明天会") sourcePid=\(panel.flow.source?.pid ?? -1) scratchPid=\(pid) sourceWindow=\(panel.flow.source?.window != nil)")
        let f = panel.panelFrame
        log.append("panel=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)) mouse=\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))")
        // 4. 同一来源再按 ↩ 回复：草稿恢复
        panel.startReply()
        pump(seconds: 0.4)
        st = panel.selfTestState
        log.append("replyAgain mode=\(st.mode) draftRestored=\(st.input == "我明天会")")
        // 5. ⎋：丢弃草稿
        panel.hide()
        log.append("escape mode=\(panel.selfTestState.mode) stashCleared=\(panel.flow.stashedDraft == nil)")
        flush()
        return 0
    }

    private static func pump(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    private static func pump(until cond: () -> Bool, timeout: Double) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
