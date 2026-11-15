#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
import AVFoundation
@testable import IMECore

/// 核心约束：发音绝不自动播放，只有点击按钮（pronounceTapped）才触发；只读英文那一侧（中→英读译文、英→中读原文），美式 en-US；中文永远不读。
@MainActor
final class PronunciationTests: XCTestCase {

    private func makeCoordinator(_ speaker: MockSpeaker) -> TranslationCoordinator {
        let provider = MockProvider(id: "mock") { _, from, _ in from == .chinese ? "Hello" : "你好" }
        return TranslationCoordinator(service: TranslationService(providers: [provider]),
                                      speaker: speaker, debounce: 0)
    }

    func testNoAutoSpeakWhenTranslationCompletes() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        c.update(text: "你好"); await c.settle()
        XCTAssertEqual(c.result?.translated, "Hello")
        XCTAssertTrue(c.canPronounce)
        XCTAssertEqual(spk.spoken, [], "翻译完成后不得自动朗读")
    }

    func testNoAutoSpeakAcrossManyUpdatesAndReset() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        for t in ["你", "你好", "谢谢", "再见"] { c.update(text: t) }
        await c.settle(); c.reset()
        XCTAssertEqual(spk.spoken, [])
    }

    func testSpeaksOnlyWhenButtonTapped() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        c.update(text: "你好"); await c.settle()
        c.pronounceTapped()
        XCTAssertEqual(spk.spoken, ["Hello"])
        c.pronounceTapped()
        XCTAssertEqual(spk.spoken, ["Hello", "Hello"])   // 每次点击一次
    }

    // 新需求（2026-11-14）：英→中时，英文原文旁也有 🔊，点击才读英文原文；中文译文不读。
    func testEnglishSourcePronouncesOriginalOnlyWhenTapped() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        c.update(text: "hello"); await c.settle()
        XCTAssertEqual(c.result?.translated, "你好")
        XCTAssertTrue(c.canPronounce)
        XCTAssertTrue(c.canPronounceSource, "英文原文旁应有发音按钮")
        XCTAssertFalse(c.canPronounceTranslation, "中文译文旁不应有发音按钮")
        XCTAssertEqual(c.pronunciationText, "hello")
        XCTAssertEqual(spk.spoken, [], "英文原文翻译完成后不得自动朗读")
        c.pronounceTapped()
        XCTAssertEqual(spk.spoken, ["hello"], "点击读的是英文原文，不是中文译文")
        c.pronounceTapped()
        XCTAssertEqual(spk.spoken, ["hello", "hello"])
    }

    func testNoAutoSpeakForEnglishSourceAcrossUpdatesAndReset() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        for t in ["h", "he", "hello", "hello world", "good morning"] { c.update(text: t); await c.settle() }
        c.reset()
        c.update(text: "thanks"); await c.settle()
        XCTAssertEqual(spk.spoken, [], "英文输入、改动、重置、再次翻译都不得自动朗读")
    }

    func testChineseIsNeverSpokenInEitherDirection() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        c.update(text: "你好"); await c.settle(); c.pronounceTapped()
        c.update(text: "good night"); await c.settle(); c.pronounceTapped()
        XCTAssertEqual(spk.spoken, ["Hello", "good night"])
        for t in spk.spoken {
            XCTAssertFalse(t.unicodeScalars.contains { LanguageDetector.isHan($0) }, "不得朗读中文：\(t)")
        }
    }

    func testPronunciationTextPerDirection() async {
        let spk = MockSpeaker(); let c = makeCoordinator(spk)
        XCTAssertNil(c.pronunciationText)
        c.update(text: "你好"); await c.settle()
        XCTAssertEqual(c.pronunciationText, "Hello")
        XCTAssertTrue(c.canPronounceTranslation); XCTAssertFalse(c.canPronounceSource)
        c.update(text: "hello"); await c.settle()
        XCTAssertEqual(c.pronunciationText, "hello")
        XCTAssertTrue(c.canPronounceSource); XCTAssertFalse(c.canPronounceTranslation)
        c.reset()
        XCTAssertNil(c.pronunciationText); XCTAssertFalse(c.canPronounce)
    }

    func testEnglishSourceTapIgnoredWhileLoading() async {
        let spk = MockSpeaker()
        let slow = MockProvider(id: "slow") { _, _, _ in try await Task.sleep(nanoseconds: 50_000_000); return "你好" }
        let c = TranslationCoordinator(service: TranslationService(providers: [slow]), speaker: spk, debounce: 0)
        c.update(text: "hello"); c.pronounceTapped()       // loading：按钮未显示，点击也不读
        XCTAssertFalse(c.canPronounceSource)
        await c.settle()
        XCTAssertEqual(spk.spoken, [])
    }

    func testTapIgnoredWhenIdleOrLoadingOrFailed() async {
        let spk = MockSpeaker()
        let failing = MockProvider(id: "f") { _, _, _ in throw TranslationError.providerFailed("x") }
        let c = TranslationCoordinator(service: TranslationService(providers: [failing]), speaker: spk, debounce: 0)
        c.pronounceTapped()                              // idle
        c.update(text: "你好"); c.pronounceTapped()      // loading
        await c.settle(); c.pronounceTapped()            // failed
        XCTAssertEqual(spk.spoken, [])
    }

    func testUtteranceUsesAmericanEnglish() throws {
        XCTAssertEqual(SpeechService.voiceLanguage, "en-US")
        let u = SpeechService.makeUtterance("hello")
        let voice = try XCTUnwrap(u.voice, "本机没有 en-US 语音，请在 系统设置 › 辅助功能 › 朗读内容 下载")
        XCTAssertEqual(voice.language, "en-US")
    }

    /// 静态守卫：防止以后有人在别处偷偷加自动朗读。
    func testSourceGuardOnlyCoordinatorCallsSpeak() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let en = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in en where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            switch name {
            case "SpeechService.swift":
                break
            case "TranslationCoordinator.swift":
                XCTAssertEqual(text.components(separatedBy: ".speak(").count - 1, 1)
                let fn = try XCTUnwrap(text.range(of: "func pronounceTapped"))
                let call = try XCTUnwrap(text.range(of: ".speak("))
                XCTAssertTrue(fn.lowerBound < call.lowerBound, "speak 只能出现在 pronounceTapped 内")
            default:
                XCTAssertFalse(text.contains(".speak("), "\(name) 不应调用 speak")
                XCTAssertFalse(text.contains("AVSpeechSynthesizer"), "\(name) 不应直接使用 AVSpeechSynthesizer")
            }
        }
        XCTAssertGreaterThan(checked, 5)
    }
}
