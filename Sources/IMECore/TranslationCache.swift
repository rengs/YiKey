import Foundation

/// 线程安全 LRU 译文缓存。键 = 裁剪后的原文（翻译方向由语言判别唯一确定）。
/// 单次 lookup 为一次加锁 + 哈希查询（微秒级），主线程可同步命中，不需要任何 await。
public final class TranslationCache: @unchecked Sendable {
    private struct Entry { var result: TranslationResult; var tick: UInt64 }
    private let lock = NSLock()
    private var store: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 500) { self.capacity = max(1, capacity) }

    public var count: Int { lock.withLock { store.count } }

    public func lookup(_ text: String) -> TranslationResult? {
        lock.withLock {
            guard var e = store[text] else { return nil }
            tick &+= 1; e.tick = tick; store[text] = e
            return e.result
        }
    }

    public func insert(_ result: TranslationResult) {
        lock.withLock {
            tick &+= 1
            store[result.original] = Entry(result: result, tick: tick)
            if store.count > capacity {
                // 淘汰最久未使用的 20%
                let drop = Swift.max(1, capacity / 5)
                for (k, _) in store.sorted(by: { $0.value.tick < $1.value.tick }).prefix(drop) { store[k] = nil }
            }
        }
    }

    public func removeAll() { lock.withLock { store.removeAll() } }
}
