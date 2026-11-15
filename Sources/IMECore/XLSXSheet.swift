import Foundation

/// 读 .xlsx 第一张表（只需要 sharedStrings.xml 与 sheetN.xml 的内容；解压由 App 用系统 unzip 完成）
public enum XLSXSheet {
    public static func sharedStrings(_ data: Data) -> [String] {
        let p = SSParser(); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.items
    }

    public static func rows(sheet: Data, shared: [String]) -> [[String]] {
        let p = SheetParser(shared: shared); let x = XMLParser(data: sheet); x.delegate = p; x.parse()
        return p.rows
    }

    /// "B12" → 1
    static func columnIndex(_ ref: String) -> Int? {
        var n = 0, seen = false
        for u in ref.unicodeScalars {
            guard u.value >= 65 && u.value <= 90 else { break }
            n = n * 26 + Int(u.value - 64); seen = true
        }
        return seen ? n - 1 : nil
    }

    private final class SSParser: NSObject, XMLParserDelegate {
        var items: [String] = []
        private var current = "", inSI = false, inT = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { inSI = true; current = "" } else if e == "t" && inSI { inT = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inT { current += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false } else if e == "si" { items.append(current); inSI = false }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var col = 0, type = "", value = "", inV = false, inT = false
        init(shared: [String]) { self.shared = shared }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row": row = []
            case "c":
                col = a["r"].flatMap(XLSXSheet.columnIndex) ?? row.count
                type = a["t"] ?? ""; value = ""
            case "v": inV = true
            case "t": inT = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inV || inT { value += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "v": inV = false
            case "t": inT = false
            case "c":
                var text = value
                if type == "s", let i = Int(value), i >= 0, i < shared.count { text = shared[i] }
                while row.count < col { row.append("") }
                if row.count == col { row.append(text) } else if col < row.count { row[col] = text }
            case "row":
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            default: break
            }
        }
    }
}
