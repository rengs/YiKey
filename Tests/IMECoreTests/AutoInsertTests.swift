#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation
import CoreGraphics
@testable import IMECore

// MARK: - 面板跟随光标：位置计算 + 屏幕边缘夹取

final class PanelPlacementTests: XCTestCase {
    /// 1440×900 屏幕，菜单栏 25、Dock 70
    private let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    private let size = CGSize(width: 440, height: 180)

    func testBelowCaretByDefault() {
        let caret = CGRect(x: 300, y: 600, width: 2, height: 18)
        let r = PanelPlacement.place(caret: caret, size: size, visible: visible)
        XCTAssertEqual(r.side, .below)
        XCTAssertEqual(r.topLeft, CGPoint(x: 300, y: 594))     // 光标行下沿 - 6
        XCTAssertLessThanOrEqual(r.frame.maxY, caret.minY, "不挡光标行")
    }

    func testAboveWhenNearScreenBottom() {
        let caret = CGRect(x: 300, y: 150, width: 2, height: 18)   // 下方只剩 66pt
        let r = PanelPlacement.place(caret: caret, size: size, visible: visible)
        XCTAssertEqual(r.side, .above)
        XCTAssertEqual(r.frame.minY, caret.maxY + PanelPlacement.gap)
        XCTAssertGreaterThanOrEqual(r.frame.minY, caret.maxY, "不挡光标行")
        XCTAssertLessThanOrEqual(r.frame.maxY, visible.maxY - PanelPlacement.margin)
    }

    func testClampedToRightEdge() {
        let caret = CGRect(x: 1400, y: 600, width: 2, height: 18)
        let r = PanelPlacement.place(caret: caret, size: size, visible: visible)
        XCTAssertEqual(r.frame.maxX, visible.maxX - PanelPlacement.margin)
        XCTAssertEqual(r.side, .below)
    }

    func testClampedToLeftEdge() {
        let caret = CGRect(x: -50, y: 600, width: 2, height: 18)
        let r = PanelPlacement.place(caret: caret, size: size, visible: visible)
        XCTAssertEqual(r.frame.minX, visible.minX + PanelPlacement.margin)
    }

    func testTallPanelPicksLargerSideAndStaysOnScreen() {
        let tall = CGSize(width: 440, height: 600)
        let caret = CGRect(x: 300, y: 500, width: 2, height: 18)   // 下方 416，上方 343：都放不下
        let r = PanelPlacement.place(caret: caret, size: tall, visible: visible)
        XCTAssertEqual(r.side, .below)
        XCTAssertGreaterThanOrEqual(r.frame.minY, visible.minY + PanelPlacement.margin - 0.001)
        XCTAssertLessThanOrEqual(r.frame.maxY, visible.maxY - PanelPlacement.margin + 0.001)
    }

    func testSecondaryScreenWithOffsetOrigin() {
        let screen2 = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let caret = CGRect(x: 2000, y: -10, width: 2, height: 20)
        let r = PanelPlacement.place(caret: caret, size: size, visible: screen2)
        XCTAssertEqual(r.side, .above, "副屏下方只剩 176pt → 上方")
        XCTAssertTrue(screen2.contains(r.frame))
    }

    func testFieldRectAsCaret() {
        // AX 只拿到输入框（宽 600，高 36）：面板贴在输入框下方、左对齐
        let field = CGRect(x: 400, y: 120, width: 600, height: 36)
        let r = PanelPlacement.place(caret: field, size: size, visible: visible)
        XCTAssertEqual(r.side, .above)        // 输入框靠近底部（聊天应用常见）
        XCTAssertEqual(r.frame.minX, 400)
        XCTAssertGreaterThanOrEqual(r.frame.minY, field.maxY)
    }

    func testQuartzToCocoaConversion() {
        let q = CGRect(x: 100, y: 50, width: 2, height: 18)        // 左上原点
        XCTAssertEqual(PanelPlacement.cocoaRect(fromQuartz: q, primaryScreenHeight: 900),
                       CGRect(x: 100, y: 832, width: 2, height: 18))
    }

    func testUnusableCaretRejected() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertFalse(PanelPlacement.isUsableCaret(.zero, screens: screens))
        XCTAssertFalse(PanelPlacement.isUsableCaret(CGRect(x: 5000, y: 5000, width: 2, height: 18), screens: screens))
        XCTAssertFalse(PanelPlacement.isUsableCaret(CGRect(x: 0, y: 0, width: 1440, height: 900), screens: screens))
        XCTAssertTrue(PanelPlacement.isUsableCaret(CGRect(x: 10, y: 10, width: 0, height: 18), screens: screens))
    }
}

// MARK: - 插入策略选择

final class InsertionPlannerTests: XCTestCase {
    func testStrategyMatrix() {
        XCTAssertEqual(InsertionPlanner.strategy(autoInsert: true, imeClientAvailable: true, accessibilityTrusted: false), .clientInsert)
        XCTAssertEqual(InsertionPlanner.strategy(autoInsert: true, imeClientAvailable: true, accessibilityTrusted: true), .clientInsert)
        XCTAssertEqual(InsertionPlanner.strategy(autoInsert: true, imeClientAvailable: false, accessibilityTrusted: true), .paste)
        XCTAssertEqual(InsertionPlanner.strategy(autoInsert: true, imeClientAvailable: false, accessibilityTrusted: false), .copyOnly)
        XCTAssertEqual(InsertionPlanner.strategy(autoInsert: false, imeClientAvailable: true, accessibilityTrusted: true), .copyOnly)
        XCTAssertEqual(InsertionPlanner.copyOnlyHint, "已复制，请 ⌘V（开启辅助功能可自动粘贴）")
    }

    func testHintsMentionAutoInsert() {
        XCTAssertTrue(PanelSubmitPolicy.hint(closeAfterCopy: true, autoInsert: true).hasPrefix("↩ 填入原输入框"))
        XCTAssertTrue(PanelSubmitPolicy.hint(closeAfterCopy: true, autoInsert: true).contains("⇧⌥↩ 复制并清空"))
        XCTAssertTrue(ReadingPanelPolicy.replyHint(autoInsert: true).contains("自动填入"))
        XCTAssertTrue(ReadingPanelPolicy.replyHint(autoInsert: false).contains("⌘V"))
    }
}

// MARK: - 自动填入：IMK 插入 / ⌘V + 恢复剪贴板 / 仅复制；剪贴板监测不再触发

@MainActor
final class MockStore: PasteboardStore, PasteboardReading {
    var changeCount = 500
    var items: [[String: Data]] = [["public.utf8-plain-text": Data("user's old clip".utf8), "public.html": Data("<b>x</b>".utf8)]]
    private(set) var log: [String] = []
    func snapshot() -> [[String: Data]] { log.append("snapshot"); return items }
    func restore(_ items: [[String: Data]]) { changeCount += 1; self.items = items; log.append("restore") }
    func writeOwn(_ text: String) {
        changeCount += 1
        items = [["public.utf8-plain-text": Data(text.utf8), ClipboardTextFilter.ownType: Data()]]
        log.append("write:\(text)")
    }
    // PasteboardReading
    func readTypes() -> [String] { items.flatMap { $0.keys } }
    func readString() -> String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
    var string: String? { readString() }
    /// 模拟用户在别处复制
    func userCopies(_ s: String) { changeCount += 1; items = [["public.utf8-plain-text": Data(s.utf8)]]; log.append("user:\(s)") }
}

@MainActor
final class MockKeys: PasteKeystrokeSender {
    var onSend: (() -> Void)?
    private(set) var commandVCount = 0
    func sendCommandV() { commandVCount += 1; onSend?() }
}

@MainActor
final class MockClient: ClientTextInserter {
    var available = true
    private(set) var inserted: [String] = []
    func insertIntoClient(_ text: String) -> Bool { guard available else { return false }; inserted.append(text); return true }
}

@MainActor
final class AutoInserterTests: XCTestCase {
    private func make(_ store: MockStore, _ keys: MockKeys, _ client: MockClient, watcher: ClipboardWatcher? = nil,
                      onSleep: (() -> Void)? = nil) -> AutoInserter {
        AutoInserter(pasteboard: store, keys: keys, client: client,
                     markOwn: { cc in watcher?.markOwnChange(cc) },
                     sleep: { _ in onSleep?() })
    }

    func testClientInsertDoesNotTouchClipboardOrKeys() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient()
        let before = store.changeCount
        let out = await make(store, keys, client).insert("See you at 3.", strategy: .clientInsert, accessibilityTrusted: true)
        XCTAssertEqual(out, .inserted)
        XCTAssertEqual(client.inserted, ["See you at 3."])
        XCTAssertEqual(keys.commandVCount, 0)
        XCTAssertEqual(store.changeCount, before)
        XCTAssertEqual(store.log, [])
    }

    func testClientUnavailableFallsBackToPasteWhenTrusted() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient(); client.available = false
        let out = await make(store, keys, client).insert("Hello", strategy: .clientInsert, accessibilityTrusted: true)
        XCTAssertEqual(out, .pasted)
        XCTAssertEqual(keys.commandVCount, 1)
    }

    func testClientUnavailableFallsBackToCopyOnlyWhenUntrusted() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient(); client.available = false
        let out = await make(store, keys, client).insert("Hello", strategy: .clientInsert, accessibilityTrusted: false)
        XCTAssertEqual(out, .copiedOnly)
        XCTAssertEqual(keys.commandVCount, 0)
        XCTAssertEqual(store.readString(), "Hello")
    }

    func testPasteSendsOnlyCommandVAndRestoresClipboard() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient()
        let original = store.items
        var clipAtPaste: String?
        keys.onSend = { clipAtPaste = store.readString() }
        let out = await make(store, keys, client).insert("I'll be there.", strategy: .paste, accessibilityTrusted: true)
        XCTAssertEqual(out, .pasted)
        XCTAssertEqual(keys.commandVCount, 1, "只发一次 ⌘V，不发回车")
        XCTAssertEqual(clipAtPaste, "I'll be there.", "⌘V 时剪贴板里是英文译文")
        XCTAssertEqual(store.items, original, "之后恢复用户原来的剪贴板（含所有类型）")
        XCTAssertEqual(store.log, ["snapshot", "write:I'll be there.", "restore"])
        XCTAssertEqual(client.inserted, [])
    }

    func testDoesNotOverwriteIfUserCopiedMeanwhile() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient()
        keys.onSend = { store.userCopies("something new") }
        _ = await make(store, keys, client).insert("Hi", strategy: .paste, accessibilityTrusted: true)
        XCTAssertEqual(store.readString(), "something new", "用户在恢复前自己复制了 → 不覆盖")
        XCTAssertFalse(store.log.contains("restore"))
    }

    func testCopyOnlyLeavesEnglishOnClipboard() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient()
        let out = await make(store, keys, client).insert("Thanks!", strategy: .copyOnly, accessibilityTrusted: true)
        XCTAssertEqual(out, .copiedOnly)
        XCTAssertEqual(store.readString(), "Thanks!")
        XCTAssertEqual(keys.commandVCount, 0)
        XCTAssertEqual(client.inserted, [])
    }

    func testNoRetriggerFromPasteOrRestore() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient()
        // 用户原剪贴板就是英文（比如刚才触发阅读面板的那段）
        store.items = [["public.utf8-plain-text": Data("Are you free tomorrow?".utf8)]]
        let watcher = ClipboardWatcher(pasteboard: store)
        var shown: [String] = []; watcher.onEnglishText = { shown.append($0) }
        // 每次 sleep（⌘V 前、恢复前）都让监测器轮询一次，模拟 0.5s 定时器
        let inserter = make(store, keys, client, watcher: watcher, onSleep: { watcher.poll() })
        keys.onSend = { watcher.poll() }
        _ = await inserter.insert("Yes, I am.", strategy: .paste, accessibilityTrusted: true)
        XCTAssertEqual(watcher.poll(), .ignore(.ownChange), "恢复原剪贴板也登记为自写")
        XCTAssertEqual(shown, [], "粘贴的译文与恢复的英文原剪贴板都不能再弹出面板")
        XCTAssertEqual(store.readString(), "Are you free tomorrow?")
        // 之后用户真的复制新英文 → 正常弹出
        store.userCopies("New message here")
        XCTAssertEqual(watcher.poll(), .translate("New message here"))
    }

    func testCopyOnlyNoRetrigger() async {
        let store = MockStore(), keys = MockKeys(), client = MockClient()
        let watcher = ClipboardWatcher(pasteboard: store)
        var shown: [String] = []; watcher.onEnglishText = { shown.append($0) }
        _ = await make(store, keys, client, watcher: watcher).insert("Got it.", strategy: .copyOnly, accessibilityTrusted: false)
        watcher.poll()
        XCTAssertEqual(shown, [])
    }
}
