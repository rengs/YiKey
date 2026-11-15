import Foundation

/// “纠正译法”编辑器的预填：优先用输入框里选中的文字；没选中且整段很短（像一个词）时用整段；
/// 原词就是整段时，把当前译文填进“正确译法”方便直接改。
public struct CorrectionPrefill: Equatable, Sendable {
    public var source: String
    public var target: String

    public static func make(selection: String, whole: String, translation: String?) -> CorrectionPrefill {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = whole.trimmingCharacters(in: .whitespacesAndNewlines)
        let src = !sel.isEmpty ? sel : (isTermLike(all) ? all : "")
        var dst = ""
        if !src.isEmpty, src == all, let t = translation?.trimmingCharacters(in: .whitespacesAndNewlines), isTermLike(t) {
            dst = t.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        }
        return CorrectionPrefill(source: src, target: dst)
    }

    /// 像一个术语：中文 ≤ 12 字、英文 ≤ 5 个词，且不含句中标点
    public static func isTermLike(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 40 else { return false }
        if s.rangeOfCharacter(from: CharacterSet(charactersIn: "，,；;：:\n")) != nil { return false }
        let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        if body.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return body.count <= 12 }
        return body.split(whereSeparator: { $0 == " " }).count <= 5
    }
}
