// Apple 本地 Translation 框架（离线）适配。
// 公开 API 的限制：macOS 15/26 上，可编程翻译只能通过 SwiftUI 的 .translationTask 拿到 TranslationSession，
// 且需要一个在窗口里的 SwiftUI 视图。所以这里用“桥”：翻译请求入队 → 改 configuration 触发 translationTask
// → 在回调里用 session 翻译 → 通过 continuation 返回。宿主视图放在浮窗里（浮窗显示时才会翻译）。
// macOS 14 没有 Translation 的可编程 API，Provider 会返回“不可用”，由在线备用接管。
#if canImport(Translation)
import SwiftUI
import Translation
import IMECore

@available(macOS 15.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    @Published private(set) var configuration: TranslationSession.Configuration?

    private struct Pair: Equatable { let source: TextLanguage; let target: TextLanguage }
    private struct Pending {
        let id: UUID
        let text: String
        let pair: Pair
        let continuation: CheckedContinuation<String, Error>
    }

    private var queue: [Pending] = []
    private var inflight: [UUID: Pending] = [:]
    private var activePair: Pair?

    func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String {
        let id = UUID()
        let pair = Pair(source: from, target: to)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                queue.append(Pending(id: id, text: text, pair: pair, continuation: cont))
                kick(pair)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// 由 .translationTask 的回调调用：session 只在回调期间有效，不要保存。
    func process(_ session: TranslationSession) async {
        guard let pair = activePair else { return }
        let batch = queue.filter { $0.pair == pair }
        queue.removeAll { $0.pair == pair }
        for p in batch { inflight[p.id] = p }

        for (i, p) in batch.enumerated() {
            guard inflight[p.id] != nil else { continue }   // 期间已被取消
            do {
                let response = try await session.translate(p.text)
                finish(p.id, .success(response.targetText))
            } catch {
                if Task.isCancelled {
                    // 被新的 configuration/invalidate 打断：把没做完的放回队首，由下一次回调处理
                    for q in batch[i...].reversed() where inflight[q.id] != nil {
                        inflight[q.id] = nil
                        queue.insert(q, at: 0)
                    }
                    return
                }
                finish(p.id, .failure(error))
            }
        }
        if let next = queue.first { kick(next.pair) }
    }

    private func kick(_ pair: Pair) {
        if activePair == pair, var c = configuration {
            c.invalidate()
            configuration = c
        } else {
            activePair = pair
            configuration = .init(source: Locale.Language(identifier: pair.source.bcp47),
                                  target: Locale.Language(identifier: pair.target.bcp47))
        }
    }

    private func finish(_ id: UUID, _ result: Result<String, Error>) {
        guard let p = inflight.removeValue(forKey: id) else { return }
        p.continuation.resume(with: result)
    }

    private func cancel(_ id: UUID) {
        if let i = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: i).continuation.resume(throwing: CancellationError())
        } else if let p = inflight.removeValue(forKey: id) {
            p.continuation.resume(throwing: CancellationError())
        }
    }
}

@available(macOS 15.0, *)
struct AppleTranslationHostView: View {
    @ObservedObject var bridge: AppleTranslationBridge
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .translationTask(bridge.configuration) { session in
                await bridge.process(session)
            }
    }
}

@available(macOS 15.0, *)
final class AppleTranslationProvider: TranslationProvider, @unchecked Sendable {
    let id = "apple"
    private let bridge: AppleTranslationBridge
    private struct Cached { let value: Bool; let at: Date }
    private let lock = NSLock()
    private var availability: [String: Cached] = [:]

    init(bridge: AppleTranslationBridge) { self.bridge = bridge }

    /// LanguageAvailability 查询有开销：按语言对缓存 30 秒，避免每次翻译都查
    func isAvailable(from: TextLanguage, to: TextLanguage) async -> Bool {
        let key = "\(from.rawValue)>\(to.rawValue)"
        if let hit = lock.withLock({ availability[key] }), Date().timeIntervalSince(hit.at) < 30 { return hit.value }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: from.bcp47),
            to: Locale.Language(identifier: to.bcp47))
        // .supported = 支持但语言包未安装：翻译时系统会弹出下载提示；.unsupported 才跳过
        let ok = status != .unsupported
        lock.withLock { availability[key] = Cached(value: ok, at: Date()) }
        return ok
    }

    func prewarm() async {
        _ = await isAvailable(from: .chinese, to: .english)
        _ = await isAvailable(from: .english, to: .chinese)
    }

    func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String {
        try await bridge.translate(text, from: from, to: to)
    }
}
#endif
