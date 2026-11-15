import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 读取选中文本（需要“辅助功能”授权，没授权返回 nil）
enum SelectionReader {
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedRef = focused else { return nil }
        let element = focusedRef as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// 翻译器模式的上屏：写剪贴板 + 模拟 ⌘V（需要辅助功能授权）。
/// 没授权时只复制到剪贴板并弹出授权提示；有授权时粘贴后恢复原剪贴板。
@MainActor
enum PasteCommitter {
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func commit(_ text: String) {
        let pb = NSPasteboard.general
        let backup: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        OwnPasteboard.write(text)

        guard AXIsProcessTrusted() else {
            requestAccessibility()      // 文本已在剪贴板，用户可手动 ⌘V
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            postCommandV()
            try? await Task.sleep(nanoseconds: 400_000_000)
            pb.clearContents()
            for dict in backup {
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
            OwnPasteboard.noteOwnChange()     // 恢复用户原剪贴板也不能触发“英文自动翻译”
        }
    }

    private static func postCommandV() {
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
