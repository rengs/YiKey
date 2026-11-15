import Foundation
import AVFoundation

public protocol SpeechSynthesizing: AnyObject {
    func speak(_ text: String)
    func stop()
}

/// 美式英语朗读。本类只提供“能力”，是否播放由调用方决定；
/// 整个工程里只有 TranslationCoordinator.pronounceTapped() 会调用 speak（有测试守卫）。
public final class SpeechService: NSObject, SpeechSynthesizing {
    public static let voiceLanguage = "en-US"
    private lazy var synthesizer = AVSpeechSynthesizer()

    public static func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        return u
    }

    public func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(Self.makeUtterance(t))
    }

    /// 启动时调用，避免第一次点击发音时才初始化合成器
    public func prewarm() { _ = synthesizer }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
