import Foundation
import os

public enum LatencyMetric: String, CaseIterable, Sendable {
    case keyHandling      // IMK handle() 全程（主线程；预算 5ms）
    case clientIPC        // handle() 内对宿主应用的调用（setMarkedText / 取光标位置）
    case panelUpdate      // 浮窗布局一次
    case keyToPanel       // 按键 → 候选浮窗状态更新
    case translation      // 最后一次输入 → 译文就绪（含防抖，用户感知）
    case providerCall     // 单次翻译服务调用（后台）
    case vocabularyWrite  // 单词本落盘（后台）
    case clipboardPoll    // 剪贴板变化后的一次判定（读类型+文本+过滤；未变化的轮询不记录）
}

public struct LatencyStats: Equatable, Sendable {
    public let count: Int          // 累计记录数
    public let mean: Double        // 以下统计基于最近 capacity 条（ms）
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let max: Double
    public let overBudget: Int     // 累计超预算次数
}

public protocol LatencySink: Sendable {
    func slow(metric: LatencyMetric, milliseconds: Double, budget: Double, note: String?)
    func sample(metric: LatencyMetric, milliseconds: Double, note: String?)
    func summary(_ text: String)
}
public extension LatencySink {
    func sample(metric: LatencyMetric, milliseconds: Double, note: String?) {}
}

/// 线程安全的延迟统计。record() 只做一次加锁 + 环形缓冲写入（亚微秒级），可放心在按键路径调用。
/// 注意：note 里只能放长度、provider 名等元数据，**不要放用户输入的文字**。
public final class LatencyMonitor: @unchecked Sendable {
    public static let defaultBudgets: [LatencyMetric: Double] = [
        .keyHandling: 5, .clientIPC: 3, .panelUpdate: 8, .keyToPanel: 50, .vocabularyWrite: 100, .clipboardPoll: 3,
    ]
    public static let shared = LatencyMonitor()

    private struct Ring {
        var values: [Double]
        var next = 0, filled = 0, total = 0, over = 0
        init(capacity: Int) { values = Array(repeating: 0, count: capacity) }
        mutating func add(_ v: Double, over breached: Bool) {
            values[next] = v
            next = (next + 1) % values.count
            filled = min(filled + 1, values.count)
            total += 1
            if breached { over += 1 }
        }
    }

    private let lock = NSLock()
    private var rings: [LatencyMetric: Ring] = [:]
    private var sinks: [LatencySink]
    private let budgets: [LatencyMetric: Double]
    private let summaryEvery: Int
    private var _verbose = false

    public init(capacity: Int = 1024,
                budgets: [LatencyMetric: Double] = LatencyMonitor.defaultBudgets,
                sinks: [LatencySink] = [],
                summaryEvery: Int = 500) {
        self.budgets = budgets
        self.sinks = sinks
        self.summaryEvery = max(1, summaryEvery)
        for m in LatencyMetric.allCases { rings[m] = Ring(capacity: max(1, capacity)) }
    }

    public var verbose: Bool {
        get { lock.withLock { _verbose } }
        set { lock.withLock { _verbose = newValue } }
    }

    public func addSink(_ sink: LatencySink) { lock.withLock { sinks.append(sink) } }

    @inline(__always) public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func ms(since start: UInt64) -> Double { Double(now() &- start) / 1_000_000 }

    public func record(_ metric: LatencyMetric, milliseconds ms: Double, note: String? = nil) {
        let budget = budgets[metric]
        let breached = budget.map { ms > $0 } ?? false
        var targets: [LatencySink] = []
        var verbose = false
        var needSummary = false

        lock.lock()
        rings[metric]?.add(ms, over: breached)
        if breached || _verbose || metric == .keyHandling { targets = sinks; verbose = _verbose }
        if metric == .keyHandling, let t = rings[metric]?.total, t % summaryEvery == 0 { needSummary = true }
        lock.unlock()

        for s in targets {
            if breached, let budget { s.slow(metric: metric, milliseconds: ms, budget: budget, note: note) }
            else if verbose { s.sample(metric: metric, milliseconds: ms, note: note) }
        }
        if needSummary {
            let text = report()
            for s in targets { s.summary(text) }
        }
    }

    @discardableResult
    public func measure<T>(_ metric: LatencyMetric, note: String? = nil, _ body: () throws -> T) rethrows -> T {
        let t0 = Self.now()
        defer { record(metric, milliseconds: Self.ms(since: t0), note: note) }
        return try body()
    }

    public func stats(_ metric: LatencyMetric) -> LatencyStats {
        let ring = lock.withLock { rings[metric] }
        guard let ring, ring.filled > 0 else {
            return LatencyStats(count: ring?.total ?? 0, mean: 0, p50: 0, p95: 0, p99: 0, max: 0, overBudget: ring?.over ?? 0)
        }
        let sorted = ring.values[0..<ring.filled].sorted()
        func pct(_ p: Double) -> Double {
            let idx = Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[idx]
        }
        return LatencyStats(count: ring.total, mean: sorted.reduce(0, +) / Double(sorted.count),
                            p50: pct(0.50), p95: pct(0.95), p99: pct(0.99),
                            max: sorted.last ?? 0, overBudget: ring.over)
    }

    public func report() -> String {
        var lines = ["metric            count    mean     p50     p95     p99     max  over-budget"]
        for m in LatencyMetric.allCases {
            let s = stats(m)
            guard s.count > 0 else { continue }
            func f(_ v: Double) -> String { String(format: "%7.2f", v) }
            lines.append(m.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
                         + String(format: "%7d", s.count) + f(s.mean) + f(s.p50) + f(s.p95) + f(s.p99) + f(s.max)
                         + String(format: "  %d", s.overBudget))
        }
        return lines.joined(separator: "\n")
    }

    public func reset() {
        lock.withLock {
            let cap = rings.values.first?.values.count ?? 1024
            for m in LatencyMetric.allCases { rings[m] = Ring(capacity: cap) }
        }
    }
}

// MARK: - Sinks

/// 统一日志：log stream --predicate 'subsystem == "com.example.inputmethod.TranslateIME" && category == "latency"' --level debug
public struct OSLogLatencySink: LatencySink {
    private let logger = Logger(subsystem: "com.example.inputmethod.TranslateIME", category: "latency")
    public init() {}
    public func slow(metric: LatencyMetric, milliseconds: Double, budget: Double, note: String?) {
        logger.warning("SLOW \(metric.rawValue, privacy: .public) \(milliseconds, format: .fixed(precision: 2)) ms > budget \(budget, format: .fixed(precision: 1)) ms \(note ?? "", privacy: .public)")
    }
    public func sample(metric: LatencyMetric, milliseconds: Double, note: String?) {
        logger.debug("\(metric.rawValue, privacy: .public) \(milliseconds, format: .fixed(precision: 2)) ms \(note ?? "", privacy: .public)")
    }
    public func summary(_ text: String) { logger.info("\(text, privacy: .public)") }
}

/// 文件日志（~/Library/Logs/TranslateIME/latency.log）：写入在后台串行队列，调用方只付出一次 async 入队的代价。
public final class FileLatencySink: LatencySink, @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TranslateIME/latency.log")
    }
    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "TranslateIME.latency.file", qos: .utility)
    private var handle: FileHandle?
    private var bytes = 0

    public init(url: URL = FileLatencySink.defaultURL, maxBytes: Int = 1_000_000) {
        self.url = url; self.maxBytes = maxBytes
    }

    public func slow(metric: LatencyMetric, milliseconds: Double, budget: Double, note: String?) {
        append(String(format: "SLOW %@ %.2fms > %.1fms %@", metric.rawValue, milliseconds, budget, note ?? ""))
    }
    public func sample(metric: LatencyMetric, milliseconds: Double, note: String?) {
        append(String(format: "     %@ %.2fms %@", metric.rawValue, milliseconds, note ?? ""))
    }
    public func summary(_ text: String) { append("SUMMARY\n" + text) }

    private func append(_ s: String) {
        let date = Date()
        queue.async { [self] in
            let stamp = ISO8601DateFormatter().string(from: date)
            write(Data("\(stamp) \(s)\n".utf8))
        }
    }

    private func write(_ data: Data) {
        do {
            if handle == nil {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try FileHandle(forWritingTo: url)
                bytes = Int(try handle?.seekToEnd() ?? 0)
            }
            if bytes > maxBytes {
                try? handle?.close(); handle = nil
                let old = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try FileHandle(forWritingTo: url); bytes = 0
            }
            try handle?.write(contentsOf: data)
            bytes += data.count
        } catch { handle = nil }
    }
}
