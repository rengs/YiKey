import AppKit
import UniformTypeIdentifiers
import IMECore

/// 术语表：内置五套（App 资源）+ 用户词表（~/Library/Application Support/TranslateIME/glossary.csv，热重载）。
/// 所有读写/建索引都在后台队列，绝不在按键路径上。
@MainActor
final class GlossaryManager {
    nonisolated static let masterKey = "glossaryEnabled"
    let store: GlossaryStore
    /// 用户词表位置（自测可用环境变量 TRANSLATEIME_GLOSSARY_FILE 指到临时文件，避免改动真实词表）
    let userURL: URL = ProcessInfo.processInfo.environment["TRANSLATEIME_GLOSSARY_FILE"]
        .map { URL(fileURLWithPath: $0) } ?? UserGlossaryFile.defaultURL
    private var watcher: FileChangeWatcher?
    private let io = DispatchQueue(label: "TranslateIME.glossary.io", qos: .utility)

    init() {
        let d = UserDefaults.standard
        let enabled = Set(GlossaryDomain.builtIn.filter { IMESettings.flag($0.settingsKey, defaults: d) })
        store = GlossaryStore(enabled: enabled)
        store.setMaster(IMESettings.flag(Self.masterKey, defaults: d))
    }

    nonisolated static var builtInDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("Glossaries") }

    /// 启动时在后台加载；完成后建立文件监视（用户改了 CSV 自动重新加载）
    func start() {
        let store = store, url = userURL
        io.async {
            if let dir = Self.builtInDirectory { store.setBuiltIns(BuiltInGlossary.load(from: dir)) }
            _ = try? UserGlossaryFile.ensureTemplate(at: url)
            store.setUser(UserGlossaryFile.load(url).map(\.entry))
            DispatchQueue.main.async { self.startWatching() }
        }
    }

    private func startWatching() {
        let store = store, url = userURL
        let w = FileChangeWatcher(url: url) {
            store.setUser(UserGlossaryFile.load(url).map(\.entry))
            PlacementLog.write("glossary reload user=\(store.count(.user))")
        }
        w.start()
        watcher = w
    }

    func reloadAll(completion: (@MainActor (String) -> Void)? = nil) {
        let store = store, url = userURL
        io.async {
            if let dir = Self.builtInDirectory { store.setBuiltIns(BuiltInGlossary.load(from: dir)) }
            store.setUser(UserGlossaryFile.load(url).map(\.entry))
            let msg = self.summaryText(store)
            DispatchQueue.main.async { completion?(msg) }
        }
    }

    nonisolated func summaryText(_ s: GlossaryStore) -> String {
        (GlossaryDomain.builtIn + [.user]).map { "\($0.title)：\(s.count($0)) 条" }.joined(separator: "\n")
    }

    func setDomain(_ d: GlossaryDomain, on: Bool) {
        UserDefaults.standard.set(on, forKey: d.settingsKey)
        let store = store
        io.async { store.setEnabled(d, on) }
    }

    func setMaster(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.masterKey)
        store.setMaster(on)
    }

    func openUserFile() {
        _ = try? UserGlossaryFile.ensureTemplate(at: userURL)
        NSWorkspace.shared.open(userURL)
    }

    /// 纠正译法：写入用户词表并立即重建索引（完成后再回调，调用方据此重新翻译）
    func saveCorrection(source: String, translation: String) async throws -> UserGlossaryRow {
        let store = store, url = userURL
        return try await withCheckedThrowingContinuation { cont in
            io.async {
                do {
                    let row = try UserGlossaryFile.upsertCorrection(source: source, translation: translation, at: url)
                    store.setUser(UserGlossaryFile.load(url).map(\.entry))
                    cont.resume(returning: row)
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: 导入（CSV / TSV / XLSX）

    func importFile() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.title = "导入词表（CSV / TSV / XLSX）"
        p.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText,
                                 UTType(filenameExtension: "xlsx") ?? .data, UTType(filenameExtension: "tsv") ?? .data]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let file = p.url else { return }
        let store = store, url = userURL
        io.async {
            let result: String
            do {
                let rows = try Self.readTable(file)
                let parsed = UserGlossaryFile.rows(from: rows)
                let (added, updated) = try UserGlossaryFile.merge(parsed, into: url)
                store.setUser(UserGlossaryFile.load(url).map(\.entry))
                result = "已导入 \(parsed.count) 条：新增 \(added)，更新 \(updated)。\n我的词表现有 \(store.count(.user)) 条。"
            } catch {
                result = "导入失败：\(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                let a = NSAlert(); a.messageText = "导入词表"; a.informativeText = result; a.runModal()
            }
        }
    }

    enum ImportError: LocalizedError {
        case unreadable, xlsx(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取文件（请使用 UTF-8 编码的 CSV/TSV，或 .xlsx）"
            case .xlsx(let m): return "读取 xlsx 失败：\(m)"
            }
        }
    }

    nonisolated static func readTable(_ file: URL) throws -> [[String]] {
        if file.pathExtension.lowercased() == "xlsx" { return try readXLSX(file) }
        let data = try Data(contentsOf: file)
        // UTF-8（含 BOM）优先；不是 UTF-8 时按 GB18030 再试（Excel 中文版另存的 CSV 常见）
        var text = String(data: data, encoding: .utf8)
        if text == nil {
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            text = String(data: data, encoding: String.Encoding(rawValue: gb))
        }
        guard let t = text else { throw ImportError.unreadable }
        return DelimitedText.parse(t, delimiter: file.pathExtension.lowercased() == "tsv" ? "\t" : nil)
    }

    /// 用系统自带的 /usr/bin/unzip 读出第一张工作表与共享字符串
    nonisolated static func readXLSX(_ file: URL) throws -> [[String]] {
        func unzip(_ args: [String]) throws -> Data {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        }
        let list = String(decoding: try unzip(["-Z1", file.path]), as: UTF8.self).split(separator: "\n").map(String.init)
        guard let sheet = list.filter({ $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") })
            .sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }).first else {
            throw ImportError.xlsx("找不到工作表")
        }
        let shared = list.contains("xl/sharedStrings.xml")
            ? XLSXSheet.sharedStrings(try unzip(["-p", file.path, "xl/sharedStrings.xml"])) : []
        return XLSXSheet.rows(sheet: try unzip(["-p", file.path, sheet]), shared: shared)
    }
}

/// 诊断：对比“直接翻译”与“术语保护后的翻译”（只用内置词表，不读用户词表）
struct GlossaryProbeCompare {
    let store: GlossaryStore

    static func make() -> GlossaryProbeCompare? {
        guard let dir = GlossaryManager.builtInDirectory else { return nil }
        return GlossaryProbeCompare(store: GlossaryStore(builtIns: BuiltInGlossary.load(from: dir)))
    }

    func compare(dir: String, source: String, raw: String, translate: (String) async -> String) async -> String {
        let from: TextLanguage = dir == "zh" ? .chinese : .english
        let t0 = LatencyMonitor.now()
        guard let plan = store.plan(for: source, from: from) else {
            return [dir, source, raw, "-", raw, "terms=0"].joined(separator: "\t")
        }
        let lookupMs = LatencyMonitor.ms(since: t0)
        if let direct = plan.singleTermOutput {
            return [dir, source, raw, plan.injectedText, direct, "terms=1 mode=single"].joined(separator: "\t")
        }
        let out1 = await translate(plan.injectedText)
        var best = plan.acceptInjected(out1)
        var extra = ""
        if !best.lost.isEmpty {
            let out2 = await translate(plan.placeholderText)
            let r2 = plan.restorePlaceholders(out2)
            extra = " ph=[\(out2)]"
            if r2.lost.count < best.lost.count { best = r2 }
        }
        let terms = plan.slots.map { "\($0.source)→\($0.target)" }.joined(separator: "; ")
        return [dir, source, raw, plan.injectedText, best.text,
                String(format: "terms=%d mode=%@ lost=%d lookupMs=%.3f [%@]%@", plan.slots.count, best.mode, best.lost.count,
                       lookupMs, terms, extra)].joined(separator: "\t")
    }
}

/// --selftest-correct <out>：在真实面板里走一遍“纠正译法”（需 TRANSLATEIME_GLOSSARY_FILE 指向临时词表）。
/// 只操作本进程自己的面板，不向任何应用发送按键、不切换系统输入源。
@MainActor
enum CorrectionSelfTest {
    static func run(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--selftest-correct"), i + 1 < args.count else { return 2 }
        let out = args[i + 1]
        guard ProcessInfo.processInfo.environment["TRANSLATEIME_GLOSSARY_FILE"] != nil else { return 3 }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var log: [String] = []
        func flush() { try? (log.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func pump(until c: () -> Bool, _ t: Double) {
            let end = Date().addingTimeInterval(t)
            while !c() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        let ctx = AppContext.shared
        ctx.glossary.start()
        pump(until: { ctx.glossary.store.count(.petroleum) > 0 }, 10)
        log.append("loaded " + ctx.glossary.summaryText(ctx.glossary.store).replacingOccurrences(of: "\n", with: " | "))
        let panel = ctx.panel
        panel.skipInputSourceSwitch = true
        let text = "请检查3号井抽油机的冲次和含水率。"
        panel.showTranslator(prefill: text, context: nil, returnTo: nil)
        pump(until: { panel.selfTestTranslation != nil }, 20)
        log.append("before=\(panel.selfTestTranslation ?? "-")")
        log.append("focusBefore input=\(panel.selfTestFirstResponderIsInput)")
        // 只纠正“抽油机”：选中输入框里的这个词后点“纠正译法”
        panel.selfTestSelect("抽油机")
        panel.beginCorrection()
        pump(0.3)
        log.append("editor open=\(panel.vm.correcting) prefill=\(panel.vm.correctionSource)|\(panel.vm.correctionTarget)")
        panel.vm.correctionTarget = "beam pumping unit"
        let t0 = Date()
        panel.saveCorrection()
        pump(until: { (panel.selfTestTranslation ?? "").contains("beam pumping unit") }, 20)
        log.append(String(format: "after=%@ (%.0f ms)", panel.selfTestTranslation ?? "-", Date().timeIntervalSince(t0) * 1000))
        log.append("editor closed=\(!panel.vm.correcting) focusAfter input=\(panel.selfTestFirstResponderIsInput)")
        log.append("userCount=\(ctx.glossary.store.count(.user))")
        let csv = (try? String(contentsOf: ctx.glossary.userURL, encoding: .utf8)) ?? ""
        let bom = ((try? Data(contentsOf: ctx.glossary.userURL)) ?? Data()).prefix(3) == Data([0xEF, 0xBB, 0xBF])
        log.append("csvHasBOM=\(bom) csvLines=" + csv.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ⏎ "))
        panel.hide()
        flush()
        return 0
    }
}
