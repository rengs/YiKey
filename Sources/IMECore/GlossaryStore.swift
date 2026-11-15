import Foundation

/// 当前生效的术语表：内置五套（可分别开关）+ 用户词表（优先）。线程安全；重建索引在调用方的后台线程做。
public final class GlossaryStore: TermProtecting, @unchecked Sendable {
    private let lock = NSLock()
    private var builtIns: [GlossaryDomain: [GlossaryEntry]] = [:]
    private var user: [GlossaryEntry] = []
    private var enabled: Set<GlossaryDomain>
    private var index = GlossaryIndex(entries: [])
    private var masterOn = true
    public private(set) var revision = 0
    /// 索引变化（重新加载 / 开关 / 纠正）后调用：用来清空译文缓存
    public var onChange: (@Sendable () -> Void)?

    public init(builtIns: [GlossaryDomain: [GlossaryEntry]] = [:], user: [GlossaryEntry] = [],
                enabled: Set<GlossaryDomain> = Set(GlossaryDomain.builtIn)) {
        self.builtIns = builtIns
        self.user = user
        self.enabled = enabled
        rebuild()
    }

    public func setBuiltIns(_ b: [GlossaryDomain: [GlossaryEntry]]) { lock.withLock { builtIns = b }; rebuild() }
    public func setUser(_ u: [GlossaryEntry]) { lock.withLock { user = u }; rebuild() }
    public func setEnabled(_ d: GlossaryDomain, _ on: Bool) {
        lock.withLock { if on { enabled.insert(d) } else { enabled.remove(d) } }
        rebuild()
    }
    public func setMaster(_ on: Bool) { lock.withLock { masterOn = on }; onChange?() }
    public var isMasterOn: Bool { lock.withLock { masterOn } }
    public func isEnabled(_ d: GlossaryDomain) -> Bool { lock.withLock { enabled.contains(d) } }

    public func count(_ d: GlossaryDomain) -> Int {
        lock.withLock { d == .user ? user.count : (builtIns[d]?.count ?? 0) }
    }

    public var currentIndex: GlossaryIndex { lock.withLock { index } }

    private func rebuild() {
        let (b, u, en) = lock.withLock { (builtIns, user, enabled) }
        // 用户词表在前（同键时优先级最高）
        var entries = u
        for d in GlossaryDomain.builtIn where en.contains(d) { entries += b[d] ?? [] }
        let idx = GlossaryIndex(entries: entries)
        lock.withLock { index = idx; revision += 1 }
        onChange?()
    }

    public func matches(in text: String, from: TextLanguage) -> [GlossaryMatch] {
        let (idx, on) = lock.withLock { (index, masterOn) }
        return on ? idx.matches(in: text, from: from) : []
    }

    public func plan(for text: String, from: TextLanguage) -> TermPlan? {
        let ms = matches(in: text, from: from)
        return ms.isEmpty ? nil : TermPlan(original: text, from: from, matches: ms)
    }
}
