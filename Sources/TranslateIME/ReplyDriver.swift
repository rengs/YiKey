import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IMECore

/// 来源（复制英文 / 打开 ⌃⌥T 时）的应用和焦点窗口
struct ReplySource: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    let window: AXUIElement?          // AXFocusedWindow（可能拿不到）

    /// 在后台或主线程都可调用；0.15s 超时；未授权时 window 为 nil
    static func capture(pid: pid_t, bundleID: String?) -> ReplySource {
        var window: AXUIElement?
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
               let v = ref, CFGetTypeID(v) == AXUIElementGetTypeID() {
                window = (v as! AXUIElement)
            }
        }
        return ReplySource(pid: pid, bundleID: bundleID, window: window)
    }
}

/// 用来判断“是不是同一个来源”（同一应用 + 同一窗口）：暂存的回复草稿只对同一来源恢复
struct ReplySourceKey: Equatable, @unchecked Sendable {
    let pid: pid_t
    let window: AXUIElement?
    static func == (a: ReplySourceKey, b: ReplySourceKey) -> Bool {
        guard a.pid == b.pid else { return false }
        switch (a.window, b.window) {
        case (nil, nil): return true
        case let (x?, y?): return CFEqual(x, y)
        default: return false
        }
    }
}

extension ReplySource {
    var key: ReplySourceKey { ReplySourceKey(pid: pid, window: window) }
}

/// 真实 AX 实现。AX 每个元素 0.15s 超时；窗口树搜索限 0.3s / 深度 30 / 4000 个节点。
@MainActor
final class SystemReplyDriver: ReplyTargetDriver {
    typealias Element = AXUIElement
    let source: ReplySource
    private let primaryH: CGFloat
    private var resolvedWindow: AXUIElement?
    var searchBudget: TimeInterval = 0.3

    init(source: ReplySource) {
        self.source = source
        primaryH = NSScreen.screens.first?.frame.height ?? 0
    }

    private var appElement: AXUIElement {
        let el = AXUIElementCreateApplication(source.pid)
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }

    // MARK: AX 小工具
    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success ? ref : nil
    }
    private func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    private func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        guard let v = attr(el, name) else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) }
        return (v as? NSNumber)?.boolValue
    }
    private func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, name as CFString, &b) == .success && b.boolValue
    }
    private func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = v as! AXUIElement
        AXUIElementSetMessagingTimeout(e, 0.15)
        return e
    }
    private func quartzFrame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    private func cocoaFrame(_ el: AXUIElement) -> CGRect? {
        quartzFrame(el).map { PanelPlacement.cocoaRect(fromQuartz: $0, primaryScreenHeight: primaryH) }
    }

    func candidate(_ el: AXUIElement, role: String? = nil) -> InputCandidate? {
        guard let role = role ?? string(el, kAXRoleAttribute), let frame = cocoaFrame(el) else { return nil }
        return InputCandidate(role: role,
                              subrole: string(el, kAXSubroleAttribute),
                              roleDescription: string(el, kAXRoleDescriptionAttribute),
                              placeholder: string(el, kAXPlaceholderValueAttribute),
                              title: string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute),
                              help: string(el, kAXHelpAttribute),
                              frame: frame,
                              enabled: bool(el, kAXEnabledAttribute) ?? true,
                              focused: bool(el, kAXFocusedAttribute) ?? false,
                              editableFlag: bool(el, "AXEditable") ?? false,
                              valueSettable: settable(el, kAXValueAttribute),
                              selectedTextSettable: settable(el, kAXSelectedTextAttribute))
    }

    // MARK: ReplyTargetDriver

    func activateSource() async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: source.pid) else { return false }
        app.activate()
        let win = source.window ?? element(appElement, kAXFocusedWindowAttribute)
        if let w = win {
            AXUIElementSetMessagingTimeout(w, 0.15)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        resolvedWindow = win
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != source.pid {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)       // 等窗口焦点稳定
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid
    }

    func windowFrame() -> CGRect? {
        (resolvedWindow ?? element(appElement, kAXFocusedWindowAttribute)).flatMap(cocoaFrame)
    }

    func focusedElement() -> (AXUIElement, InputCandidate)? {
        guard let el = element(appElement, kAXFocusedUIElementAttribute), let c = candidate(el) else { return nil }
        return (el, c)
    }

    func searchCandidates() -> [(AXUIElement, InputCandidate)] {
        guard let root = resolvedWindow ?? element(appElement, kAXFocusedWindowAttribute) else { return [] }
        var found = runSearch(root)
        if found.isEmpty, (attr(appElement, "AXManualAccessibility") != nil || isElectronLike()) {
            // Electron / Chromium 应用默认不建网页无障碍树：打开 AXManualAccessibility 后重试一次
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.15)
            found = runSearch(root)
        }
        return found
    }

    private func isElectronLike() -> Bool {
        guard let url = NSRunningApplication(processIdentifier: source.pid)?.bundleURL else { return false }
        let fw = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []
        return names.contains { $0.contains("Electron") || $0.contains("Chromium") || $0.contains("Chrome") }
    }

    private func runSearch(_ root: AXUIElement) -> [(AXUIElement, InputCandidate)] {
        let deadline = Date().addingTimeInterval(searchBudget)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0, visited = 0
        var out: [(AXUIElement, InputCandidate)] = []
        while head < queue.count, visited < 4000, Date() < deadline {
            let (el, depth) = queue[head]; head += 1; visited += 1
            AXUIElementSetMessagingTimeout(el, 0.15)
            let role = string(el, kAXRoleAttribute) ?? ""
            if InputBoxFinder.textRoles.contains(role) || role == "AXSearchField" || role == "AXSecureTextField" {
                if let c = candidate(el, role: role) { out.append((el, c)) }
                continue                                     // 输入框内部不用再往下找
            }
            if role == "AXGroup" || role == "AXScrollArea" || role == "AXWebArea" || role == "AXSplitGroup" || role == "AXLayoutArea" {
                if bool(el, "AXEditable") == true, settable(el, kAXSelectedTextAttribute) || settable(el, kAXValueAttribute),
                   let c = candidate(el, role: role), c.frame.height < 400 {
                    out.append((el, c)); continue            // 网页 contenteditable
                }
            }
            guard depth < 30, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for k in kids { queue.append((k, depth + 1)) }
        }
        return out
    }

    func focus(_ e: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.05)
        if bool(e, kAXFocusedAttribute) == true { return true }
        if let f = element(appElement, kAXFocusedUIElementAttribute), CFEqual(f, e) { return true }
        return false
    }

    func click(_ e: AXUIElement) -> Bool {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid,
              let q = quartzFrame(e), q.width > 0, q.height > 0 else { return false }
        let p = CGPoint(x: q.midX, y: q.midY)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
        return focus(e) || bool(e, kAXFocusedAttribute) == true
    }

    func setSelectedText(_ e: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(e, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func readValue(_ e: AXUIElement) -> String? { string(e, kAXValueAttribute) }

    func sendCommandV() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        return true
    }
}

/// 不抢焦点的小提示（面板关闭后显示“已填入…/未找到…”）
@MainActor
enum FeedbackHUD {
    private static var window: NSPanel?
    private static var task: Task<Void, Never>?

    static func show(_ text: String, near rect: CGRect?) {
        task?.cancel()
        window?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        let size = label.fittingSize
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width + 28, height: size.height + 16),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .popUpMenu; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 8
        bg.autoresizingMask = [.width, .height]
        label.frame = NSRect(x: 14, y: 8, width: size.width, height: size.height)
        bg.addSubview(label)
        w.contentView = bg
        let screen = NSScreen.screens.first { s in rect.map { s.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? s.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let anchor = rect ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let tl = PanelPlacement.place(caret: anchor, size: w.frame.size, visible: screen.visibleFrame).topLeft
        w.setFrameTopLeftPoint(tl)
        w.orderFrontRegardless()
        window = w
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            w.orderOut(nil)
            if window === w { window = nil }
        }
    }
}
