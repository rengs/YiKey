import Foundation

// MARK: - CSV / TSV 读写（RFC 4180：引号、转义引号、字段内逗号/换行；去掉 UTF-8 BOM；自动识别逗号/制表符）

public enum DelimitedText {
    public static let bom = "\u{FEFF}"

    /// 自动识别分隔符：第一行里制表符比逗号多 → TSV
    public static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let tabs = firstLine.filter { $0 == "\t" }.count
        let commas = firstLine.filter { $0 == "," }.count
        return tabs > commas ? "\t" : ","
    }

    public static func parse(_ raw: String, delimiter: Character? = nil) -> [[String]] {
        var text = Substring(raw)
        if text.hasPrefix(bom) { text = text.dropFirst() }
        let d = delimiter ?? detectDelimiter(String(text))
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var it = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        func endField() { row.append(field); field = ""; fieldStarted = false }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") }
                        else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where !fieldStarted && field.isEmpty:
                inQuotes = true; fieldStarted = true
            case d:
                endField()
            case "\n", "\r\n", "\r":
                endRow()
            default:
                field.append(c); fieldStarted = true
            }
        }
        if !field.isEmpty || !row.isEmpty || fieldStarted { endRow() }
        return rows
    }

    public static func quote(_ s: String, delimiter: Character = ",") -> String {
        let needs = s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r")
            || s.hasPrefix(" ") || s.hasSuffix(" ")
        return needs ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// 写出：可选 BOM（Excel 识别 UTF-8 需要），CRLF 行尾（Excel/Numbers 都能读）
    public static func format(_ rows: [[String]], delimiter: Character = ",", withBOM: Bool = true) -> String {
        let body = rows.map { $0.map { quote($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }
            .joined(separator: "\r\n")
        return (withBOM ? bom : "") + body + "\r\n"
    }
}
