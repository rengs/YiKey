import Foundation

public struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String               // 归一化后的英文，作为去重键
    public var english: String          // 首次加入时的展示文本
    public var chinese: String          // 首次的中文原文
    public var otherChinese: [String]   // 同一英文对应的其它中文原文
    public var firstAddedAt: Date
    public var lastPlayedAt: Date
    public var playCount: Int
}

public enum VocabularySort: Sendable { case lastPlayedDescending, alphabetical, playCountDescending }

public enum VocabularyKey {
    /// 去重键：合并空白、统一弯/直撇号、去掉首尾标点与空白、小写。 "Hello!" / " hello " / "HELLO" 视为同一条。
    public static func normalize(_ s: String) -> String {
        var strip = CharacterSet.whitespacesAndNewlines
        strip.insert(charactersIn: ".,!?;:\"'“”‘’…()[]{}")
        let unified = s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        let collapsed = unified.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: strip).lowercased()
    }
}

/// 单词本：内存字典 + 后台防抖落盘（JSON，原子写入）。
/// - recordPlay 只做内存更新并安排保存，调用方（pronounceTapped）不会等磁盘。
/// - 所有磁盘 IO 都发生在 actor 的后台执行器上，不会落到主线程。
/// - 文件损坏时不会覆盖：改名为 vocabulary.corrupt-<时间戳>.json 后从空表开始。
public actor VocabularyBook {
    private struct FileFormat: Codable { var version: Int; var entries: [VocabularyEntry] }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranslateIME/vocabulary.json")
    }

    public let fileURL: URL
    private let saveDelay: TimeInterval
    private let clock: @Sendable () -> Date
    private let monitor: LatencyMonitor?

    private var store: [String: VocabularyEntry] = [:]
    private var loaded = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    public private(set) var writeCount = 0
    public private(set) var lastError: String?

    public init(fileURL: URL = VocabularyBook.defaultFileURL, saveDelay: TimeInterval = 0.3,
                clock: @escaping @Sendable () -> Date = { Date() }, monitor: LatencyMonitor? = nil) {
        self.fileURL = fileURL; self.saveDelay = saveDelay; self.clock = clock; self.monitor = monitor
    }

    // MARK: 写入

    @discardableResult
    public func recordPlay(english: String, chinese: String) -> VocabularyEntry? {
        ensureLoaded()
        let key = VocabularyKey.normalize(english)
        guard !key.isEmpty else { return nil }
        let display = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let zh = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = clock()

        if var e = store[key] {
            e.playCount += 1
            e.lastPlayedAt = max(e.lastPlayedAt, now)
            if !zh.isEmpty, zh != e.chinese, !e.otherChinese.contains(zh) {
                if e.chinese.isEmpty { e.chinese = zh } else { e.otherChinese.append(zh) }
            }
            store[key] = e
            scheduleSave()
            return e
        }
        let e = VocabularyEntry(id: key, english: display, chinese: zh, otherChinese: [],
                                firstAddedAt: now, lastPlayedAt: now, playCount: 1)
        store[key] = e
        scheduleSave()
        return e
    }

    public func remove(id: String) { ensureLoaded(); if store.removeValue(forKey: id) != nil { scheduleSave() } }
    public func removeAll() { ensureLoaded(); if !store.isEmpty { store.removeAll(); scheduleSave() } }

    // MARK: 读取

    public func entries(sortedBy sort: VocabularySort = .lastPlayedDescending) -> [VocabularyEntry] {
        ensureLoaded()
        let all = Array(store.values)
        switch sort {
        case .lastPlayedDescending: return all.sorted { ($0.lastPlayedAt, $0.id) > ($1.lastPlayedAt, $1.id) }
        case .alphabetical:         return all.sorted { $0.id < $1.id }
        case .playCountDescending:  return all.sorted { ($0.playCount, $0.id) > ($1.playCount, $1.id) }
        }
    }

    // MARK: 持久化

    /// 立即落盘（测试、退出时使用）
    public func flush() {
        saveTask?.cancel(); saveTask = nil
        writeNow()
    }

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }       // 合并：窗口期内多次修改只写一次
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.saveTick()
        }
    }

    private func saveTick() { saveTask = nil; writeNow() }

    private func writeNow() {
        guard dirty else { return }
        let t0 = LatencyMonitor.now()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encodedFile().write(to: fileURL, options: .atomic)
            dirty = false; writeCount += 1; lastError = nil
        } catch {
            lastError = "\(error)"        // dirty 保持 true，下次修改会重试
        }
        monitor?.record(.vocabularyWrite, milliseconds: LatencyMonitor.ms(since: t0), note: "entries=\(store.count)")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let f = try Self.decoder().decode(FileFormat.self, from: data)
            for e in f.entries { store[e.id] = e }
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("vocabulary.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            lastError = "词库文件损坏，已备份为 \(backup.lastPathComponent)"
        }
    }

    private func encodedFile() throws -> Data {
        let sorted = store.values.sorted { ($0.firstAddedAt, $0.id) < ($1.firstAddedAt, $1.id) }
        return try Self.encoder().encode(FileFormat(version: 1, entries: sorted))
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    // MARK: 导出

    public func exportJSON(to url: URL) throws {
        ensureLoaded()
        try encodedFile().write(to: url, options: .atomic)
    }

    public func exportCSV(to url: URL) throws {
        var data = Data([0xEF, 0xBB, 0xBF])          // UTF-8 BOM：Excel 正确识别中文
        data.append(Data(csvString().utf8))
        try data.write(to: url, options: .atomic)
    }

    public func csvString() -> String {
        ensureLoaded()
        let iso = ISO8601DateFormatter()
        var lines = ["english,chinese,other_chinese,play_count,first_added,last_played"]
        for e in entries(sortedBy: .lastPlayedDescending) {
            let cols = [e.english, e.chinese, e.otherChinese.joined(separator: " | "), String(e.playCount),
                        iso.string(from: e.firstAddedAt), iso.string(from: e.lastPlayedAt)]
            lines.append(cols.map(Self.csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func csvEscape(_ raw: String) -> String {
        var s = raw
        if let f = s.first, "=+-@\t\r".contains(f) { s = "'" + s }      // 防 CSV 公式注入
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
