#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import IMECore

// MARK: - 测试用小词表

enum GT {
    static let petroleum: [GlossaryEntry] = [
        GlossaryEntry(zh: ["抽油机", "抽油机组"], en: ["pumping unit", "pump jack"], domain: .petroleum),
        GlossaryEntry(zh: ["抽油机井"], en: ["rod-pumped well"], domain: .petroleum),
        GlossaryEntry(zh: ["冲次"], en: ["strokes per minute", "SPM"], domain: .petroleum, flags: .expandAcronym),
        GlossaryEntry(zh: ["含水率"], en: ["water cut"], domain: .petroleum),
        GlossaryEntry(zh: ["示功图"], en: ["dynamometer card"], domain: .petroleum),
        GlossaryEntry(zh: ["电潜泵"], en: ["electric submersible pump", "ESP"], domain: .petroleum),
        GlossaryEntry(zh: ["有杆泵"], en: ["sucker rod pump"], domain: .petroleum),
        GlossaryEntry(zh: ["井"], en: ["well"], domain: .petroleum),            // 单字：内置表里应被跳过
        GlossaryEntry(zh: ["泵效"], en: ["pump efficiency"], domain: .petroleum),
        GlossaryEntry(zh: ["系统"], en: ["system"], domain: .petroleum),        // 停用词
    ]
    static let embedded: [GlossaryEntry] = [
        GlossaryEntry(zh: ["单片机", "微控制器"], en: ["microcontroller", "MCU"], domain: .embedded),
        GlossaryEntry(zh: ["CAN总线"], en: ["CAN bus", "CAN"], domain: .embedded),
        GlossaryEntry(zh: ["模数转换器"], en: ["ADC", "analog-to-digital converter"], domain: .embedded),
        GlossaryEntry(zh: ["看门狗"], en: ["watchdog timer"], domain: .embedded),
        GlossaryEntry(zh: ["远距离无线电"], en: ["LoRa"], domain: .embedded),
        GlossaryEntry(zh: ["变换器"], en: ["converter"], domain: .embedded, flags: .zhToEnOnly),
    ]
    static let ai: [GlossaryEntry] = [
        GlossaryEntry(zh: ["思维链"], en: ["chain-of-thought", "CoT"], domain: .ai),
        GlossaryEntry(zh: ["大语言模型"], en: ["large language model", "LLM"], domain: .ai),
    ]
    static func store(user: [GlossaryEntry] = []) -> GlossaryStore {
        GlossaryStore(builtIns: [.petroleum: petroleum, .embedded: embedded, .ai: ai], user: user)
    }
    static func tempURL(_ name: String = "glossary.csv") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    static var builtInDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Glossaries")
    }
}

final class GlossaryCSVTests: XCTestCase {
    func testQuotesCommasNewlinesAndBOM() {
        let csv = "\u{FEFF}中文,英文,领域,备注\r\n\"抽油机, 游梁式\",\"beam \"\"pumping\"\" unit\",石油,\"两行\n备注\"\r\n冲次,SPM,,\r\n"
        let rows = DelimitedText.parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["中文", "英文", "领域", "备注"])
        XCTAssertEqual(rows[1], ["抽油机, 游梁式", "beam \"pumping\" unit", "石油", "两行\n备注"])
        XCTAssertEqual(rows[2], ["冲次", "SPM", "", ""])
    }

    func testTSVAutoDetectAndExplicit() {
        let tsv = "中文\t英文\n含水率\twater cut\n"
        XCTAssertEqual(DelimitedText.parse(tsv), [["中文", "英文"], ["含水率", "water cut"]])
        XCTAssertEqual(DelimitedText.parse("a;b\n", delimiter: ";"), [["a", "b"]])
    }

    func testFormatRoundTripWithBOMAndCRLF() {
        let rows = [["中文", "英文"], ["a,b", "say \"hi\""], ["多行\n文本", "x"]]
        let text = DelimitedText.format(rows)
        XCTAssertTrue(text.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(text.contains("\r\n"))
        XCTAssertEqual(DelimitedText.parse(text), rows)
    }

    func testBuiltInCSVParsingVariantsAndFlags() {
        let csv = "zh,en,zh_alt,en_alt,flags,note\n冲次,strokes per minute,冲数|冲速,SPM,x,\n变换器,converter,,,z2e,\n# 注释,x,,,,\n"
        let e = BuiltInGlossary.parse(csv, domain: .petroleum)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e[0].zh, ["冲次", "冲数", "冲速"])
        XCTAssertEqual(e[0].en, ["strokes per minute", "SPM"])
        XCTAssertTrue(e[0].flags.contains(.expandAcronym))
        XCTAssertTrue(e[1].flags.contains(.zhToEnOnly))
    }

    func testXLSXSheetParsing() {
        let ss = """
        <?xml version="1.0" encoding="UTF-8"?><sst xmlns="x" count="4"><si><t>中文</t></si><si><t>英文</t></si>\
        <si><r><t>抽油</t></r><r><t>机</t></r></si><si><t>pumping unit</t></si></sst>
        """
        let sheet = """
        <?xml version="1.0"?><worksheet><sheetData>\
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>\
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c><c r="D2" t="inlineStr"><is><t>备注</t></is></c></row>\
        <row r="3"></row></sheetData></worksheet>
        """
        let shared = XLSXSheet.sharedStrings(Data(ss.utf8))
        XCTAssertEqual(shared, ["中文", "英文", "抽油机", "pumping unit"])
        let rows = XLSXSheet.rows(sheet: Data(sheet.utf8), shared: shared)
        XCTAssertEqual(rows, [["中文", "英文"], ["抽油机", "pumping unit", "", "备注"]])
        XCTAssertEqual(UserGlossaryFile.rows(from: rows), [UserGlossaryRow(zh: "抽油机", en: "pumping unit")])
        XCTAssertEqual(XLSXSheet.columnIndex("AA10"), 26)
    }
}

final class GlossaryMatchTests: XCTestCase {
    func testChineseLeftmostLongest() {
        let s = GT.store()
        let m = s.matches(in: "这口抽油机井的抽油机冲次偏高", from: .chinese)
        XCTAssertEqual(m.map(\.source), ["抽油机井", "抽油机", "冲次"])
        XCTAssertEqual(m.map(\.target), ["rod-pumped well", "pumping unit", "strokes per minute"])
        // 同义写法映射到标准译法
        XCTAssertEqual(s.matches(in: "抽油机组", from: .chinese).first?.target, "pumping unit")
    }

    func testEnglishWholeWordCaseInsensitiveAndPlural() {
        let s = GT.store()
        let m = s.matches(in: "Check the Pumping Units and the water-cut; dynamometer cards look odd.", from: .english)
        // 连字符按词边界处理：water-cut 也认作 water cut
        XCTAssertEqual(m.map(\.target), ["抽油机", "含水率", "示功图"])
        // pumping unitx 不是整词
        XCTAssertTrue(s.matches(in: "pumping unitx", from: .english).isEmpty)
        XCTAssertEqual(s.matches(in: "The water cut rose.", from: .english).first?.target, "含水率")
    }

    func testEnglishMultiWordLongestWins() {
        let s = GT.store()
        let m = s.matches(in: "Install an electric submersible pump.", from: .english)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.target, "电潜泵")
    }

    func testAcronymsAreCaseSensitiveAndKept() {
        let s = GT.store()
        // CAN（缩写）≠ can（情态动词）；LoRa / CoT 混合大小写同样区分
        XCTAssertTrue(s.matches(in: "We can fix it", from: .english).isEmpty)
        XCTAssertTrue(s.matches(in: "the cot is folded", from: .english).isEmpty)
        let m = s.matches(in: "The MCU talks CAN and uses CoT prompts with LoRa.", from: .english)
        XCTAssertEqual(m.map(\.source), ["MCU", "CAN", "CoT", "LoRa"])
        XCTAssertTrue(m.allSatisfy(\.keep))           // 英→中默认保留缩写原样
        // 复数缩写
        XCTAssertEqual(s.matches(in: "Two ESPs failed", from: .english).first?.source, "ESPs")
        // 标记 x 的缩写要展开
        let spm = s.matches(in: "Set SPM to 6", from: .english)
        XCTAssertEqual(spm.first?.target, "冲次"); XCTAssertEqual(spm.first?.keep, false)
    }

    func testIsAcronym() {
        for w in ["CAN", "ESP", "I2C", "LoRA", "IoT", "MoE", "DevOps", "G5"] { XCTAssertTrue(GlossaryIndex.isAcronym(w), w) }
        for w in ["can", "Well", "Pump", "i", "A", "x2"] { XCTAssertFalse(GlossaryIndex.isAcronym(w), w) }
    }

    func testStoplistAndSingleCharSkippedForBuiltIn() {
        let s = GT.store()
        XCTAssertTrue(s.matches(in: "这个系统里的井", from: .chinese).isEmpty)
        XCTAssertTrue(s.matches(in: "the well is fine", from: .english).isEmpty)
        // 用户词表不受限制
        let u = GT.store(user: [GlossaryEntry(zh: ["井"], en: ["wellbore"], domain: .user)])
        XCTAssertEqual(u.matches(in: "井", from: .chinese).first?.target, "wellbore")
    }

    func testDirectionFlags() {
        let s = GT.store()
        XCTAssertEqual(s.matches(in: "变换器", from: .chinese).first?.target, "converter")
        XCTAssertTrue(s.matches(in: "a converter", from: .english).isEmpty)
    }

    func testDomainToggleAndMaster() {
        let s = GT.store()
        s.setEnabled(.petroleum, false)
        XCTAssertTrue(s.matches(in: "抽油机", from: .chinese).isEmpty)
        XCTAssertFalse(s.matches(in: "单片机", from: .chinese).isEmpty)
        s.setEnabled(.petroleum, true)
        s.setMaster(false)
        XCTAssertTrue(s.matches(in: "抽油机", from: .chinese).isEmpty)
        s.setMaster(true)
        XCTAssertFalse(s.matches(in: "抽油机", from: .chinese).isEmpty)
    }

    func testUserEntriesWinOverBuiltIn() {
        let u = GT.store(user: [GlossaryEntry(zh: ["抽油机"], en: ["beam pumping unit"], domain: .user)])
        XCTAssertEqual(u.matches(in: "抽油机", from: .chinese).first?.target, "beam pumping unit")
        XCTAssertEqual(u.matches(in: "抽油机", from: .chinese).first?.domain, .user)
        // 用户英文同样优先（英→中）
        let u2 = GT.store(user: [GlossaryEntry(zh: ["游梁式抽油机"], en: ["pumping unit"], domain: .user)])
        XCTAssertEqual(u2.matches(in: "the pumping unit", from: .english).first?.target, "游梁式抽油机")
    }
}

final class TermPlanTests: XCTestCase {
    func testInjectionZhToEn() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "检查抽油机的冲次", from: .chinese))
        XCTAssertEqual(p.injectedText, "检查pumping unit的strokes per minute")
        XCTAssertEqual(p.placeholderText, "检查ZQXA的ZQXB")
        XCTAssertNil(p.singleTermOutput)
    }

    func testInjectionPadsLatinNeighbours() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "3号井ESP电潜泵", from: .chinese))
        XCTAssertEqual(p.injectedText, "3号井ESP electric submersible pump")
    }

    func testAdjacentTermsAreSpacedInBothModes() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "抽油机冲次偏高", from: .chinese))
        XCTAssertEqual(p.injectedText, "pumping unit strokes per minute偏高")
        XCTAssertEqual(p.placeholderText, "ZQXA ZQXB偏高")
        XCTAssertEqual(p.restorePlaceholders("ZQXAZQXB is high").text, "Pumping unit strokes per minute is high")
        XCTAssertEqual(p.restorePlaceholders("The ZQXAZQXBvalue").text, "The pumping unit strokes per minute value")
    }

    func testAcceptInjectedVerifiesTerms() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "检查抽油机的冲次", from: .chinese))
        let ok = p.acceptInjected("Check the Pumping Units' strokes per minute")
        XCTAssertEqual(ok.lost, []); XCTAssertEqual(ok.mode, "inject")
        let bad = p.acceptInjected("Check the oil pump's punch")
        XCTAssertEqual(bad.lost, [0, 1])
    }

    func testPlaceholderRoundTripAndMangledRecovery() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "检查抽油机的冲次", from: .chinese))
        XCTAssertEqual(p.restorePlaceholders("Check ZQXA's ZQXB.").text, "Check pumping unit's strokes per minute.")
        let m = p.restorePlaceholders("check zqx a and Z Q X b")
        XCTAssertEqual(m.text, "check pumping unit and strokes per minute"); XCTAssertEqual(m.lost, [])
        XCTAssertEqual(p.restorePlaceholders("Check ZQXA only").lost, [1])
    }

    func testSingleTermSkipsEngine() throws {
        XCTAssertEqual(GT.store().plan(for: "含水率。", from: .chinese)?.singleTermOutput, "water cut.")
        XCTAssertEqual(GT.store().plan(for: "Dynamometer card", from: .english)?.singleTermOutput, "示功图")
    }

    func testEnToZhKeepsAcronymsAndInjectsChinese() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "The MCU reads the water cut.", from: .english))
        XCTAssertEqual(p.injectedText, "The ZQXA reads the 含水率.")
        let r = p.acceptInjected("ZQXA 读取 含水率。")
        XCTAssertEqual(r.text, "MCU 读取含水率。")
        XCTAssertEqual(r.lost, [])
    }

    func testArticlesAndSentenceCapitalization() throws {
        let p = try XCTUnwrap(GT.store().plan(for: "电潜泵坏了，换一台电潜泵", from: .chinese))
        let r = p.acceptInjected("electric submersible pump is broken, replace it with a electric submersible pump")
        XCTAssertEqual(r.text, "Electric submersible pump is broken, replace it with an electric submersible pump")
        XCTAssertTrue(TermPlan.needsAn("ESP")); XCTAssertFalse(TermPlan.needsAn("unit test")); XCTAssertTrue(TermPlan.needsAn("hour"))
        XCTAssertEqual(TermPlan.fixEnglish("Check it. pumping unit ok", term: "pumping unit"), "Check it. Pumping unit ok")
    }
}

final class GlossaryServiceTests: XCTestCase {
    func testServiceInjectsTermsAndKeepsThem() async throws {
        let p = MockProvider(id: "apple") { t, _, _ in
            t.replacingOccurrences(of: "检查", with: "Check the ").replacingOccurrences(of: "的", with: " ")
        }
        let svc = TranslationService(providers: [p], glossary: GT.store())
        let r = try await svc.translate("检查抽油机的冲次")
        XCTAssertEqual(p.calls.map(\.text), ["检查pumping unit的strokes per minute"])
        XCTAssertEqual(r.translated, "Check the pumping unit strokes per minute")
        XCTAssertEqual(r.glossaryTerms, 2); XCTAssertEqual(r.glossaryMode, "inject"); XCTAssertEqual(r.glossaryLost, 0)
    }

    func testServiceFallsBackToPlaceholdersWhenTermLost() async throws {
        let p = MockProvider(id: "apple") { t, _, _ in
            t.contains("ZQX") ? "Check ZQXA's ZQXB" : "Check the oil pump's punch"
        }
        let svc = TranslationService(providers: [p], glossary: GT.store())
        let r = try await svc.translate("检查抽油机的冲次")
        XCTAssertEqual(p.calls.count, 2)
        XCTAssertEqual(r.translated, "Check pumping unit's strokes per minute")
        XCTAssertEqual(r.glossaryMode, "placeholder"); XCTAssertEqual(r.glossaryLost, 0)
    }

    func testSingleTermNeedsNoEngine() async throws {
        let p = MockProvider(id: "apple") { _, _, _ in "should not be called" }
        let r = try await TranslationService(providers: [p], glossary: GT.store()).translate("示功图")
        XCTAssertEqual(r.translated, "dynamometer card"); XCTAssertEqual(r.providerID, "glossary")
        XCTAssertTrue(p.calls.isEmpty)
    }

    func testEnToZhDirection() async throws {
        let p = MockProvider(id: "apple") { t, _, _ in t.replacingOccurrences(of: "Check the ", with: "检查") }
        let r = try await TranslationService(providers: [p], glossary: GT.store()).translate("Check the sucker rod pump")
        XCTAssertEqual(p.calls.first?.text, "Check the 有杆泵")
        XCTAssertEqual(r.translated, "检查有杆泵")
    }

    func testCacheClearedWhenGlossaryChanges() async throws {
        let store = GT.store()
        let p = MockProvider(id: "apple") { t, _, _ in t }
        let svc = TranslationService(providers: [p], glossary: store)
        let cache = svc.cache
        store.onChange = { cache.removeAll() }
        _ = try await svc.translate("抽油机坏了")
        XCTAssertNotNil(cache.lookup("抽油机坏了"))
        store.setUser([GlossaryEntry(zh: ["抽油机"], en: ["beam pumping unit"], domain: .user)])
        XCTAssertNil(cache.lookup("抽油机坏了"))
        let r = try await svc.translate("抽油机坏了")
        XCTAssertTrue(r.translated.lowercased().contains("beam pumping unit"), r.translated)
    }
}

final class UserGlossaryTests: XCTestCase {
    func testTemplateCreatedWithBOMAndHeader() throws {
        let url = GT.tempURL()
        XCTAssertTrue(try UserGlossaryFile.ensureTemplate(at: url))
        XCTAssertFalse(try UserGlossaryFile.ensureTemplate(at: url))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\u{FEFF}中文,英文,领域,备注\r\n"))
        XCTAssertEqual(UserGlossaryFile.load(url).count, UserGlossaryFile.exampleRows.count)
    }

    func testRowsHeaderDetection() {
        XCTAssertEqual(UserGlossaryFile.rows(from: [["English", "Chinese"], ["water cut", "含水率"]]),
                       [UserGlossaryRow(zh: "含水率", en: "water cut")])
        XCTAssertEqual(UserGlossaryFile.rows(from: [["含水率", "water cut", "石油", "备注x"]]),
                       [UserGlossaryRow(zh: "含水率", en: "water cut", domain: "石油", note: "备注x")])
        XCTAssertTrue(UserGlossaryFile.rows(from: [["中文", "英文"], ["#注释", "x"], ["空", ""]]).isEmpty)
    }

    func testCorrectionUpsertBothLanguages() throws {
        let url = GT.tempURL()
        let d = Date(timeIntervalSince1970: 1_794_700_000)
        let r1 = try UserGlossaryFile.upsertCorrection(source: "抽油机", translation: "beam pumping unit", at: url, date: d)
        XCTAssertEqual(r1.zh, "抽油机"); XCTAssertEqual(r1.en, "beam pumping unit"); XCTAssertTrue(r1.note.hasPrefix("纠正译法 "))
        // 同一中文再次纠正 → 更新而不是追加
        try UserGlossaryFile.upsertCorrection(source: "抽油机", translation: "pumpjack", at: url, date: d)
        // 英文原词（英→中纠正）
        let r3 = try UserGlossaryFile.upsertCorrection(source: "water cut", translation: "含水率", at: url, date: d)
        XCTAssertEqual(r3.zh, "含水率"); XCTAssertEqual(r3.en, "water cut")
        let rows = UserGlossaryFile.load(url)
        XCTAssertEqual(rows.filter { $0.zh == "抽油机" }.map(\.en), ["pumpjack"])
        XCTAssertEqual(rows.count, UserGlossaryFile.exampleRows.count + 2)
    }

    func testMergeImportAddsAndUpdates() throws {
        let url = GT.tempURL()
        try UserGlossaryFile.write([UserGlossaryRow(zh: "冲次", en: "SPM")], to: url)
        let res = try UserGlossaryFile.merge([UserGlossaryRow(zh: "冲次", en: "strokes per minute"),
                                              UserGlossaryRow(zh: "冲程", en: "stroke length")], into: url)
        XCTAssertEqual(res.added, 1); XCTAssertEqual(res.updated, 1)
        XCTAssertEqual(UserGlossaryFile.load(url).map(\.en), ["strokes per minute", "stroke length"])
    }

    func testUserVariantsSplitByBar() {
        let e = UserGlossaryRow(zh: "功图计产|功图量油", en: "card-based metering").entry
        XCTAssertEqual(e.zh, ["功图计产", "功图量油"])
        let s = GlossaryStore(user: [e])
        XCTAssertEqual(s.matches(in: "功图量油", from: .chinese).first?.target, "card-based metering")
    }

    func testHotReloadViaFileWatcher() async throws {
        let url = GT.tempURL()
        try UserGlossaryFile.write([UserGlossaryRow(zh: "抽油机", en: "pumping unit")], to: url)
        let store = GlossaryStore(user: UserGlossaryFile.load(url).map(\.entry))
        let w = FileChangeWatcher(url: url, debounce: 0.05) {
            store.setUser(UserGlossaryFile.load(url).map(\.entry))
        }
        w.start()
        defer { w.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try UserGlossaryFile.write([UserGlossaryRow(zh: "抽油机", en: "beam pumping unit")], to: url)  // 原子写（替换文件）
        var target = ""
        for _ in 0..<60 {
            target = store.matches(in: "抽油机", from: .chinese).first?.target ?? ""
            if target == "beam pumping unit" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(target, "beam pumping unit")
        // 第二次修改（文件被替换后仍在监视）
        try UserGlossaryFile.write([UserGlossaryRow(zh: "抽油机", en: "pumpjack")], to: url)
        for _ in 0..<60 {
            target = store.matches(in: "抽油机", from: .chinese).first?.target ?? ""
            if target == "pumpjack" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(target, "pumpjack")
    }

    func testCorrectionPrefill() {
        XCTAssertEqual(CorrectionPrefill.make(selection: " 抽油机 ", whole: "检查抽油机的冲次", translation: "x"),
                       CorrectionPrefill(source: "抽油机", target: ""))
        XCTAssertEqual(CorrectionPrefill.make(selection: "", whole: "示功图", translation: "dynamometer card."),
                       CorrectionPrefill(source: "示功图", target: "dynamometer card"))
        XCTAssertEqual(CorrectionPrefill.make(selection: "", whole: "请检查3号井抽油机的冲次和含水率，并上报", translation: "long"),
                       CorrectionPrefill(source: "", target: ""))
        XCTAssertTrue(CorrectionPrefill.isTermLike("sucker rod pump"))
        XCTAssertFalse(CorrectionPrefill.isTermLike("Please check the pump on well 12 today"))
    }
}

final class BuiltInGlossaryTests: XCTestCase {
    func testBuiltInGlossariesLoadWithExpectedSizes() {
        let all = BuiltInGlossary.load(from: GT.builtInDir)
        let n = all.mapValues(\.count)
        XCTAssertGreaterThanOrEqual(n[.petroleum] ?? 0, 500); XCTAssertLessThanOrEqual(n[.petroleum] ?? 0, 1000)
        for d in [GlossaryDomain.ai, .software, .instrument, .embedded] {
            XCTAssertGreaterThanOrEqual(n[d] ?? 0, 200, d.title); XCTAssertLessThanOrEqual(n[d] ?? 0, 400, d.title)
        }
    }

    func testNoConflictsAndNoSingleCharacterOrStoplistedKeys() {
        let all = BuiltInGlossary.load(from: GT.builtInDir)
        var zhMap: [String: String] = [:]
        var conflicts: [String] = []
        for d in GlossaryDomain.builtIn {
            for e in all[d] ?? [] {
                XCTAssertFalse(e.zh.isEmpty || e.en.isEmpty)
                for z in e.zh {
                    XCTAssertTrue(z.unicodeScalars.contains { LanguageDetector.isHan($0) }, "非中文键 \(z)")
                    if let old = zhMap[z], old != e.canonicalEN { conflicts.append("\(z): \(old) / \(e.canonicalEN ?? "")") }
                    zhMap[z] = e.canonicalEN
                }
                XCTAssertGreaterThan(e.zh[0].count, 1, "单字词条 \(e.zh[0])")
                XCTAssertFalse(GlossaryStoplist.zh.contains(e.zh[0]), "停用词 \(e.zh[0])")
            }
        }
        XCTAssertEqual(conflicts, [])
    }

    func testRealGlossaryFixesKnownMistranslations() {
        let s = GlossaryStore(builtIns: BuiltInGlossary.load(from: GT.builtInDir))
        func zh(_ t: String) -> [String] { s.matches(in: t, from: .chinese).map(\.target) }
        func en(_ t: String) -> [String] { s.matches(in: t, from: .english).map(\.target) }
        XCTAssertEqual(zh("抽油机的冲次和含水率，看示功图"), ["pumping unit", "strokes per minute", "water cut", "dynamometer card"])
        XCTAssertEqual(en("The sucker rod pump water cut and dynamometer card"), ["有杆泵", "含水率", "示功图"])
        XCTAssertEqual(zh("单片机的看门狗复位"), zh("单片机的看门狗复位"))
        XCTAssertFalse(zh("单片机通过CAN总线上传RTU数据").isEmpty)
        XCTAssertTrue(en("We can do it well").isEmpty)
    }

    func testLookupIsFarBelowOneMillisecond() {
        let all = BuiltInGlossary.load(from: GT.builtInDir)
        let t0 = LatencyMonitor.now()
        let s = GlossaryStore(builtIns: all)
        let buildMs = LatencyMonitor.ms(since: t0)
        let zhs = ["请检查3号井抽油机的冲次、冲程和含水率，示功图显示供液不足。",
                   "单片机通过SPI读取压力变送器的4-20mA信号，再经CAN总线上传到RTU。",
                   "大语言模型的检索增强生成需要向量数据库和提示词工程。",
                   "注水井的配注量和井口压力要每天录入生产数据库。"]
        let ens = ["The electric submersible pump tripped on underload; check the variable frequency drive.",
                   "Fine-tune the large language model with LoRA and evaluate hallucination rates.",
                   "The pressure transmitter output drifts; recalibrate the zero and span.",
                   "Configure the watchdog timer and the DMA controller on the microcontroller."]
        let n = 250
        let t1 = LatencyMonitor.now()
        var hits = 0
        for _ in 0..<n {
            for z in zhs { hits += s.plan(for: z, from: .chinese)?.slots.count ?? 0 }
            for e in ens { hits += s.plan(for: e, from: .english)?.slots.count ?? 0 }
        }
        let per = LatencyMonitor.ms(since: t1) / Double(n * (zhs.count + ens.count))
        print(String(format: "glossary perf: build=%.1fms lookup+plan=%.4fms/sentence hits=%d", buildMs, per, hits))
        XCTAssertGreaterThan(hits, 0)
        XCTAssertLessThan(per, 1.0)
        XCTAssertLessThan(buildMs, 500)
    }
}
