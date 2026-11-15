import Foundation
@testable import IMECore

final class MockProvider: TranslationProvider, @unchecked Sendable {
    struct Call: Equatable { let text: String; let from: TextLanguage; let to: TextLanguage }

    let id: String
    let available: Bool
    private let handler: @Sendable (String, TextLanguage, TextLanguage) async throws -> String
    private let lock = NSLock()
    private var _calls: [Call] = []

    init(id: String, available: Bool = true,
         handler: @escaping @Sendable (String, TextLanguage, TextLanguage) async throws -> String) {
        self.id = id; self.available = available; self.handler = handler
    }

    var calls: [Call] { lock.withLock { _calls } }

    func isAvailable(from: TextLanguage, to: TextLanguage) async -> Bool { available }

    func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String {
        lock.withLock { _calls.append(Call(text: text, from: from, to: to)) }
        return try await handler(text, from, to)
    }
}

final class MockSpeaker: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    func speak(_ text: String) { spoken.append(text) }
    func stop() { stopCount += 1 }
}

final class StubHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _last: URLRequest?
    let body: String
    init(body: String) { self.body = body }
    var lastRequest: URLRequest? { lock.withLock { _last } }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _last = request }
        return (Data(body.utf8),
                URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }
}

final class MockSink: LatencySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _slow: [(LatencyMetric, Double)] = []
    private var _summaries = 0
    var slow: [(LatencyMetric, Double)] { lock.withLock { _slow } }
    var summaries: Int { lock.withLock { _summaries } }
    func slow(metric: LatencyMetric, milliseconds: Double, budget: Double, note: String?) {
        lock.withLock { _slow.append((metric, milliseconds)) }
    }
    func summary(_ text: String) { lock.withLock { _summaries += 1 } }
}

func makeTempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateIMETests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 单调递增、整秒的时钟（ISO8601 落盘只有秒精度）
final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Date { lock.withLock { n += 1; return Date(timeIntervalSince1970: 1_700_000_000 + Double(n)) } }
}
