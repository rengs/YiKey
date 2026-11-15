import Foundation

public enum TextLanguage: String, Sendable, Equatable, CaseIterable {
    case chinese, english

    /// 传给 Locale.Language(identifier:) 的标识
    public var bcp47: String { self == .chinese ? "zh-Hans" : "en" }
    public var opposite: TextLanguage { self == .chinese ? .english : .chinese }
}

public enum DetectedLanguage: Equatable, Sendable {
    case chinese, english, unknown
}

/// 轻量语言判别：只区分中文 / 英文。
/// 规则：汉字个数 >= 拉丁“单词”个数 且 有汉字 → 中文；含假名 → unknown（不支持日语）；
/// 无汉字也无拉丁字母 → unknown。
public enum LanguageDetector {
    public static func detect(_ text: String) -> DetectedLanguage {
        var han = 0, kana = 0, words = 0
        var inWord = false
        for s in text.unicodeScalars {
            if isHan(s) {
                han += 1; inWord = false
            } else if isKana(s) {
                kana += 1; inWord = false
            } else if isLatinLetter(s) {
                if !inWord { words += 1; inWord = true }
            } else if inWord && (s == "'" || s == "\u{2019}" || s == "-" || (0x30...0x39).contains(s.value)) {
                // 词内的撇号、连字符、数字：保持在词内
            } else {
                inWord = false
            }
        }
        if kana > 0 { return .unknown }
        if han == 0 && words == 0 { return .unknown }
        if han > 0 && han >= words { return .chinese }
        return .english
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2EBEF: return true
        default: return false
        }
    }
    static func isKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }
    static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic && s.value < 0x250
    }
}
