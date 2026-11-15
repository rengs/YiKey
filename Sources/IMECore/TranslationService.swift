import Foundation

public struct TranslationResult: Equatable, Sendable {
    public let original: String
    public let translated: String
    public let source: TextLanguage
    public let target: TextLanguage
    public let providerID: String
    /// 本次应用的术语数（0 = 没有用术语表）与方式（inject / placeholder / single）
    public var glossaryTerms: Int = 0
    public var glossaryMode: String = ""
    public var glossaryLost: Int = 0

    public init(original: String, translated: String, source: TextLanguage,
                target: TextLanguage, providerID: String) {
        self.original = original; self.translated = translated
        self.source = source; self.target = target; self.providerID = providerID
    }
}

public enum TranslationError: Error, Equatable, Sendable, LocalizedError {
    case emptyInput
    case unsupportedLanguage
    case noProviderAvailable
    case timeout
    case providerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "输入为空"
        case .unsupportedLanguage: return "无法识别语言（仅支持中文与英文）"
        case .noProviderAvailable:
            return "没有可用的翻译引擎。macOS 15+ 请在 系统设置 › 通用 › 语言与地区 › 翻译语言 下载中文与英文语言包；或在菜单中启用并配置在线备用翻译。"
        case .timeout: return "翻译超时"
        case .providerFailed(let m): return "翻译失败：\(m)"
        }
    }
}

/// 可插拔翻译提供者。实现只需翻译“一个方向”的一段文本。
public protocol TranslationProvider: Sendable {
    var id: String { get }
    func isAvailable(from: TextLanguage, to: TextLanguage) async -> Bool
    func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String
    /// 启动时预热（如缓存可用性查询），默认什么都不做
    func prewarm() async
}
public extension TranslationProvider {
    func prewarm() async {}
}

/// 按顺序尝试 providers：不可用 / 失败 / 超时 → 下一个；被取消 → 立即抛出，不回退。
/// 所有工作都在 actor / 后台线程，调用方永远不在主线程等待网络或模型。
public actor TranslationService {
    private var providers: [TranslationProvider]
    private let timeout: TimeInterval
    /// 同步可读：协调器在主线程直接查缓存，命中则零等待
    public nonisolated let cache: TranslationCache
    /// 术语保护（离线术语表）；nil = 不用
    private let glossary: TermProtecting?

    public init(providers: [TranslationProvider], timeout: TimeInterval = 8,
                cache: TranslationCache = TranslationCache(), glossary: TermProtecting? = nil) {
        self.providers = providers
        self.timeout = timeout
        self.cache = cache
        self.glossary = glossary
    }

    public func setProviders(_ new: [TranslationProvider]) {
        providers = new
        cache.removeAll()
    }

    public func prewarm() async {
        for p in providers { await p.prewarm() }
    }

    public func translate(_ raw: String) async throws -> TranslationResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationError.emptyInput }

        let source: TextLanguage
        switch LanguageDetector.detect(text) {
        case .chinese: source = .chinese
        case .english: source = .english
        case .unknown: throw TranslationError.unsupportedLanguage
        }
        let target = source.opposite

        if let hit = cache.lookup(text) { return hit }

        // 术语保护：查表 < 1ms，在 actor 上（不在主线程/按键路径上）
        if let plan = glossary?.plan(for: text, from: source) {
            var result: TranslationResult
            if let direct = plan.singleTermOutput {
                result = TranslationResult(original: text, translated: direct, source: source, target: target, providerID: "glossary")
                result.glossaryMode = "single"
            } else {
                let (out1, id1) = try await runProviders(plan.injectedText, source: source, target: target)
                var best = plan.acceptInjected(out1)
                var pid = id1
                if !best.lost.isEmpty {
                    // 有术语没保住 → 用占位符再译一次，取丢得少的
                    if let (out2, id2) = try? await runProviders(plan.placeholderText, source: source, target: target) {
                        let r2 = plan.restorePlaceholders(out2)
                        if r2.lost.count < best.lost.count { best = r2; pid = id2 }
                    }
                }
                result = TranslationResult(original: text, translated: best.text, source: source, target: target, providerID: pid)
                result.glossaryMode = best.mode
                result.glossaryLost = best.lost.count
            }
            result.glossaryTerms = plan.slots.count
            cache.insert(result)
            return result
        }

        let (out, pid) = try await runProviders(text, source: source, target: target)
        let result = TranslationResult(original: text, translated: out, source: source, target: target, providerID: pid)
        cache.insert(result)
        return result
    }

    private func runProviders(_ text: String, source: TextLanguage, target: TextLanguage) async throws -> (String, String) {
        var lastError: Error = TranslationError.noProviderAvailable
        let timeout = self.timeout
        for provider in providers {
            try Task.checkCancellation()
            guard await provider.isAvailable(from: source, to: target) else { continue }
            do {
                let out = try await withTimeout(seconds: timeout) {
                    try await provider.translate(text, from: source, to: target)
                }
                let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else {
                    lastError = TranslationError.providerFailed("\(provider.id): 空结果")
                    continue
                }
                return (clean, provider.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

func withTimeout<T: Sendable>(seconds: TimeInterval,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranslationError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TranslationError.timeout }
        return first
    }
}
