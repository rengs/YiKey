import XCTest
@testable import IMECore

// MARK: - 回复模式中复制别的英文 → 立即切回英文阅读

@MainActor
final class ClipboardOverrideTests: XCTestCase {
    private func watcher(_ pb: MockPasteboard, state: @escaping () -> ClipboardPanelState)
        -> (ClipboardWatcher, () -> [(String, ClipboardTriggerKind)]) {
        let w = ClipboardWatcher(pasteboard: pb, panelState: state)
        var got: [(String, ClipboardTriggerKind)] = []
        w.onTrigger = { got.append(($0, $1)) }
        return (w, { got })
    }

    func testNewCopyDuringReplyOverrides() {
        let pb = MockPasteboard()
        let (w, got) = watcher(pb) { .replying(current: "Can you check the draft?") }
        pb.copy("Please send me the report by Friday.")
        XCTAssertEqual(w.poll(), .translate("Please send me the report by Friday."))
        XCTAssertEqual(got().map(\.1), [.overrideReply])
        XCTAssertEqual(w.lastTriggerKind, .overrideReply)
    }

    func testCtrlOptTTranslatorWithoutContextAlsoOverrides() {
        let pb = MockPasteboard()
        let (w, got) = watcher(pb) { .replying(current: nil) }
        pb.copy("Where are we meeting?")
        XCTAssertEqual(w.poll(), .translate("Where are we meeting?"))
        XCTAssertEqual(got().first?.1, .overrideReply)
    }

    func testSelfCopyDuringReplyStillIgnored() {
        let pb = MockPasteboard()
        let (w, got) = watcher(pb) { .replying(current: "Can you check the draft?") }
        pb.copy("I will check it tomorrow.", types: ["public.utf8-plain-text", ClipboardTextFilter.ownType])
        XCTAssertEqual(w.poll(), .ignore(.ownChange))
        pb.copy("I will check it tonight.")
        w.markOwnChange(pb.changeCount)                   // 自己写的（changeCount 登记）
        XCTAssertEqual(w.poll(), .ignore(.ownChange))
        XCTAssertTrue(got().isEmpty)
    }

    func testSameTextAsCurrentIgnored() {
        let pb = MockPasteboard()
        let (w, got) = watcher(pb) { .replying(current: "Can you check the draft?") }
        pb.copy("  Can you check the draft?\n")
        XCTAssertEqual(w.poll(), .ignore(.duplicate))
        let (w2, got2) = watcher(pb) { .reading(current: "Can you check the draft?") }
        pb.copy("Can you check the draft?")
        XCTAssertEqual(w2.poll(), .ignore(.duplicate))
        XCTAssertTrue(got().isEmpty && got2().isEmpty)
    }

    func testFiltersStillApplyDuringReply() {
        let pb = MockPasteboard()
        let (w, got) = watcher(pb) { .replying(current: "Hi there") }
        pb.copy("https://example.com/report")
        XCTAssertEqual(w.poll(), .ignore(.urlOnly))
        pb.copy("你好，明天见")
        XCTAssertEqual(w.poll(), .ignore(.notEnglish))
        pb.copy("hunter2hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        XCTAssertEqual(w.poll(), .ignore(.sensitiveType))
        XCTAssertTrue(got().isEmpty)
    }

    func testBusyStatesStillNotInterrupted() {
        let pb = MockPasteboard()
        let (w, got) = watcher(pb) { .busy }
        pb.copy("Hello there friend")
        XCTAssertEqual(w.poll(), .ignore(.busy))
        XCTAssertTrue(got().isEmpty)
    }

    func testKindsForIdleAndReading() {
        let pb = MockPasteboard()
        var state = ClipboardPanelState.idle
        let (w, got) = watcher(pb) { state }
        pb.copy("First message here")
        w.poll()
        state = .reading(current: "First message here")
        pb.copy("Second message here")
        w.poll()
        XCTAssertEqual(got().map(\.1), [.fresh, .replaceReading])
    }

    func testLegacyIsBusyAndOnEnglishTextStillWork() {
        let pb = MockPasteboard()
        let w = ClipboardWatcher(pasteboard: pb, isBusy: { false })
        var shown: [String] = []; w.onEnglishText = { shown.append($0) }
        pb.copy("Legacy path works")
        w.poll()
        XCTAssertEqual(shown, ["Legacy path works"])
    }
}

final class ReplySessionTests: XCTestCase {
    struct Src: Equatable { let pid: Int; let window: Int }
    let chatA = Src(pid: 10, window: 1), chatB = Src(pid: 20, window: 7)

    func testOverrideStashesDraftAndUpdatesSource() {
        var s = ReplySession<Src>()
        s.clipboardEnglish("Can you check the draft?", from: chatA)
        XCTAssertNil(s.startReply())
        XCTAssertEqual(s.mode, .replying)
        let t = s.clipboardEnglish("Please send the report.", from: chatB, draft: "我明天会")
        XCTAssertEqual(t, .init(leftReply: true, stashedDraft: true, cancelPending: true))
        XCTAssertEqual(s.mode, .reading)
        XCTAssertEqual(s.english, "Please send the report.")
        XCTAssertEqual(s.source, chatB, "来源更新为新复制的位置")
        XCTAssertEqual(s.stashedDraft, "我明天会")
        XCTAssertEqual(s.stashedSource, chatA)
    }

    func testDraftRestoredOnlyForSameSource() {
        var s = ReplySession<Src>()
        s.clipboardEnglish("One", from: chatA)
        _ = s.startReply()
        s.clipboardEnglish("Two", from: chatB, draft: "草稿")
        XCTAssertNil(s.startReply(), "不同来源：不恢复")
        XCTAssertEqual(s.stashedDraft, "草稿", "仍保留，等回到原来源")
        s.clipboardEnglish("Three", from: chatA, draft: "")
        XCTAssertEqual(s.startReply(), "草稿", "回到同一来源再回复：恢复")
        XCTAssertNil(s.stashedDraft)
    }

    func testSameSourceNewCopyRestoresDraft() {
        var s = ReplySession<Src>()
        s.clipboardEnglish("Can you check the draft?", from: chatA)
        _ = s.startReply()
        s.clipboardEnglish("Also the slides, please.", from: chatA, draft: "好的，我")
        XCTAssertEqual(s.startReply(), "好的，我")
    }

    func testEscapeDropsDraft() {
        var s = ReplySession<Src>()
        s.clipboardEnglish("One", from: chatA)
        _ = s.startReply()
        s.clipboardEnglish("Two", from: chatA, draft: "草稿")
        s.hide()
        XCTAssertNil(s.stashedDraft)
        XCTAssertEqual(s.mode, .hidden)
        s.clipboardEnglish("Three", from: chatA)
        XCTAssertNil(s.startReply())
    }

    func testEmptyDraftNotStashedAndReadingReplaceDoesNotLeaveReply() {
        var s = ReplySession<Src>()
        s.clipboardEnglish("One", from: chatA)
        let t1 = s.clipboardEnglish("Two", from: chatB, draft: "ignored")
        XCTAssertFalse(t1.leftReply); XCTAssertFalse(t1.stashedDraft)
        XCTAssertEqual(s.source, chatB)
        _ = s.startReply()
        let t2 = s.clipboardEnglish("Three", from: chatB, draft: "   ")
        XCTAssertTrue(t2.leftReply); XCTAssertFalse(t2.stashedDraft)
        XCTAssertNil(s.stashedDraft)
    }

    func testUnknownNewSourceKeepsPrevious() {
        var s = ReplySession<Src>()
        s.openTranslator(source: chatA)
        s.clipboardEnglish("Hello again", from: nil, draft: "你好")
        XCTAssertEqual(s.source, chatA)
        XCTAssertEqual(s.startReply(), "你好")
    }
}

@MainActor
final class ReplyCancelTests: XCTestCase {
    private let messageBox = InputCandidate(role: "AXTextField", placeholder: "Type a message",
                                            frame: CGRect(x: 10, y: 10, width: 780, height: 32))

    func testCancelledAfterActivationDoesNotInsertOrPaste() async {
        let d = MockReplyDriver()
        d.candidates = [(3, messageBox)]
        let store = MockStore()
        let r = await ReplyInserter(driver: d, pasteboard: store, markOwn: { _ in }, isCancelled: { true })
            .run("See you", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .cancelled)
        XCTAssertEqual(d.log, ["activate"], "取消后不再找框、不点击、不插入、不发 ⌘V")
        XCTAssertEqual(store.readString(), "See you", "英文仍在剪贴板")
        XCTAssertFalse(r.result.inserted)
    }

    func testCancelledBeforePasteFallback() async {
        let d = MockReplyDriver()
        d.focused = (3, messageBox)
        d.setWorks = false
        var calls = 0
        let r = await ReplyInserter(driver: d, pasteboard: MockStore(), markOwn: { _ in },
                                    isCancelled: { calls += 1; return calls >= 3 })
            .run("See you", accessibilityTrusted: true)
        XCTAssertEqual(r.result, .cancelled)
        XCTAssertFalse(d.log.contains("cmdV"))
    }
}
