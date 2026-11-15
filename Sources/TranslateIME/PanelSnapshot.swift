import AppKit
import SwiftUI
import IMECore

/// 诊断/验收用：把真实的翻译面板视图（同一套 SwiftUI + NSTextView 代码）以给定文字排版，
/// 输出尺寸数据并渲染成 PNG，用来验证“换行后每一行都完整可见、没有空白”。不读写设置、不切换输入源。
///   TranslateIME --snapshot-panel <out.png> <文字> [停留秒数]
@MainActor
enum PanelSnapshot {
    private struct StaticProvider: TranslationProvider {
        let id = "snapshot"
        func isAvailable(from: TextLanguage, to: TextLanguage) async -> Bool { true }
        func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String {
            from == .chinese ? "(English translation of \(text.count) characters)" : "（中文译文）"
        }
    }

    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--snapshot-panel"), arguments.count > i + 2 else {
            print("usage: TranslateIME --snapshot-panel <out.png> <text> [linger-seconds]"); return 2
        }
        let out = arguments[i + 1], text = arguments[i + 2]
        let linger = arguments.count > i + 3 ? Double(arguments[i + 3]) ?? 0 : 0

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let coord = TranslationCoordinator(service: TranslationService(providers: [StaticProvider()]),
                                           speaker: SpeechService(), debounce: 0, monitor: LatencyMonitor())
        let vm = PanelViewModel()
        vm.mode = .translator
        vm.inputText = text
        let hosting = FirstMouseHostingView(rootView: PanelRootView(vm: vm, coordinator: coord, host: AnyView(EmptyView())))
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.contentView = hosting
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let topLeft = NSPoint(x: vf.minX + 40, y: vf.maxY - 40)
        win.setFrameTopLeftPoint(topLeft)
        win.orderFrontRegardless()
        coord.update(text: text)

        for _ in 0..<4 {
            pump(0.15)
            hosting.layoutSubtreeIfNeeded()
            win.setContentSize(hosting.fittingSize)
            win.setFrameTopLeftPoint(topLeft)
        }
        pump(0.2)

        // —— 诊断数据 ——
        guard let tv = find(PanelInputTextView.self, in: hosting), let scroll = tv.enclosingScrollView,
              let lm = tv.layoutManager, let tc = tv.textContainer else {
            print("ERROR: text view not found"); return 3
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let need = ceil(used + 2 * tv.textContainerInset.height)
        let visibleH = scroll.contentView.bounds.height
        let originY = scroll.contentView.bounds.origin.y
        let lines = ComposingTextField.measurer.lineCount(NSAttributedString(string: tv.string, attributes: ComposingTextField.measurer.attributes),
                                                          textWidth: ComposingTextField.sizer.maxTextWidth)
        let layout = vm.inputLayout
        let scrollInWindow = scroll.convert(scroll.bounds, to: nil)
        let clippedByWindow = scrollInWindow.minY < -0.5 || scrollInWindow.maxY > hosting.bounds.height + 0.5
        let clippedTop = originY > 0.5 && !layout.scrolls
        let clippedBottom = need > visibleH + 0.5 && !layout.scrolls
        let gap = visibleH - need
        let docMisplaced = abs(tv.frame.minY) > 0.5 || abs(tv.frame.width - scroll.contentSize.width) > 0.5
        print("chars=\(text.count) lines=\(lines) layout=\(Int(layout.width))x\(Int(layout.height)) wraps=\(layout.wraps) scrolls=\(layout.scrolls)")
        print("textHeightNeeded=\(need) visibleHeight=\(visibleH) clipOriginY=\(originY) gap=\(gap)")
        print("window=\(Int(win.frame.width))x\(Int(win.frame.height)) inputFrameInWindow=\(scrollInWindow.integral)")
        print("textView.frame=\(tv.frame.integral) container=\(tc.size.width.rounded())x\(min(tc.size.height, 99999).rounded()) clip=\(scroll.contentView.bounds.integral) font=\(tv.font?.pointSize ?? 0)")
        let ok = !clippedTop && !clippedBottom && !clippedByWindow && !docMisplaced && (layout.scrolls || (gap < 2.5 && gap > -0.5))
        print(ok ? (layout.scrolls ? "RESULT: OK (超过最大行数：高度封顶、从顶部开始显示，可滚动)" : "RESULT: OK (all lines fully visible, no gap)") : "RESULT: FAIL clippedTop=\(clippedTop) clippedBottom=\(clippedBottom) clippedByWindow=\(clippedByWindow) docMisplaced=\(docMisplaced) gap=\(gap)")

        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("PNG \(out)")
        }
        print("WINDOW_ID \(win.windowNumber)")
        fflush(stdout)
        if linger > 0 { pump(linger) }
        win.orderOut(nil)
        return ok ? 0 : 1
    }

    private static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }
}
