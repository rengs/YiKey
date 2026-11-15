import Foundation

// MARK: - 术语保护：翻译前替换、翻译后还原
//
// 实测（Apple 本地翻译，2026-11-14，本机）：
// - 直接把“目标语言的标准术语”嵌进原文（中文句子里嵌英文术语 / 英文句子里嵌中文术语）：12/12 原样保留，
//   而且译文语法最自然（会自动补冠词 the、正确的介词）。→ 首选。
// - 拉丁字母占位符（ZQXA、XZQ1 等）10 种写法各 17/17 保留，但会丢冠词、偶尔多出空格；{1} 会被改成 {{1}}，
//   TERM1 会让整句变全大写，⟦T1⟧ 会粘连空格。→ 作为备用：嵌入后有术语丢失时，改用 ZQX+字母 占位符重译一次。
// - 两次都丢：取丢得少的那次，并在结果里记下丢失数（日志可见）。

public struct TermSlot: Equatable, Sendable {
    public let source: String
    public let target: String
    public let keep: Bool
    public let placeholder: String
}

public struct TermRestoreResult: Equatable, Sendable {
    public var text: String
    /// 没找回来的术语序号
    public var lost: [Int]
    public var mode: String
}

public struct TermPlan: Equatable, Sendable {
    public let original: String
    public let from: TextLanguage
    public let slots: [TermSlot]
    /// 方案 A：目标术语直接嵌入原文（缩写保留项用占位符）
    public let injectedText: String
    /// 方案 B：全部用占位符
    public let placeholderText: String
    /// 整句就是一个术语（可带句末标点）：不用调用翻译引擎
    public let singleTermOutput: String?

    public var target: TextLanguage { from.opposite }
    public var isEmpty: Bool { slots.isEmpty }

    public static let maxSlots = 26
    static func placeholder(_ i: Int) -> String { "ZQX" + String(UnicodeScalar(UInt8(65 + i))) }

    public init(original: String, from: TextLanguage, matches: [GlossaryMatch]) {
        self.original = original
        self.from = from
        let sc = Array(original.unicodeScalars)
        let ms = Array(matches.prefix(Self.maxSlots))
        var slots: [TermSlot] = []
        var inj = "", ph = ""
        var pos = 0
        func isLatinOrDigit(_ u: Unicode.Scalar?) -> Bool {
            guard let u else { return false }
            return LanguageDetector.isLatinLetter(u) || (u.value >= 0x30 && u.value <= 0x39)
        }
        for (i, m) in ms.enumerated() {
            let gap = GlossaryIndex.string(sc[pos..<m.range.lowerBound])
            inj += gap; ph += gap
            let code = Self.placeholder(i)
            slots.append(TermSlot(source: m.source, target: m.target, keep: m.keep, placeholder: code))
            let after = m.range.upperBound < sc.count ? sc[m.range.upperBound] : nil
            // 拉丁文字紧挨着拉丁字母/数字（原文里的，或刚放进去的上一个术语）时补空格，避免粘成一个词
            func padded(_ t: String, after acc: String) -> String {
                guard let f = t.unicodeScalars.first, let l = t.unicodeScalars.last else { return t }
                var r = t
                if isLatinOrDigit(acc.unicodeScalars.last) && isLatinOrDigit(f) { r = " " + r }
                if isLatinOrDigit(after) && isLatinOrDigit(l) { r += " " }
                return r
            }
            inj += padded(m.keep ? code : m.target, after: inj)
            ph += padded(code, after: ph)
            pos = m.range.upperBound
        }
        let tail = GlossaryIndex.string(sc[pos..<sc.count])
        inj += tail; ph += tail
        self.slots = slots
        self.injectedText = inj
        self.placeholderText = ph

        // 整句只有一个术语（允许首尾空白和句末标点）
        if ms.count == 1 {
            let m = ms[0]
            let head = GlossaryIndex.string(sc[0..<m.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = GlossaryIndex.string(sc[m.range.upperBound..<sc.count]).trimmingCharacters(in: .whitespacesAndNewlines)
            let punct = Set(["", "。", ".", "！", "!", "？", "?", "；", ";", "：", ":"])
            if head.isEmpty && punct.contains(rest) {
                singleTermOutput = m.target + Self.mapPunctuation(rest, to: from.opposite)
            } else { singleTermOutput = nil }
        } else { singleTermOutput = nil }
    }

    static func mapPunctuation(_ p: String, to target: TextLanguage) -> String {
        let toEN = ["。": ".", "！": "!", "？": "?", "；": ";", "：": ":"]
        let toZH = [".": "。", "!": "！", "?": "？", ";": "；", ":": "："]
        return (target == .english ? toEN[p] : toZH[p]) ?? p
    }

    // MARK: 还原

    /// 方案 A 的译文：检查每个嵌入的术语都还在（英文按整词、大小写/单复数不敏感），并修正冠词/句首大写/中文空格
    public func acceptInjected(_ output: String) -> TermRestoreResult {
        var text = replacePlaceholders(in: output, onlyKeep: true).text
        var lost: [Int] = []
        for (i, s) in slots.enumerated() where !s.keep {
            if !Self.contains(text, term: s.target, language: target) { lost.append(i) }
        }
        let keepLost = replacePlaceholders(in: output, onlyKeep: true).lost
        lost += keepLost
        text = polish(text)
        return TermRestoreResult(text: text, lost: lost.sorted(), mode: "inject")
    }

    /// 方案 B 的译文：把（可能被改了大小写/插了空格的）占位符换回目标术语
    public func restorePlaceholders(_ output: String) -> TermRestoreResult {
        let r = replacePlaceholders(in: output, onlyKeep: false)
        return TermRestoreResult(text: polish(r.text), lost: r.lost, mode: "placeholder")
    }

    private static let placeholderRegex = try! NSRegularExpression(pattern: "[Zz]\\s?[Qq]\\s?[Xx]\\s?([A-Za-z])")

    func replacePlaceholders(in output: String, onlyKeep: Bool) -> (text: String, lost: [Int]) {
        var found = Set<Int>()
        let ns = output as NSString
        var result = ""
        var last = 0
        for m in Self.placeholderRegex.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
            let letter = ns.substring(with: m.range(at: 1)).uppercased().unicodeScalars.first!.value
            let i = Int(letter) - 65
            guard i >= 0, i < slots.count, !(onlyKeep && !slots[i].keep) else { continue }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // 占位符被引擎粘在一起（ZQXAZQXB）或贴着英文单词时，还原后补空格
            let t = slots[i].target
            if isLatin(result.unicodeScalars.last) && isLatin(t.unicodeScalars.first) { result += " " }
            result += t
            let next = m.range.location + m.range.length
            if next < ns.length, let u = Unicode.Scalar(ns.character(at: next)), isLatin(u),
               isLatin(t.unicodeScalars.last), !Self.placeholderStarts(ns, at: next) { result += " " }
            found.insert(i)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        let lost = slots.indices.filter { (onlyKeep ? slots[$0].keep : true) && !found.contains($0) }
        return (result, lost)
    }

    private func isLatin(_ u: Unicode.Scalar?) -> Bool {
        guard let u else { return false }
        return LanguageDetector.isLatinLetter(u) || (u.value >= 0x30 && u.value <= 0x39)
    }

    /// next 处是否紧跟着另一个占位符（它自己还原时会补空格）
    static func placeholderStarts(_ ns: NSString, at i: Int) -> Bool {
        guard let m = placeholderRegex.firstMatch(in: ns as String, range: NSRange(location: i, length: ns.length - i)) else { return false }
        return m.range.location == i
    }

    static func contains(_ text: String, term: String, language: TextLanguage) -> Bool {
        if language == .chinese {
            return text.contains(term) || text.replacingOccurrences(of: " ", with: "").contains(term.replacingOccurrences(of: " ", with: ""))
        }
        let t = GlossaryIndex.tokenize(text).map(\.norm)
        let k = GlossaryIndex.tokenize(term).map(\.norm)
        guard !k.isEmpty, t.count >= k.count else { return false }
        for i in 0...(t.count - k.count) where Array(t[i..<(i + k.count)]) == k { return true }
        return false
    }

    /// 英文：句首大写、a/an；中文：术语与汉字之间不留空格
    func polish(_ text: String) -> String {
        var s = text
        if target == .english {
            for slot in slots where !slot.keep { s = Self.fixEnglish(s, term: slot.target) }
        } else {
            for slot in slots where !slot.keep && slot.target.unicodeScalars.contains(where: { LanguageDetector.isHan($0) }) {
                let t = NSRegularExpression.escapedPattern(for: slot.target)
                s = s.replacingOccurrences(of: "(\\p{Han}|[，。、；：])[ \\t]+(\(t))", with: "$1$2", options: .regularExpression)
                s = s.replacingOccurrences(of: "(\(t))[ \\t]+(\\p{Han}|[，。、；：])", with: "$1$2", options: .regularExpression)
            }
        }
        return s
    }

    static func fixEnglish(_ text: String, term: String) -> String {
        guard let first = term.first else { return text }
        let t = NSRegularExpression.escapedPattern(for: term)
        var s = text
        // a / an
        let an = needsAn(term)
        s = s.replacingOccurrences(of: "\\b([Aa])n?(\\s+)(\(t))", with: an ? "$1n$2$3" : "$1$2$3",
                                   options: [.regularExpression, .caseInsensitive])
        // 句首（开头，或 . ! ? 之后）的小写术语 → 首字母大写
        if first.isLowercase {
            let cap = first.uppercased() + term.dropFirst()
            if let r = s.range(of: "^([\"'“‘(\\s]*)" + t, options: [.regularExpression]) {
                let lead = s[r].prefix { !$0.isLetter }
                s.replaceSubrange(r, with: lead + cap)
            }
            s = s.replacingOccurrences(of: "([.!?]\\s+)" + t, with: "$1" + NSRegularExpression.escapedTemplate(for: cap),
                                       options: .regularExpression)
        }
        return s
    }

    static func needsAn(_ term: String) -> Bool {
        let w = term.split(separator: " ").first.map(String.init) ?? term
        if GlossaryIndex.isAcronym(w) { return "AEFHILMNORSX".contains(w.first!) }
        let l = w.lowercased()
        for p in ["uni", "use", "usu", "uti", "eu", "one", "once", "ura", "uro"] where l.hasPrefix(p) { return false }
        for p in ["hour", "honest", "honor", "heir"] where l.hasPrefix(p) { return true }
        return "aeiou".contains(l.first ?? "x")
    }
}

/// 翻译服务用：给一段原文生成术语保护方案（无术语返回 nil）
public protocol TermProtecting: Sendable {
    func plan(for text: String, from: TextLanguage) -> TermPlan?
}
