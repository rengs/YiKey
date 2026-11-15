#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
@testable import IMECore

/// 性能与“不被翻译阻塞”的验证。
/// 说明：这里测的是按键路径上**我们自己的同步逻辑**（状态机 + coordinator.update）。
/// 对宿主应用的 IPC（setMarkedText）与 SwiftUI 布局无法在单测里复现，运行时由 LatencyMonitor 的
/// keyHandling / clientIPC / panelUpdate 指标记录，见 README 的实测方法。
@MainActor
final class PerformanceTests: XCTestCase {

    private func coordinator(_ provider: MockProvider, debounce: TimeInterval = 0.2,
                             monitor: LatencyMonitor = LatencyMonitor()) -> TranslationCoordinator {
        TranslationCoordinator(service: TranslationService(providers: [provider]),
                               speaker: MockSpeaker(), debounce: debounce, monitor: monitor)
    }

    // MARK: 按键路径 < 5ms，即使 provider 很慢 / 把线程卡死

    private func typeAndMeasure(_ c: TranslationCoordinator, chars: Int) async throws -> LatencyStats {
        let m = LatencyMonitor()
        var buf = CompositionBuffer()
        let text = String(repeating: "hello world ", count: chars / 12 + 1).prefix(chars)
        for ch in text {
            m.measure(.keyHandling) {
                _ = buf.handle(.character(String(ch)))
                c.update(text: buf.text)
            }
            try await Task.sleep(nanoseconds: 2_000_000)      // 让后台任务有机会运行，证明它们不会反过来拖住主线程
        }
        print("keyHandling:\n" + m.report())
        return m.stats(.keyHandling)
    }

    func testKeystrokeUnder5msWithSlowAsyncProvider() async throws {
        let slow = MockProvider(id: "slow") { _, _, _ in try await Task.sleep(nanoseconds: 300_000_000); return "x" }
        let s = try await typeAndMeasure(coordinator(slow), chars: 240)
        XCTAssertLessThan(s.p95, 5.0, "p95 应 < 5ms")
        XCTAssertLessThan(s.p99, 5.0, "p99 应 < 5ms")
        XCTAssertLessThan(s.max, 25.0, "偶发抖动上限")
    }

    func testKeystrokeUnder5msWithThreadBlockingProvider() async throws {
        let blocking = MockProvider(id: "blocking") { _, _, _ in Thread.sleep(forTimeInterval: 0.3); return "x" }
        let s = try await typeAndMeasure(coordinator(blocking, debounce: 0.05), chars: 120)
        XCTAssertLessThan(s.p95, 5.0)
        XCTAssertLessThan(s.max, 25.0)
    }

    // MARK: 防抖 / 取消 / 过期丢弃

    func testDebounceCollapsesBurstIntoSingleCall() async throws {
        let p = MockProvider(id: "p") { t, _, _ in "T:" + t }
        let c = coordinator(p, debounce: 0.1)
        var text = ""
        for ch in "你好世界今天天气不错" {
            text.append(ch); c.update(text: text)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await c.settle()
        XCTAssertEqual(p.calls.count, 1, "连续输入只应触发一次翻译")
        XCTAssertEqual(p.calls.first?.text, "你好世界今天天气不错")
        XCTAssertEqual(c.result?.original, "你好世界今天天气不错")
    }

    func testStaleResultNeverOverwritesNewer() async throws {
        let p = MockProvider(id: "p") { t, _, _ in
            if t == "你好" { try await Task.sleep(nanoseconds: 200_000_000); return "Hello" }
            return "Thanks"
        }
        let c = coordinator(p, debounce: 0)
        c.update(text: "你好")
        try await Task.sleep(nanoseconds: 50_000_000)        // 慢请求已在途
        c.update(text: "谢谢")
        await c.settle()
        XCTAssertEqual(c.result?.original, "谢谢")
        try await Task.sleep(nanoseconds: 350_000_000)        // 等慢请求“本该返回”的时间
        XCTAssertEqual(c.result?.original, "谢谢", "旧结果不得覆盖新结果")
        XCTAssertEqual(c.result?.translated, "Thanks")
    }

    func testCancelledRequestIsNotPublishedAfterReset() async throws {
        let p = MockProvider(id: "p") { _, _, _ in try await Task.sleep(nanoseconds: 100_000_000); return "x" }
        let c = coordinator(p, debounce: 0)
        c.update(text: "你好")
        try await Task.sleep(nanoseconds: 20_000_000)
        c.reset()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(c.phase, .idle)
    }

    // MARK: 缓存

    func testCacheHitIsSynchronousAndSkipsProvider() async throws {
        let p = MockProvider(id: "p") { _, _, _ in "Hello" }
        let c = coordinator(p, debounce: 0.2)
        c.update(text: "你好"); await c.settle()
        XCTAssertEqual(p.calls.count, 1)

        c.reset()
        let t0 = LatencyMonitor.now()
        c.update(text: "你好")
        let ms = LatencyMonitor.ms(since: t0)
        XCTAssertEqual(c.result?.translated, "Hello", "命中缓存应同步 ready，不经过防抖")
        XCTAssertLessThan(ms, 5.0)
        XCTAssertEqual(p.calls.count, 1)
    }

    func testTranslationCacheLRUEvictsOldest() {
        let cache = TranslationCache(capacity: 10)
        func r(_ s: String) -> TranslationResult {
            TranslationResult(original: s, translated: s, source: .english, target: .chinese, providerID: "t")
        }
        for i in 0..<10 { cache.insert(r("k\(i)")) }
        _ = cache.lookup("k0")                         // k0 变“新”
        for i in 10..<14 { cache.insert(r("k\(i)")) }  // 触发淘汰
        XCTAssertLessThanOrEqual(cache.count, 10)
        XCTAssertNotNil(cache.lookup("k0"), "最近使用过的应保留")
        XCTAssertNil(cache.lookup("k1"), "最久未用的应被淘汰")
    }

    func testCacheLookupIsFast() {
        let cache = TranslationCache(capacity: 500)
        for i in 0..<500 {
            cache.insert(TranslationResult(original: "word \(i)", translated: "词 \(i)", source: .english, target: .chinese, providerID: "t"))
        }
        let t0 = LatencyMonitor.now()
        for i in 0..<10_000 { _ = cache.lookup("word \(i % 500)") }
        let perLookupUs = LatencyMonitor.ms(since: t0) * 1000 / 10_000
        print("cache lookup: \(perLookupUs) µs")
        XCTAssertLessThan(perLookupUs, 50)
    }

    // MARK: 微基准

    func testCompositionBufferThroughput() {
        measure {
            var b = CompositionBuffer()
            for _ in 0..<10_000 { _ = b.handle(.character("a")) }
        }
        let t0 = LatencyMonitor.now()
        var b = CompositionBuffer()
        for _ in 0..<10_000 { _ = b.handle(.character("a")) }
        XCTAssertLessThan(LatencyMonitor.ms(since: t0), 100, "10k 次按键状态机 < 100ms（均摊 < 10µs/次）")
    }

    func testLanguageDetectorOnLongTextIsFast() {
        let text = String(repeating: "Hello 你好 world 世界 ", count: 100)    // ~1500 字符
        let t0 = LatencyMonitor.now()
        for _ in 0..<100 { _ = LanguageDetector.detect(text) }
        let perCallMs = LatencyMonitor.ms(since: t0) / 100
        print("detect: \(perCallMs) ms")
        XCTAssertLessThan(perCallMs, 2.0)
    }
}
