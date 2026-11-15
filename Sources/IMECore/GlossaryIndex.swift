import Foundation

// MARK: - 术语匹配索引
//
// 中文：按 Unicode 标量建字典树，从左到右“最长匹配优先”（正向最大匹配），一次扫描 O(n·最大词长)。
// 英文：先切词（字母/数字为词，空格、连字符、斜杠、标点都是分隔），每个词转小写并做简单单复数归一
//      （pumps→pump、batteries→battery、processes→process），按“词序列”建字典树 → 天然整词匹配、支持多词术语。
//      全大写缩写（CAN、ESP、RAG、I2C）区分大小写，避免把普通单词 can 当成 CAN 总线；ESPs/MCUs 视为复数。

public struct GlossaryMatch: Equatable, Sendable {
    /// 在原文 unicodeScalars 中的范围
    public let range: Range<Int>
    public let source: String
    /// 要换上的目标术语
    public let target: String
    /// 英→中时缩写原样保留（target == source）
    public let keep: Bool
    public let domain: GlossaryDomain
}

public enum GlossaryStoplist {
    /// 过于宽泛、不应作为术语替换的中文（内置词表里出现也跳过；用户词表不受限制）
    public static let zh: Set<String> = Set([
        "系统", "数据", "设备", "参数", "模型", "网络", "接口", "信号", "压力", "温度", "流量", "时间", "功率",
        "电压", "电流", "管理", "控制", "监测", "测试", "运行", "分析", "平台", "模块", "单元", "节点", "问题",
        "情况", "工作", "生产", "技术", "方法", "结果", "处理", "井", "泵", "油", "气", "水", "站",
    ])
    /// 单独出现时有歧义的英文单词（英→中不替换；多词术语里出现没关系）
    public static let en: Set<String> = Set([
        "well", "pump", "agent", "model", "head", "string", "card", "lock", "rod", "line", "field", "cell",
        "stage", "bit", "core", "tree", "log", "shoe", "pig", "kick", "trip", "mud", "plant", "station", "unit",
        "layer", "token", "port", "bus", "driver", "node", "thread", "process", "register", "interrupt", "flow",
        "pressure", "temperature", "level", "rate", "head", "drift", "span", "range", "zero", "gain", "noise",
        "data", "system", "network", "service", "server", "client", "board", "chip", "pin", "clock", "timer",
        "memory", "storage", "cloud", "edge", "gateway", "protocol", "frame", "packet", "attention", "inference",
        "training", "learning", "feature", "label", "loss", "weight", "bias", "prompt", "context", "pipeline",
        "tank", "valve", "meter", "gauge", "sensor", "probe", "screen", "cement", "pay", "net", "gross",
        "cut", "skin", "trap", "seal", "cap", "plug", "test",
    ])
}

public final class GlossaryIndex: @unchecked Sendable {
    struct Payload {
        let target: String
        let keep: Bool
        let priority: Int
        let domain: GlossaryDomain
        /// 需要区分大小写的词（缩写）：(相对词序号, 原样写法)
        let exact: [(Int, String)]
    }

    // 中文字典树
    private var zhChildren: [[UInt32: Int]] = [[:]]
    private var zhPayload: [Payload?] = [nil]
    // 英文字典树（按归一化后的词）
    private var enChildren: [[String: Int]] = [[:]]
    private var enPayload: [[Payload]] = [[]]
    public private(set) var zhKeyCount = 0
    public private(set) var enKeyCount = 0
    public private(set) var skipped: [String] = []

    public init(entries: [GlossaryEntry]) {
        for e in entries { add(e) }
    }

    // MARK: 构建

    private func add(_ e: GlossaryEntry) {
        let isUser = e.domain == .user
        let p = e.domain.priority
        if !e.flags.contains(.enToZhOnly), let en = e.canonicalEN {
            for z in e.zh {
                if !isUser && (z.count < 2 || GlossaryStoplist.zh.contains(z)) { skipped.append(z); continue }
                insertZH(z, Payload(target: en, keep: false, priority: p, domain: e.domain, exact: []))
            }
        }
        if !e.flags.contains(.zhToEnOnly), let zh = e.canonicalZH {
            for form in e.en {
                let toks = Self.tokenize(form)
                guard !toks.isEmpty else { continue }
                let letters = form.unicodeScalars.filter { LanguageDetector.isLatinLetter($0) }.count
                if toks.count == 1 && (toks[0].text.count < 2 || letters < 2) { skipped.append(form); continue }
                let acronym = toks.count == 1 && toks[0].isAcronym || toks.allSatisfy { $0.isAcronym || $0.isNumber }
                    && toks.contains { $0.isAcronym }
                if !isUser && toks.count == 1 && !toks[0].isAcronym && GlossaryStoplist.en.contains(toks[0].norm) {
                    skipped.append(form); continue
                }
                let keep = acronym && !e.flags.contains(.expandAcronym) && !isUser
                let exact = toks.enumerated().compactMap { i, t in t.isAcronym ? (i, t.text) : nil }
                insertEN(toks.map(\.norm), Payload(target: keep ? form : zh, keep: keep, priority: p,
                                                   domain: e.domain, exact: exact))
            }
        }
    }

    private func insertZH(_ key: String, _ payload: Payload) {
        var node = 0
        for s in key.unicodeScalars {
            if let n = zhChildren[node][s.value] { node = n }
            else {
                zhChildren.append([:]); zhPayload.append(nil)
                let n = zhChildren.count - 1
                zhChildren[node][s.value] = n
                node = n
            }
        }
        if let old = zhPayload[node], old.priority <= payload.priority { return }
        if zhPayload[node] == nil { zhKeyCount += 1 }
        zhPayload[node] = payload
    }

    private func insertEN(_ key: [String], _ payload: Payload) {
        var node = 0
        for w in key {
            if let n = enChildren[node][w] { node = n }
            else {
                enChildren.append([:]); enPayload.append([])
                let n = enChildren.count - 1
                enChildren[node][w] = n
                node = n
            }
        }
        // 同一键：区分大小写的（缩写）放前面；同类按优先级，同优先级保留先来的
        var list = enPayload[node]
        if list.isEmpty { enKeyCount += 1 }
        if let i = list.firstIndex(where: { $0.exact.isEmpty == payload.exact.isEmpty }) {
            if list[i].priority > payload.priority { list[i] = payload }
        } else {
            list.append(payload)
            list.sort { !$0.exact.isEmpty && $1.exact.isEmpty }
        }
        enPayload[node] = list
    }

    // MARK: 英文切词

    struct Token {
        let text: String       // 原样
        let norm: String       // 小写 + 单数
        let start: Int         // 标量偏移
        let end: Int
        var isAcronym: Bool { GlossaryIndex.isAcronym(text) }
        var isNumber: Bool { text.unicodeScalars.allSatisfy { $0.properties.numericType != nil } }
        /// 文中的 ESPs / MCUs → ESP / MCU
        var acronymBase: String {
            if text.count > 2, text.hasSuffix("s"), GlossaryIndex.isAcronym(String(text.dropLast())) { return String(text.dropLast()) }
            return text
        }
    }

    /// 缩写 / 专名写法：至少两个大写字母（CAN、ESP、I2C、LoRA、IoT、MoE、DevOps），或“大写字母+数字”（G5、H2S 已含两个）
    /// 这类词区分大小写匹配（cot ≠ CoT，can ≠ CAN），英→中时默认原样保留。
    static func isAcronym(_ s: String) -> Bool {
        var upper = 0, lower = 0, digit = 0
        for u in s.unicodeScalars {
            if u.properties.isUppercase { upper += 1 }
            else if u.properties.isLowercase { lower += 1 }
            else if u.properties.numericType != nil { digit += 1 }
        }
        if upper >= 2 { return true }
        return upper == 1 && lower == 0 && digit > 0
    }

    static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        (u.value < 128 && (CharacterSet.alphanumerics.contains(u))) || LanguageDetector.isLatinLetter(u)
            || (u.value >= 0x30 && u.value <= 0x39) || u == "²" || u == "³"
    }

    static func tokenize(_ s: String) -> [Token] { tokenize(Array(s.unicodeScalars)) }

    static func tokenize(_ sc: [Unicode.Scalar]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < sc.count {
            guard isWordScalar(sc[i]) else { i += 1; continue }
            var j = i
            while j < sc.count && isWordScalar(sc[j]) { j += 1 }
            var v = String.UnicodeScalarView(); v.append(contentsOf: sc[i..<j])
            let text = String(v)
            out.append(Token(text: text, norm: singular(text.lowercased()), start: i, end: j))
            i = j
        }
        return out
    }

    /// 简单单复数归一（索引和文本用同一规则，所以只要两边一致即可）
    static func singular(_ w: String) -> String {
        guard w.count > 3, w.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return w }
        if w.hasSuffix("ies") && w.count > 4 { return String(w.dropLast(3)) + "y" }
        for suf in ["sses", "shes", "ches", "xes", "zzes"] where w.hasSuffix(suf) { return String(w.dropLast(2)) }
        if w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is") { return w }
        if w.hasSuffix("s") { return String(w.dropLast()) }
        return w
    }

    // MARK: 匹配

    public func matches(in text: String, from: TextLanguage) -> [GlossaryMatch] {
        let sc = Array(text.unicodeScalars)
        return from == .chinese ? matchZH(sc) : matchEN(sc)
    }

    func matchZH(_ sc: [Unicode.Scalar]) -> [GlossaryMatch] {
        var out: [GlossaryMatch] = []
        var i = 0
        while i < sc.count {
            var node = 0, j = i
            var best: (end: Int, p: Payload)?
            while j < sc.count, let n = zhChildren[node][sc[j].value] {
                node = n; j += 1
                if let p = zhPayload[node] { best = (j, p) }
            }
            if let b = best {
                out.append(GlossaryMatch(range: i..<b.end, source: Self.string(sc[i..<b.end]), target: b.p.target,
                                         keep: b.p.keep, domain: b.p.domain))
                i = b.end
            } else {
                i += 1
            }
        }
        return out
    }

    func matchEN(_ sc: [Unicode.Scalar]) -> [GlossaryMatch] {
        let toks = Self.tokenize(sc)
        var out: [GlossaryMatch] = []
        var i = 0
        while i < toks.count {
            var node = 0, j = i
            var best: (endTok: Int, p: Payload)?
            while j < toks.count, let n = enChildren[node][toks[j].norm] {
                node = n; j += 1
                for p in enPayload[node] {
                    let ok = p.exact.allSatisfy { k, exact in toks[i + k].acronymBase == exact || toks[i + k].text == exact }
                    if ok { best = (j, p); break }
                }
            }
            if let b = best {
                let r = toks[i].start..<toks[b.endTok - 1].end
                let src = Self.string(sc[r])
                out.append(GlossaryMatch(range: r, source: src, target: b.p.keep ? src : b.p.target,
                                         keep: b.p.keep, domain: b.p.domain))
                i = b.endTok
            } else {
                i += 1
            }
        }
        return out
    }

    static func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var v = String.UnicodeScalarView(); v.append(contentsOf: s); return String(v)
    }
}
