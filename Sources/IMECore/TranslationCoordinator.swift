import Foundation
import Combine

/// UI 与翻译服务之间的状态机。按键路径上的同步工作只有：trim → 查缓存 → 取消旧任务 → 起新任务（微秒级）。
/// 翻译全部异步：防抖(默认 200ms) → 后台 actor → 回主线程只做一次赋值。
/// 旧任务被取消；即便取消有延迟，generation 计数也保证过期结果绝不会覆盖新结果。
/// 发音：只有 pronounceTapped()（按钮点击）会触发，翻译完成/上屏/关闭都不会。
/// 读的永远是“英文那一侧”：中→英读英文译文，英→中读英文原文；中文（原文或译文）永远不发音。
@MainActor
public final class TranslationCoordinator: ObservableObject {
    public enum Phase: Equatable {
        case idle, loading, ready(TranslationResult), failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var sourceText: String = ""

    private let service: TranslationService
    private let speaker: SpeechSynthesizing
    private let debounce: TimeInterval
    private let vocabulary: VocabularyBook?
    private let monitor: LatencyMonitor
    private var task: Task<Void, Never>?
    private var vocabularyTask: Task<Void, Never>?
    private var generation = 0

    public init(service: TranslationService, speaker: SpeechSynthesizing,
                debounce: TimeInterval = 0.2, vocabulary: VocabularyBook? = nil,
                monitor: LatencyMonitor = .shared) {
        self.service = service
        self.speaker = speaker
        self.debounce = debounce
        self.vocabulary = vocabulary
        self.monitor = monitor
    }

    public var result: TranslationResult? {
        if case .ready(let r) = phase { return r }
        return nil
    }
    public var isReady: Bool { result != nil }
    /// 可发音的英文文本：中→英时是英文译文，英→中时是英文原文；没有结果或没有英文时为 nil。
    public var pronunciationText: String? {
        guard let r = result else { return nil }
        if r.target == .english { return r.translated }
        if r.source == .english { return r.original }
        return nil
    }
    /// 有可读的英文（任一方向）
    public var canPronounce: Bool { pronunciationText != nil }
    /// 英文原文旁的 🔊（英→中）
    public var canPronounceSource: Bool { result?.source == .english }
    /// 英文译文旁的 🔊（中→英）
    public var canPronounceTranslation: Bool { result?.target == .english }

    public func update(text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == sourceText {
            switch phase {
            case .ready, .loading: return
            default: break
            }
        }
        generation &+= 1
        let gen = generation
        task?.cancel(); task = nil
        if sourceText != text { sourceText = text }
        guard !text.isEmpty else { setPhase(.idle); return }

        // 缓存命中：同步出结果，没有防抖、没有 await
        if let hit = service.cache.lookup(text) {
            setPhase(.ready(hit))
            monitor.record(.translation, milliseconds: 0, note: "cache len=\(text.count)")
            return
        }

        setPhase(.loading)
        let delay = debounce
        let started = LatencyMonitor.now()
        task = Task { [service, monitor] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled || gen != self.generation { return }
            let t0 = LatencyMonitor.now()
            do {
                let r = try await service.translate(text)
                monitor.record(.providerCall, milliseconds: LatencyMonitor.ms(since: t0),
                               note: "\(r.providerID) len=\(text.count)")
                guard !Task.isCancelled, gen == self.generation else { return }   // 过期结果丢弃
                monitor.record(.translation, milliseconds: LatencyMonitor.ms(since: started),
                               note: "\(r.providerID) len=\(text.count)")
                self.setPhase(.ready(r))
            } catch is CancellationError {
                // 被新输入取代
            } catch {
                guard !Task.isCancelled, gen == self.generation else { return }
                self.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    public func reset() {
        generation &+= 1
        task?.cancel(); task = nil
        setPhase(.idle)
        if !sourceText.isEmpty { sourceText = "" }
        speaker.stop()
    }

    /// 测试用：等待当前翻译任务结束
    public func settle() async { await task?.value }
    /// 测试用：等待单词本写入任务结束
    public func settleVocabulary() async { await vocabularyTask?.value }

    // 全工程唯一的朗读入口，仅由发音按钮的点击触发。
    // 英→中时读英文原文，中→英时读英文译文；译文/原文中的中文永远不读。
    public func pronounceTapped() {
        guard let r = result, let english = pronunciationText else { return }
        let chinese = r.target == .english ? r.original : r.translated
        speaker.speak(english)

        // 加入单词本：fire-and-forget，去重/计数/落盘都在 VocabularyBook actor 内的后台线程完成，不阻塞主线程。
        guard let book = vocabulary else { return }
        let previous = vocabularyTask
        vocabularyTask = Task.detached(priority: .utility) {
            await previous?.value
            await book.recordPlay(english: english, chinese: chinese)
        }
    }

    private func setPhase(_ p: Phase) { if phase != p { phase = p } }
}
