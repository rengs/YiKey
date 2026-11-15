import Foundation

// MARK: - 术语表数据模型

public enum GlossaryDomain: String, CaseIterable, Sendable, Codable {
    case petroleum, ai, software, instrument, embedded, user

    public static let builtIn: [GlossaryDomain] = [.petroleum, .ai, .software, .instrument, .embedded]

    public var title: String {
        switch self {
        case .petroleum: return "石油工程（采油·注水·地面集输）"
        case .ai: return "人工智能"
        case .software: return "计算机 / 软件"
        case .instrument: return "仪器仪表与传感器"
        case .embedded: return "单片机 / 嵌入式硬件"
        case .user: return "我的词表"
        }
    }
    /// 资源文件名（Contents/Resources/Glossaries/<name>.csv）
    public var resourceName: String { "glossary-\(rawValue)" }
    /// 菜单开关的 UserDefaults 键（未设置 = 开）
    public var settingsKey: String { "glossaryDomain.\(rawValue)" }
    /// 同一个词在多个内置词表里时的优先级（越小越优先）；用户词表永远最优先
    var priority: Int {
        switch self {
        case .user: return 0
        case .petroleum: return 1
        case .instrument: return 2
        case .embedded: return 3
        case .software: return 4
        case .ai: return 5
        }
    }
}

public struct GlossaryFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 只用于 中→英（英文是普通词，英→中时不匹配，避免误伤）
    public static let zhToEnOnly = GlossaryFlags(rawValue: 1)
    /// 只用于 英→中
    public static let enToZhOnly = GlossaryFlags(rawValue: 2)
    /// 英→中时把英文缩写也译成中文（默认缩写原样保留，如 MCU、RAG）
    public static let expandAcronym = GlossaryFlags(rawValue: 4)

    public static func parse(_ s: String) -> GlossaryFlags {
        var f: GlossaryFlags = []
        for t in s.lowercased().split(whereSeparator: { $0 == " " || $0 == "|" || $0 == ";" }) {
            switch t {
            case "z2e": f.insert(.zhToEnOnly)
            case "e2z": f.insert(.enToZhOnly)
            case "x": f.insert(.expandAcronym)
            default: break
            }
        }
        return f
    }
}

public struct GlossaryEntry: Equatable, Sendable {
    /// 第一个是标准中文，其余是同义写法（都映射到标准英文）
    public var zh: [String]
    /// 第一个是标准英文，其余是同义写法/缩写（都映射到标准中文）
    public var en: [String]
    public var domain: GlossaryDomain
    public var domainLabel: String
    public var note: String
    public var flags: GlossaryFlags

    public init(zh: [String], en: [String], domain: GlossaryDomain, domainLabel: String = "",
                note: String = "", flags: GlossaryFlags = []) {
        self.zh = zh.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.en = en.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.domain = domain; self.domainLabel = domainLabel; self.note = note; self.flags = flags
    }

    public var canonicalZH: String? { zh.first }
    public var canonicalEN: String? { en.first }

    static func splitVariants(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "|" || $0 == "｜" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - 内置词表 CSV：zh,en,zh_alt,en_alt,flags,note（同义写法用 | 分隔）

public enum BuiltInGlossary {
    public static let header = ["zh", "en", "zh_alt", "en_alt", "flags", "note"]

    public static func parse(_ text: String, domain: GlossaryDomain) -> [GlossaryEntry] {
        var out: [GlossaryEntry] = []
        for (i, row) in DelimitedText.parse(text, delimiter: ",").enumerated() {
            if i == 0, row.first?.lowercased() == "zh" { continue }
            guard row.count >= 2, !row[0].hasPrefix("#") else { continue }
            func col(_ k: Int) -> String { k < row.count ? row[k] : "" }
            let e = GlossaryEntry(zh: [row[0]] + GlossaryEntry.splitVariants(col(2)),
                                  en: [row[1]] + GlossaryEntry.splitVariants(col(3)),
                                  domain: domain, domainLabel: domain.title, note: col(5),
                                  flags: GlossaryFlags.parse(col(4)))
            if !e.zh.isEmpty && !e.en.isEmpty { out.append(e) }
        }
        return out
    }

    /// 从目录加载五套内置词表（App 里是 Contents/Resources/Glossaries）
    public static func load(from directory: URL) -> [GlossaryDomain: [GlossaryEntry]] {
        var all: [GlossaryDomain: [GlossaryEntry]] = [:]
        for d in GlossaryDomain.builtIn {
            let url = directory.appendingPathComponent(d.resourceName + ".csv")
            if let text = try? String(contentsOf: url, encoding: .utf8) { all[d] = parse(text, domain: d) }
        }
        return all
    }
}

// MARK: - 用户词表：~/Library/Application Support/TranslateIME/glossary.csv（中文,英文,领域,备注；UTF-8 BOM）

public struct UserGlossaryRow: Equatable, Sendable {
    public var zh: String
    public var en: String
    public var domain: String
    public var note: String
    public init(zh: String, en: String, domain: String = "", note: String = "") {
        self.zh = zh.trimmingCharacters(in: .whitespacesAndNewlines)
        self.en = en.trimmingCharacters(in: .whitespacesAndNewlines)
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var entry: GlossaryEntry {
        GlossaryEntry(zh: GlossaryEntry.splitVariants(zh), en: GlossaryEntry.splitVariants(en),
                      domain: .user, domainLabel: domain, note: note)
    }
    var isExample: Bool { note.hasPrefix("示例") }
}

public enum UserGlossaryFile {
    public static let header = ["中文", "英文", "领域", "备注"]
    public static let exampleRows: [UserGlossaryRow] = [
        UserGlossaryRow(zh: "功图量油", en: "dynamometer-card-based production metering", domain: "石油工程",
                        note: "示例：可修改或删除。多个写法用 | 分隔，例如 中文写 功图计产|功图量油"),
        UserGlossaryRow(zh: "井场RTU", en: "wellsite RTU", domain: "仪器仪表", note: "示例：可修改或删除"),
    ]

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TranslateIME/glossary.csv")
    }

    /// 不存在时创建表头 + 示例；返回是否新建
    @discardableResult
    public static func ensureTemplate(at url: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(exampleRows, to: url)
        return true
    }

    /// 解析表格行：识别表头（中文/英文/领域/备注 或 zh/en/domain/note），没有表头时按前两列 = 中文,英文
    public static func rows(from table: [[String]]) -> [UserGlossaryRow] {
        guard let first = table.first else { return [] }
        let names = first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func find(_ keys: [String]) -> Int? { names.firstIndex { n in keys.contains { n == $0 || n.hasPrefix($0) } } }
        let zhCol = find(["中文", "zh", "chinese", "汉语", "术语"])
        let enCol = find(["英文", "en", "english", "译文"])
        let hasHeader = zhCol != nil && enCol != nil
        let zi = zhCol ?? 0, ei = enCol ?? 1
        let di = hasHeader ? find(["领域", "domain", "分类", "类别"]) : (first.count > 2 ? 2 : nil)
        let ni = hasHeader ? find(["备注", "note", "说明", "注释"]) : (first.count > 3 ? 3 : nil)
        var out: [UserGlossaryRow] = []
        for (i, r) in table.enumerated() {
            if hasHeader && i == 0 { continue }
            func col(_ k: Int?) -> String { guard let k, k < r.count else { return "" }; return r[k] }
            let row = UserGlossaryRow(zh: col(zi), en: col(ei), domain: col(di), note: col(ni))
            if row.zh.hasPrefix("#") || row.zh.isEmpty || row.en.isEmpty { continue }
            out.append(row)
        }
        return out
    }

    public static func load(_ url: URL) -> [UserGlossaryRow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return rows(from: DelimitedText.parse(text))
    }

    public static func write(_ rows: [UserGlossaryRow], to url: URL) throws {
        let table = [header] + rows.map { [$0.zh, $0.en, $0.domain, $0.note] }
        try DelimitedText.format(table).write(to: url, atomically: true, encoding: .utf8)
    }

    /// 纠正译法：source 可以是中文或英文；按中文（或英文）找到已有行就更新，否则追加
    @discardableResult
    public static func upsertCorrection(source: String, translation: String, at url: URL,
                                        domain: String = "纠正", date: Date = Date()) throws -> UserGlossaryRow {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIsChinese = LanguageDetector.detect(s) == .chinese
            || (LanguageDetector.detect(s) == .unknown && s.unicodeScalars.contains { LanguageDetector.isHan($0) })
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let row = UserGlossaryRow(zh: sourceIsChinese ? s : t, en: sourceIsChinese ? t : s,
                                  domain: domain, note: "纠正译法 \(f.string(from: date))")
        try merge([row], into: url, matchOn: sourceIsChinese ? .zh : .en)
        return row
    }

    public enum MatchKey { case zh, en }

    /// 合并（导入 / 纠正）：同一中文（或英文）的行被新行替换，其余追加。返回 (新增, 更新)
    @discardableResult
    public static func merge(_ new: [UserGlossaryRow], into url: URL, matchOn: MatchKey = .zh) throws -> (added: Int, updated: Int) {
        try ensureTemplate(at: url)
        var rows = load(url)
        var added = 0, updated = 0
        for n in new {
            func key(_ r: UserGlossaryRow) -> String {
                (matchOn == .zh ? GlossaryEntry.splitVariants(r.zh).first : GlossaryEntry.splitVariants(r.en).first?.lowercased()) ?? ""
            }
            if let i = rows.firstIndex(where: { key($0) == key(n) && !key(n).isEmpty }) { rows[i] = n; updated += 1 }
            else { rows.append(n); added += 1 }
        }
        try write(rows, to: url)
        return (added, updated)
    }
}
