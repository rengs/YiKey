#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation
import CoreGraphics
@testable import IMECore

// MARK: - 输入框候选打分与选择

final class InputBoxFinderTests: XCTestCase {
    /// 窗口 800×600，原点 (100,100)（Cocoa：底部 y=100）
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func c(_ role: String, _ frame: CGRect, subrole: String? = nil, placeholder: String? = nil,
                   enabled: Bool = true, focused: Bool = false, editable: Bool = false,
                   settable: Bool = true) -> InputCandidate {
        InputCandidate(role: role, subrole: subrole, placeholder: placeholder, frame: frame, enabled: enabled,
                       focused: focused, editableFlag: editable, valueSettable: settable, selectedTextSettable: settable)
    }

    func testSkipsSearchSecureDisabledAndNonEditable() {
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXSearchField", window)))
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXTextField", window, subrole: "AXSearchField")))
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXTextField", window, subrole: "AXSecureTextField")))
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXSecureTextField", window)))
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXTextArea", window, enabled: false)))
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXStaticText", window)))
        XCTAssertFalse(InputBoxFinder.isEditableInput(c("AXTextArea", window, settable: false)), "只读文本区域（聊天记录）")
        XCTAssertTrue(InputBoxFinder.isEditableInput(c("AXTextArea", window)))
        XCTAssertTrue(InputBoxFinder.isEditableInput(c("AXGroup", window, editable: true, settable: false)), "网页 contenteditable")
        XCTAssertTrue(InputBoxFinder.isEditableInput(c("AXComboBox", window)))
    }

    func testPicksBottomWideMessageBox() {
        let cands = [
            c("AXTextField", CGRect(x: 110, y: 660, width: 300, height: 24), placeholder: "Search"),       // 顶部搜索（普通文本框）
            c("AXSearchField", CGRect(x: 420, y: 660, width: 300, height: 24)),
            c("AXTextField", CGRect(x: 740, y: 660, width: 150, height: 24), subrole: "AXSecureTextField"),
            c("AXTextField", CGRect(x: 110, y: 110, width: 780, height: 36), placeholder: "Type a message"), // 底部消息框
        ]
        XCTAssertEqual(InputBoxFinder.best(cands, window: window), 3)
    }

    func testBottomBeatsTopWhenNoHints() {
        let cands = [c("AXTextField", CGRect(x: 110, y: 600, width: 700, height: 24)),
                     c("AXTextArea", CGRect(x: 110, y: 120, width: 700, height: 60))]
        XCTAssertEqual(InputBoxFinder.best(cands, window: window), 1)
    }

    func testMessagePlaceholderWinsOverSlightlyLowerField() {
        let cands = [c("AXTextField", CGRect(x: 110, y: 105, width: 200, height: 20)),          // 窄小的底部字段
                     c("AXTextArea", CGRect(x: 110, y: 150, width: 760, height: 50), placeholder: "输入消息")]
        XCTAssertEqual(InputBoxFinder.best(cands, window: window), 1)
    }

    func testHugeEditorPenalized() {
        let cands = [c("AXTextArea", CGRect(x: 100, y: 140, width: 800, height: 520)),    // 大编辑区（文档）
                     c("AXTextField", CGRect(x: 110, y: 105, width: 600, height: 28))]
        XCTAssertEqual(InputBoxFinder.best(cands, window: window), 1)
    }

    func testTinyOrOffWindowRejected() {
        XCTAssertNil(InputBoxFinder.score(c("AXTextField", CGRect(x: 110, y: 110, width: 20, height: 20)), window: window))
        XCTAssertNil(InputBoxFinder.score(c("AXTextField", CGRect(x: 3000, y: 3000, width: 300, height: 30)), window: window))
        XCTAssertNil(InputBoxFinder.best([], window: window))
    }

    func testChineseSearchPlaceholderRejected() {
        XCTAssertNil(InputBoxFinder.score(c("AXTextField", CGRect(x: 110, y: 110, width: 700, height: 30), placeholder: "搜索"), window: window))
    }
}

// MARK: - 插入编排：回退顺序、剪贴板保留、不再触发

@MainActor
final class MockReplyDriver: ReplyTargetDriver {
    typealias Element = Int
    var activates = true
    var window: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600)
    var focused: (Int, InputCandidate)?
    var candidates: [(Int, InputCandidate)] = []
    var focusWorks = true, clickWorks = true, setWorks = true, valueChanges = true, valueReadable = true, cmdVWorks = true
    var values: [Int: String] = [:]
    private(set) var log: [String] = []

    func activateSource() async -> Bool { log.append("activate"); return activates }
    func windowFrame() -> CGRect? { window }
    func focusedElement() -> (Int, InputCandidate)? { log.append("focused?"); return focused }
    func searchCandidates() -> [(Int, InputCandidate)] { log.append("search"); return candidates }
    func focus(_ e: Int) -> Bool { log.append("focus:\(e)"); return focusWorks }
    func click(_ e: Int) -> Bool { log.append("click:\(e)"); return clickWorks }
    func setSelectedText(_ e: Int, _ text: String) -> Bool {
        log.append("set:\(e)")
        guard setWorks else { return false }
        if valueChanges { values[e, default: ""] += text }
        return true
    }
    func readValue(_ e: Int) -> String? { valueReadable ? values[e, default: ""] : nil }
    func sendCommandV() -> Bool { log.append("cmdV"); return cmdVWorks }
}

@MainActor
final class ReplyInserterTests: XCTestCase {
    private let history = InputCandidate(role: "AXTextArea", frame: CGRect(x: 10, y: 80, width: 780, height: 480),
                                         valueSettable: false, selectedTextSettable: false)
    private let messageBox = InputCandidate(role: "AXTextField", placeholder: "Type a message",
                                            frame: CGRect(x: 10, y: 10, width: 780, height: 32))
    private let searchBox = InputCandidate(role: "AXSearchField", frame: CGRect(x: 10, y: 570, width: 300, height: 24))

    private func make(_ d: MockReplyDriver, store: MockStore? = nil, watcher: ClipboardWatcher? = nil) -> ReplyInserter<MockReplyDriver> {
        ReplyInserter(driver: d, pasteboard: store ?? MockStore(), markOwn: { watcher?.markOwnChange($0) })
    }

    func testFocusOnHistorySearchesAndInsertsViaSelectedText() async {
        let d = MockReplyDriver()
        d.focused = (1, history)                                   // 复制时焦点在聊天记录
        d.candidates = [(2, searchBox), (1, history), (3, messageBox)]
        d.values[3] = "draft "
        let store = MockStore()
        let r = await make(d, store: store).run("See you at 3.", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .insertedAX)
        XCTAssertEqual(r.target, "searched")
        XCTAssertEqual(r.focusedBy, "ax")
        XCTAssertEqual(r.chosen, messageBox)
        XCTAssertEqual(d.values[3], "draft See you at 3.", "插在光标处，不覆盖已有文字")
        XCTAssertFalse(d.log.contains("cmdV"))
        XCTAssertEqual(store.readString(), "See you at 3.", "英文同时在剪贴板")
        XCTAssertEqual(r.result.feedback, "已填入输入框（已同时复制）")
    }

    func testFocusedEditableUsedDirectly() async {
        let d = MockReplyDriver()
        d.focused = (3, messageBox)
        let r = await make(d).run("Hi", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .insertedAX)
        XCTAssertEqual(r.target, "focused")
        XCTAssertFalse(d.log.contains("search"), "焦点就是输入框时不搜索")
        XCTAssertFalse(d.log.contains { $0.hasPrefix("focus:") })
    }

    func testFallbackOrderFocusThenClick() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]; d.focusWorks = false
        let r = await make(d).run("Hi", accessibilityTrusted: true)
        XCTAssertEqual(r.focusedBy, "click")
        XCTAssertEqual(d.log.filter { $0.hasPrefix("focus:") || $0.hasPrefix("click:") }, ["focus:3", "click:3"])
    }

    func testSelectedTextUnsupportedFallsBackToCommandVOnce() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]; d.setWorks = false
        let r = await make(d).run("Hi", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .pasted)
        XCTAssertEqual(d.log.filter { $0 == "cmdV" }.count, 1)
        XCTAssertEqual(d.log.suffix(2), ["set:3", "cmdV"], "先 AXSelectedText，失败后才 ⌘V")
    }

    func testSelectedTextReportedOKButValueUnchangedFallsBackToCommandV() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]; d.valueChanges = false
        let r = await make(d).run("Hi", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .pasted)
    }

    func testUnreadableValueTrustsAPIAndDoesNotDoublePaste() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]; d.valueReadable = false
        let r = await make(d).run("Hi", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .insertedAX)
        XCTAssertFalse(d.log.contains("cmdV"), "读不到值时不再 ⌘V，避免插入两遍")
    }

    func testNoCommandVWhenFocusCouldNotBeSet() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]
        d.focusWorks = false; d.clickWorks = false; d.setWorks = false
        let r = await make(d).run("Hi", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .insertFailed)
        XCTAssertFalse(d.log.contains("cmdV"), "焦点不在输入框时不发 ⌘V（避免粘错地方）")
        XCTAssertEqual(r.result.feedback, "未找到输入框，已复制，请 ⌘V")
    }

    func testNotFoundOnlySearchAndSecure() async {
        let d = MockReplyDriver()
        d.focused = (1, history)
        d.candidates = [(2, searchBox), (4, InputCandidate(role: "AXSecureTextField", frame: CGRect(x: 10, y: 10, width: 700, height: 30)))]
        let store = MockStore()
        let r = await make(d, store: store).run("Hello", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .notFound)
        XCTAssertEqual(r.candidates, 2)
        XCTAssertFalse(d.log.contains { $0.hasPrefix("set:") || $0 == "cmdV" })
        XCTAssertEqual(store.readString(), "Hello", "找不到输入框时英文仍在剪贴板")
    }

    func testActivationFailureDoesNothingButCopy() async {
        let d = MockReplyDriver(); d.activates = false; d.candidates = [(3, messageBox)]
        let store = MockStore()
        let r = await make(d, store: store).run("Hello", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .activationFailed)
        XCTAssertEqual(d.log, ["activate"])
        XCTAssertEqual(store.readString(), "Hello")
    }

    func testUntrustedCopiesOnly() async {
        let d = MockReplyDriver()
        let store = MockStore()
        let r = await make(d, store: store).run("Hello", accessibilityTrusted: false)
        XCTAssertEqual(r.result, .notFound)
        XCTAssertEqual(d.log, [], "未授权时不做任何 AX 操作")
        XCTAssertEqual(store.readString(), "Hello")
    }

    func testClipboardKeptAndNoRetrigger() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]; d.setWorks = false   // 走 ⌘V
        let store = MockStore()
        store.items = [["public.utf8-plain-text": Data("Are you free tomorrow?".utf8)]]
        let watcher = ClipboardWatcher(pasteboard: store)
        var shown: [String] = []; watcher.onEnglishText = { shown.append($0) }
        let r = await make(d, store: store, watcher: watcher).run("Yes, I am free.", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .pasted)
        XCTAssertEqual(watcher.poll(), .ignore(.ownChange))
        XCTAssertEqual(shown, [])
        XCTAssertEqual(store.readString(), "Yes, I am free.", "这个流程不恢复旧剪贴板：英文留在剪贴板里")
        XCTAssertFalse(store.log.contains("restore"))
        XCTAssertFalse(store.log.contains("snapshot"))
    }

    func testLogLineHasNoText() async {
        let d = MockReplyDriver(); d.candidates = [(3, messageBox)]
        let r = await make(d).run("secret words", accessibilityTrusted: true)
        XCTAssertFalse(r.logLine.contains("secret"))
        XCTAssertTrue(r.logLine.hasPrefix("reply result=insertedAX target=searched focus=ax candidates=1 role=AXTextField"))
    }
}
