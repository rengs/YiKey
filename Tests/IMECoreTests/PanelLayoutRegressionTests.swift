#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
import AppKit
@testable import IMECore

/// 回归：“换行后第一行被遮挡 / 下面留空白”。
/// 用真实字体 + 真实 NSTextView 排版，验证输入框高度 == 实际文本高度（含内边距），1/2/3/10 行全部完整可见。
@MainActor
final class PanelLayoutRegressionTests: XCTestCase {
    private let measurer = InputBoxTextMeasurer(font: .systemFont(ofSize: 16))
    private lazy var sizer = measurer.makeSizer()
    private let sentence = "我们今天下午和海外大模型团队交流了油田数字化的最新进展，"   // 28 字

    private func text(lines: Int) -> String {
        // 每行 35 个汉字容量：生成 (lines-1)*35 + 10 个字，正好排成 lines 行
        let n = lines == 1 ? 20 : (lines - 1) * 35 + 10
        let pool = Array(String(repeating: sentence, count: n / sentence.count + 2).replacingOccurrences(of: "，", with: "中"))
        return String(pool.prefix(n))
    }

    /// 用与面板相同配置的 NSTextView 在给定宽度下排版，返回（所需高度, 行数）
    private func realTextView(_ s: String, width: CGFloat) -> (height: CGFloat, lines: Int) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        measurer.configure(tv)
        tv.string = s
        let lm = tv.layoutManager!, tc = tv.textContainer!
        lm.ensureLayout(for: tc)
        var lines = 0, idx = 0
        while idx < lm.numberOfGlyphs {
            var r = NSRange(); lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &r); idx = NSMaxRange(r); lines += 1
        }
        return (ceil(lm.usedRect(for: tc).height + 2 * tv.textContainerInset.height), max(lines, 1))
    }

    private func check(lines expected: Int) {
        let s = text(lines: expected)
        let layout = measurer.layout(for: s, sizer: sizer)
        let real = realTextView(s, width: layout.width)
        print("lines=\(expected) chars=\(s.count) layout=\(layout.width)x\(layout.height) realHeight=\(real.height) realLines=\(real.lines)")
        XCTAssertEqual(real.lines, expected, "实际排版行数 lines=\(expected)")
        XCTAssertEqual(layout.wraps, expected > 1, "lines=\(expected)")
        XCTAssertFalse(layout.scrolls, "lines=\(expected)")
        XCTAssertGreaterThanOrEqual(layout.height, real.height, "输入框高度不得小于实际文本高度（否则裁切） lines=\(expected)")
        XCTAssertLessThanOrEqual(layout.height - real.height, 1.0, "输入框不得比文本高出一截（空白） lines=\(expected)")
    }

    func testOneLine() { check(lines: 1) }
    func testTwoLines() { check(lines: 2) }
    func testThreeLines() { check(lines: 3) }
    func testTenLines() { check(lines: 10) }

    func test35CharsStaySingleLineInRealTextView() {
        let s = String(repeating: "中", count: 35)
        let layout = measurer.layout(for: s, sizer: sizer)
        XCTAssertFalse(layout.wraps)
        XCTAssertEqual(realTextView(s, width: layout.width).lines, 1, "35 个汉字在真实 NSTextView 里也是一行")
        let s36 = String(repeating: "中", count: 36)
        let l36 = measurer.layout(for: s36, sizer: sizer)
        XCTAssertTrue(l36.wraps)
        XCTAssertEqual(realTextView(s36, width: l36.width).lines, 2)
    }

    func testMixedChineseEnglishAndPinyinMarkedText() {
        // 拼音组词时，field 里是“汉字 + 拼音字母”混排，也要按真实排版算高度
        let s = text(lines: 2) + " haiwai damoxing jiaoliu"
        let layout = measurer.layout(for: s, sizer: sizer)
        let real = realTextView(s, width: layout.width)
        XCTAssertGreaterThanOrEqual(layout.height, real.height)
        XCTAssertLessThanOrEqual(layout.height - real.height, 1.0)
    }

    func testEmptyTextIsOneLineHigh() {
        let layout = measurer.layout(for: "", sizer: sizer)
        XCTAssertEqual(layout, sizer.singleLine.withHeight(layout.height))
        XCTAssertEqual(layout.height, ceil(measurer.lineHeight + 2 * measurer.inset.height), accuracy: 1)
    }

    func testBeyondMaxLinesCapsHeightAndAllowsScrolling() {
        let s = text(lines: 20)
        let layout = measurer.layout(for: s, sizer: sizer)
        XCTAssertTrue(layout.scrolls)
        XCTAssertEqual(layout.height, ceil(measurer.lineHeight * 15 + 2 * measurer.inset.height), accuracy: 1)
    }
}

private extension InputBoxLayout {
    func withHeight(_ h: CGFloat) -> InputBoxLayout { InputBoxLayout(width: width, height: h, wraps: wraps, scrolls: scrolls) }
}

// MARK: - ↩ / ⇧⌥↩ / ⌥↩ / ⌘↩ 与复制后的面板行为

final class PanelSubmitPolicyTests: XCTestCase {
    func testKeyMapping() {
        XCTAssertEqual(PanelSubmitPolicy.action(command: false, shift: false, option: false), .copyTranslation)
        XCTAssertEqual(PanelSubmitPolicy.action(command: false, shift: true, option: true), .copyAndClear)
        XCTAssertEqual(PanelSubmitPolicy.action(command: false, shift: false, option: true), .commitTranslation)
        XCTAssertEqual(PanelSubmitPolicy.action(command: true, shift: false, option: false), .commitOriginal)
        XCTAssertEqual(PanelSubmitPolicy.action(command: false, shift: true, option: false), .commitOriginal)
        XCTAssertEqual(PanelSubmitPolicy.action(command: true, shift: true, option: true), .commitOriginal)
    }

    func testCopyThenCloseAfterHalfSecondByDefault() {
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.copied("Hi"), action: .copyTranslation, closeAfterCopy: true),
                       .closeAfter(0.5))
    }

    func testCopyStaysOpenWhenAutoCloseDisabled() {
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.copied("Hi"), action: .copyTranslation, closeAfterCopy: false), .stay)
    }

    func testShiftOptionReturnClearsAndStays() {
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.copied("Hi"), action: .copyAndClear, closeAfterCopy: true), .clearAndStay)
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.copied("Hi"), action: .copyAndClear, closeAfterCopy: false), .clearAndStay)
    }

    func testFailureNeverClosesAndShowsError() {
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.failed("网络错误"), action: .copyTranslation, closeAfterCopy: true),
                       .showError("网络错误"))
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.failed("x"), action: .copyAndClear, closeAfterCopy: true), .showError("x"))
    }

    func testEmptyOrSupersededDoesNothing() {
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.nothingToCopy, action: .copyTranslation, closeAfterCopy: true), .nothing)
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(.superseded, action: .copyTranslation, closeAfterCopy: true), .nothing)
    }

    func testHintTextReflectsSetting() {
        XCTAssertTrue(PanelSubmitPolicy.hint(closeAfterCopy: true).hasPrefix("↩ 复制并关闭"))
        XCTAssertTrue(PanelSubmitPolicy.hint(closeAfterCopy: false).hasPrefix("↩ 复制译文"))
        XCTAssertTrue(PanelSubmitPolicy.hint(closeAfterCopy: true).contains("⇧⌥↩ 复制并清空"))
        XCTAssertTrue(PanelSubmitPolicy.hint(closeAfterCopy: true).contains("⌘↩ 上屏原文"))
    }

    func testCloseAfterCopyDefaultsOn() {
        let d = UserDefaults(suiteName: "TranslateIMETests-\(UUID().uuidString)")!
        XCTAssertTrue(IMESettings.flag(IMESettings.closeAfterCopy, defaults: d))
        d.set(false, forKey: IMESettings.closeAfterCopy)
        XCTAssertFalse(IMESettings.flag(IMESettings.closeAfterCopy, defaults: d))
    }

    /// 等待翻译的情况：先“翻译中…”，就绪后复制；结果交给 afterCopy 决定关闭
    @MainActor
    func testPendingTranslationCopiedThenClose() async {
        let p = MockProvider(id: "p") { t, _, _ in try await Task.sleep(nanoseconds: 80_000_000); return "EN(\(t))" }
        let c = TranslationCoordinator(service: TranslationService(providers: [p]), speaker: MockSpeaker(),
                                       debounce: 0.2, monitor: LatencyMonitor())
        let clip = MockClipboard()
        let copier = TranslationCopier(coordinator: c, clipboard: clip)
        let outcome = await copier.copyTranslation(of: "你好")
        XCTAssertEqual(outcome, .copied("EN(你好)"))
        XCTAssertEqual(PanelSubmitPolicy.afterCopy(outcome, action: .copyTranslation, closeAfterCopy: true), .closeAfter(0.5))
        XCTAssertEqual(clip.writes, ["EN(你好)"])
    }
}
