#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
@testable import IMECore

final class LatencyMonitorTests: XCTestCase {
    func testPercentiles() {
        let m = LatencyMonitor(capacity: 1024)
        for i in 1...100 { m.record(.translation, milliseconds: Double(i)) }
        let s = m.stats(.translation)
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.p50, 50); XCTAssertEqual(s.p95, 95); XCTAssertEqual(s.p99, 99); XCTAssertEqual(s.max, 100)
        XCTAssertEqual(s.mean, 50.5, accuracy: 0.001)
    }

    func testRingKeepsOnlyRecentWindowButCountsAll() {
        let m = LatencyMonitor(capacity: 10)
        for i in 1...100 { m.record(.translation, milliseconds: Double(i)) }
        let s = m.stats(.translation)
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.max, 100)
        XCTAssertGreaterThanOrEqual(s.p50, 91)       // 只统计最近 10 条：91...100
    }

    func testBudgetBreachNotifiesSinkAndCounts() {
        let sink = MockSink()
        let m = LatencyMonitor(budgets: [.keyHandling: 5], sinks: [sink])
        m.record(.keyHandling, milliseconds: 1)
        m.record(.keyHandling, milliseconds: 5)        // 恰好等于预算：不算超
        m.record(.keyHandling, milliseconds: 5.01)
        XCTAssertEqual(sink.slow.count, 1)
        XCTAssertEqual(sink.slow.first?.0, .keyHandling)
        XCTAssertEqual(m.stats(.keyHandling).overBudget, 1)
    }

    func testMetricWithoutBudgetNeverFlagged() {
        let sink = MockSink()
        let m = LatencyMonitor(sinks: [sink])
        m.record(.translation, milliseconds: 99_999)
        XCTAssertTrue(sink.slow.isEmpty)
    }

    func testPeriodicSummary() {
        let sink = MockSink()
        let m = LatencyMonitor(sinks: [sink], summaryEvery: 10)
        for _ in 0..<25 { m.record(.keyHandling, milliseconds: 0.1) }
        XCTAssertEqual(sink.summaries, 2)
    }

    func testMeasureReturnsValueAndRecords() {
        let m = LatencyMonitor()
        let v = m.measure(.panelUpdate) { 42 }
        XCTAssertEqual(v, 42)
        XCTAssertEqual(m.stats(.panelUpdate).count, 1)
        XCTAssertTrue(m.report().contains("panelUpdate"))
    }

    func testRecordIsThreadSafe() async {
        let m = LatencyMonitor()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { for _ in 0..<1000 { m.record(.providerCall, milliseconds: 1) } } }
        }
        XCTAssertEqual(m.stats(.providerCall).count, 8000)
    }

    func testDebounceSettingIsClamped() {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        XCTAssertEqual(IMESettings.debounce(defaults: d), 0.2, accuracy: 1e-9)
        d.set(50, forKey: IMESettings.debounceMs);  XCTAssertEqual(IMESettings.debounce(defaults: d), 0.15, accuracy: 1e-9)
        d.set(900, forKey: IMESettings.debounceMs); XCTAssertEqual(IMESettings.debounce(defaults: d), 0.30, accuracy: 1e-9)
        d.set(250, forKey: IMESettings.debounceMs); XCTAssertEqual(IMESettings.debounce(defaults: d), 0.25, accuracy: 1e-9)
    }
}
