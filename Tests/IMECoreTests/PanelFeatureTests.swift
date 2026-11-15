#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
import CoreGraphics
@testable import IMECore

// MARK: - 输入框尺寸：35 个汉字才换行

final class InputBoxSizerTests: XCTestCase {
    private let sizer = InputBoxSizer(cjkAdvance: 16, lineHeight: 20, minTextWidth: 260,
                                      horizontalPadding: 20, verticalPadding: 6, maxLines: 10)

    /// 简易排版：汉字 16pt，其余 8pt；按字符贪心折行
    private func width(_ s: String) -> CGFloat {
        s.reduce(0) { $0 + ($1.unicodeScalars.first.map { LanguageDetector.isHan($0) } == true ? 16 : 8) }
    }
    private func wrappedHeight(_ s: String) -> (CGFloat) -> CGFloat {
        { maxW in
            var lines = 1; var cur: CGFloat = 0
            for ch in s {
                let w: CGFloat = ch.unicodeScalars.first.map { LanguageDetector.isHan($0) } == true ? 16 : 8
                if cur + w > maxW + 0.001 { lines += 1; cur = w } else { cur += w }
            }
            return CGFloat(lines) * 20
        }
    }
    private func layout(_ s: String) -> InputBoxLayout { sizer.layout(singleLineWidth: width(s), wrappedHeight: wrappedHeight(s)) }

    func testThresholdIs35ChineseCharacters() {
        XCTAssertEqual(InputBoxSizer.wrapThresholdChineseChars, 35)
        XCTAssertEqual(sizer.maxTextWidth, 560)
    }

    func testExactly35ChineseCharactersDoesNotWrap() {
        let l = layout(String(repeating: "中", count: 35))
        XCTAssertFalse(l.wraps)
        XCTAssertEqual(l.width, 580)          // 560 + 20
        XCTAssertEqual(l.height, 26)          // 单行
    }

    func test36ChineseCharactersWrapsAndGrowsVertically() {
        let l = layout(String(repeating: "中", count: 36))
        XCTAssertTrue(l.wraps)
        XCTAssertEqual(l.width, 580, "换行后宽度封顶在 35 个汉字")
        XCTAssertEqual(l.height, 46, "两行：40 + 6")
    }

    func testWidthGrowsWithTextBeforeWrapping() {
        var last: CGFloat = 0
        for n in stride(from: 17, through: 35, by: 1) {
            let l = layout(String(repeating: "中", count: n))
            XCTAssertFalse(l.wraps)
            XCTAssertGreaterThan(l.width, last, "\(n) 个字应比 \(n - 1) 个字更宽")
            last = l.width
        }
    }

    func testShortAndEmptyTextUseMinimumWidth() {
        XCTAssertEqual(layout("").width, 280)
        XCTAssertEqual(layout("你好").width, 280)
        XCTAssertEqual(layout("").height, 26)
        XCTAssertEqual(sizer.singleLine, layout(""))
    }

    func testHeightGrowsWithMoreLinesAndIsCapped() {
        let three = layout(String(repeating: "中", count: 80))     // 3 行
        XCTAssertEqual(three.height, 66)
        let huge = layout(String(repeating: "中", count: 2000))    // 封顶 10 行
        XCTAssertEqual(huge.height, 206)
        XCTAssertTrue(huge.wraps)
    }

    func testEnglishUsesSameWidthThreshold() {
        // 70 个英文字符（8pt）= 560pt，等于 35 个汉字宽，不换行；71 个换行
        XCTAssertFalse(layout(String(repeating: "a", count: 70)).wraps)
        XCTAssertTrue(layout(String(repeating: "a", count: 71)).wraps)
    }

    func testFloatingPointToleranceAtThreshold() {
        let l = sizer.layout(singleLineWidth: 560.3, wrappedHeight: { _ in 40 })
        XCTAssertFalse(l.wraps)
    }
}

// MARK: - ⌘V 粘贴到英文组词

final class PasteCompositionTests: XCTestCase {
    func testPasteEnglishIntoEmptyStartsComposition() {
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.paste("Hello world")), .update)
        XCTAssertEqual(b.text, "Hello world")
    }

    func testPasteAppendsWhileComposing() {
        var b = CompositionBuffer()
        for c in "good " { _ = b.handle(.character(String(c))) }
        XCTAssertEqual(b.handle(.paste("morning")), .update)
        XCTAssertEqual(b.text, "good morning")
        XCTAssertEqual(b.handle(.character("!")), .update)
        XCTAssertEqual(b.text, "good morning!")
        XCTAssertEqual(b.handle(.delete), .update)
        XCTAssertEqual(b.text, "good morning")
    }

    func testPasteChineseIntoEmptyPassesThrough() {
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.paste("你好世界")), .passThrough, "中文粘贴交给应用正常处理")
        XCTAssertTrue(b.isEmpty)
    }

    func testPasteNonTextIntoEmptyPassesThrough() {
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.paste("12345")), .passThrough)
        XCTAssertEqual(b.handle(.paste("   \n\t ")), .passThrough)
        XCTAssertTrue(b.isEmpty)
    }

    func testPasteNormalizesNewlinesAndSpaces() {
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.paste("  Hello\r\nbig\tworld \n")), .update)
        XCTAssertEqual(b.text, "Hello big world")
        XCTAssertEqual(PasteNormalizer.normalize("a\u{0007}b"), "ab")
    }

    func testTooLongPasteIsNotTakenOver() {
        let long = String(repeating: "word ", count: 200)            // 1000 字符
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.paste(long)), .passThrough)
        _ = b.handle(.character("a"))
        XCTAssertEqual(b.handle(.paste(long)), .flushThenPass, "组词中粘贴过长文本：先上屏已输入的，再让应用粘贴")
        XCTAssertNil(PasteNormalizer.normalize(long))
        XCTAssertNotNil(PasteNormalizer.normalize(String(repeating: "a", count: PasteNormalizer.maxLength)))
    }

    func testAppendIsCappedAtMaxLength() {
        var b = CompositionBuffer()
        _ = b.handle(.paste(String(repeating: "a", count: 400)))
        _ = b.handle(.paste(String(repeating: "b", count: 400)))
        XCTAssertEqual(b.text.count, PasteNormalizer.maxLength)
    }

    func testPasteHandlingIsFast() {
        let text = String(repeating: "hello world ", count: 41)       // ~492 字符
        let t0 = LatencyMonitor.now()
        for _ in 0..<1000 { var b = CompositionBuffer(); _ = b.handle(.paste(text)) }
        let perMs = LatencyMonitor.ms(since: t0) / 1000
        print("paste handle (~490 chars): \(perMs) ms")
        XCTAssertLessThan(perMs, 1.0, "粘贴处理（清理+语言判断）应远小于 5ms 预算")
    }

    @MainActor
    func testPastedTextTriggersTranslation() async {
        let p = MockProvider(id: "p") { t, _, _ in "译:" + t }
        let c = TranslationCoordinator(service: TranslationService(providers: [p]), speaker: MockSpeaker(),
                                       debounce: 0, monitor: LatencyMonitor())
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.paste("Good morning\n")), .update)
        c.update(text: b.text); await c.settle()
        XCTAssertEqual(c.result?.original, "Good morning")
        XCTAssertEqual(c.result?.target, .chinese)
        XCTAssertEqual(p.calls.count, 1)
    }
}

// MARK: - ↩ 复制译文到剪贴板

final class MockClipboard: ClipboardWriting {
    private(set) var writes: [String] = []
    func write(_ text: String) { writes.append(text) }
}

@MainActor
final class TranslationCopierTests: XCTestCase {
    private func make(debounce: TimeInterval = 0.2, delayMs: UInt64 = 0,
                      fail: Bool = false) -> (TranslationCoordinator, TranslationCopier, MockClipboard, MockProvider) {
        let p = MockProvider(id: "p") { t, from, _ in
            if delayMs > 0 { try await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            if fail { throw TranslationError.providerFailed("boom") }
            return from == .chinese ? "EN(\(t))" : "ZH(\(t))"
        }
        let c = TranslationCoordinator(service: TranslationService(providers: [p]), speaker: MockSpeaker(),
                                       debounce: debounce, monitor: LatencyMonitor())
        let clip = MockClipboard()
        return (c, TranslationCopier(coordinator: c, clipboard: clip), clip, p)
    }

    func testEnterCopiesReadyEnglishTranslation() async {
        let (c, copier, clip, _) = make(debounce: 0)
        c.update(text: "你好"); await c.settle()
        let r = await copier.copyTranslation(of: "你好")
        XCTAssertEqual(r, .copied("EN(你好)"))
        XCTAssertEqual(clip.writes, ["EN(你好)"])
    }

    func testEnterWaitsForPendingTranslation() async {
        let (c, copier, clip, p) = make(debounce: 0.2, delayMs: 100)
        c.update(text: "今天天气不错")                       // 仍在防抖中
        XCTAssertEqual(c.phase, .loading)
        let r = await copier.copyTranslation(of: "今天天气不错")
        XCTAssertEqual(r, .copied("EN(今天天气不错)"))
        XCTAssertEqual(clip.writes, ["EN(今天天气不错)"])
        XCTAssertEqual(p.calls.count, 1, "等待已有请求，不重复翻译")
    }

    func testEnterBeforeCoordinatorSawTextStillCopies() async {
        let (_, copier, clip, _) = make(debounce: 0.2)
        let r = await copier.copyTranslation(of: "  谢谢 ")
        XCTAssertEqual(r, .copied("EN(谢谢)"))
        XCTAssertEqual(clip.writes, ["EN(谢谢)"])
    }

    func testEnterDoesNotBlockMainThread() async {
        let (_, copier, clip, _) = make(debounce: 0.2, delayMs: 200)
        let t0 = LatencyMonitor.now()
        let task = Task { @MainActor in await copier.copyTranslation(of: "再见") }
        let syncMs = LatencyMonitor.ms(since: t0)
        print("enter→copy synchronous part: \(syncMs) ms")
        XCTAssertLessThan(syncMs, 5.0, "按 ↩ 在主线程的同步开销必须 < 5ms")
        XCTAssertEqual(clip.writes, [], "翻译完成前不写剪贴板")
        let r = await task.value
        XCTAssertEqual(r, .copied("EN(再见)"))
    }

    func testEmptyInputCopiesNothing() async {
        let (_, copier, clip, _) = make()
        let r = await copier.copyTranslation(of: "   ")
        XCTAssertEqual(r, .nothingToCopy)
        XCTAssertEqual(clip.writes, [])
    }

    func testFailedTranslationCopiesNothing() async {
        let (_, copier, clip, _) = make(debounce: 0, fail: true)
        let r = await copier.copyTranslation(of: "你好")
        if case .failed = r {} else { XCTFail("应为 failed，实际 \(r)") }
        XCTAssertEqual(clip.writes, [])
    }

    func testSupersededWhenInputChangesWhileWaiting() async throws {
        let (c, copier, clip, _) = make(debounce: 0.05, delayMs: 100)
        let task = Task { @MainActor in await copier.copyTranslation(of: "你好") }
        try await Task.sleep(nanoseconds: 70_000_000)
        c.update(text: "你好世界")                           // 用户继续输入
        let r = await task.value
        XCTAssertEqual(r, .superseded)
        XCTAssertEqual(clip.writes, [])
    }

    func testEnglishInputCopiesChineseTranslation() async {
        let (_, copier, clip, _) = make(debounce: 0)
        let r = await copier.copyTranslation(of: "good night")
        XCTAssertEqual(r, .copied("ZH(good night)"))
        XCTAssertEqual(clip.writes, ["ZH(good night)"])
    }

    func testCopyNeverSpeaks() async {
        let spk = MockSpeaker()
        let p = MockProvider(id: "p") { _, _, _ in "Hello" }
        let c = TranslationCoordinator(service: TranslationService(providers: [p]), speaker: spk, debounce: 0)
        let copier = TranslationCopier(coordinator: c, clipboard: MockClipboard())
        _ = await copier.copyTranslation(of: "你好")
        XCTAssertEqual(spk.spoken, [], "复制不得触发发音")
    }
}

// MARK: - 打开面板自动切到简体拼音（Mock 系统输入源）

@MainActor
final class MockInputSourceSystem: InputSourceSystem {
    var current: String?
    var sources: [InputSourceInfo]
    var failSelect = false
    private(set) var selects: [String] = []
    init(current: String?, sources: [InputSourceInfo]) { self.current = current; self.sources = sources }
    func currentSourceID() -> String? { current }
    func enabledSources() -> [InputSourceInfo] { sources.filter(\.isEnabled) }
    func select(id: String) -> Bool {
        selects.append(id)
        guard !failSelect, sources.contains(where: { $0.id == id && $0.isEnabled }) else { return false }
        current = id; return true
    }
}

@MainActor
final class InputSourceSwitcherTests: XCTestCase {
    static let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", localizedName: "ABC", languages: ["en"])
    static let ime = InputSourceInfo(id: "com.example.inputmethod.TranslateIME.Translate", localizedName: "Translate IME", languages: ["en"])
    static let pinyin = InputSourceInfo(id: "com.apple.inputmethod.SCIM.ITABC", localizedName: "拼音 – 简体", languages: ["zh-Hans"])
    static let tcPinyin = InputSourceInfo(id: "com.apple.inputmethod.TCIM.Pinyin", localizedName: "拼音 – 繁體", languages: ["zh-Hant"])
    static let sogou = InputSourceInfo(id: "com.sogou.inputmethod.sogou.pinyin", localizedName: "搜狗拼音", languages: ["zh-Hans"])

    func testSwitchesToEnabledSimplifiedPinyinAndRestores() {
        let sys = MockInputSourceSystem(current: Self.ime.id, sources: [Self.abc, Self.ime, Self.pinyin])
        let sw = InputSourceSwitcher(system: sys)
        XCTAssertEqual(sw.activatePinyin(), .switched(from: Self.ime.id, to: Self.pinyin.id))
        XCTAssertEqual(sys.current, Self.pinyin.id)
        XCTAssertTrue(sw.restore())
        XCTAssertEqual(sys.current, Self.ime.id, "关闭面板恢复原输入源")
        XCTAssertFalse(sw.restore(), "只恢复一次")
        XCTAssertEqual(sys.selects, [Self.pinyin.id, Self.ime.id])
    }

    func testPrefersAppleSimplifiedPinyin() {
        let sys = MockInputSourceSystem(current: Self.abc.id, sources: [Self.sogou, Self.tcPinyin, Self.pinyin])
        let sw = InputSourceSwitcher(system: sys)
        XCTAssertEqual(sw.activatePinyin(), .switched(from: Self.abc.id, to: Self.pinyin.id))
    }

    func testFallsBackToOtherSimplifiedPinyinButNeverTraditional() {
        XCTAssertEqual(InputSourcePicker.pickSimplifiedPinyin(from: [Self.abc, Self.tcPinyin, Self.sogou])?.id, Self.sogou.id)
        XCTAssertNil(InputSourcePicker.pickSimplifiedPinyin(from: [Self.abc, Self.tcPinyin]))
    }

    func testIgnoresDisabledOrNonSelectableSources() {
        var disabled = Self.pinyin; disabled.isEnabled = false
        var notSelectable = Self.pinyin; notSelectable.isSelectCapable = false
        XCTAssertNil(InputSourcePicker.pickSimplifiedPinyin(from: [disabled]))
        XCTAssertNil(InputSourcePicker.pickSimplifiedPinyin(from: [notSelectable]))
    }

    func testNoPinyinShowsHintAndChangesNothing() {
        let sys = MockInputSourceSystem(current: Self.abc.id, sources: [Self.abc, Self.ime])
        let sw = InputSourceSwitcher(system: sys)
        XCTAssertEqual(sw.activatePinyin(), .noPinyin)
        XCTAssertEqual(sys.selects, [], "没有拼音时不得调用 select（更不会启用/添加输入源）")
        XCTAssertFalse(sw.restore())
        XCTAssertEqual(sys.current, Self.abc.id)
    }

    func testAlreadyPinyinDoesNotSwitchOrRestore() {
        let sys = MockInputSourceSystem(current: Self.pinyin.id, sources: [Self.abc, Self.pinyin])
        let sw = InputSourceSwitcher(system: sys)
        XCTAssertEqual(sw.activatePinyin(), .alreadyActive(Self.pinyin.id))
        XCTAssertFalse(sw.restore())
        XCTAssertEqual(sys.selects, [])
    }

    func testSelectFailureIsReportedAndNotRestored() {
        let sys = MockInputSourceSystem(current: Self.abc.id, sources: [Self.abc, Self.pinyin])
        sys.failSelect = true
        let sw = InputSourceSwitcher(system: sys)
        XCTAssertEqual(sw.activatePinyin(), .selectFailed(Self.pinyin.id))
        XCTAssertFalse(sw.restore())
    }

    func testRepeatedActivateKeepsOriginalSource() {
        let sys = MockInputSourceSystem(current: Self.abc.id, sources: [Self.abc, Self.pinyin])
        let sw = InputSourceSwitcher(system: sys)
        _ = sw.activatePinyin()
        sys.current = Self.abc.id                               // 激活过程把输入源切回去了
        _ = sw.activatePinyin()
        XCTAssertEqual(sw.savedSourceID, Self.abc.id)
        _ = sw.restore()
        XCTAssertEqual(sys.current, Self.abc.id)
    }

    func testReassertOnlyWhenSourceDrifted() {
        let sys = MockInputSourceSystem(current: Self.abc.id, sources: [Self.abc, Self.pinyin])
        let sw = InputSourceSwitcher(system: sys)
        _ = sw.activatePinyin()
        XCTAssertFalse(sw.reassertIfNeeded(), "仍是拼音时不重复切换")
        sys.current = Self.abc.id
        XCTAssertTrue(sw.reassertIfNeeded())
        XCTAssertEqual(sys.current, Self.pinyin.id)
    }

    func testRestoreSkippedWhenAlreadyBackOnPreviousSource() {
        let sys = MockInputSourceSystem(current: Self.abc.id, sources: [Self.abc, Self.pinyin])
        let sw = InputSourceSwitcher(system: sys)
        _ = sw.activatePinyin()
        sys.current = Self.abc.id                               // 用户自己切回去了
        XCTAssertFalse(sw.restore())
        XCTAssertEqual(sys.selects, [Self.pinyin.id])
    }
}
