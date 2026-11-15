#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
@testable import IMECore

final class VocabularyTests: XCTestCase {
    private func makeBook(delay: TimeInterval = 0.05, file: URL? = nil) -> (VocabularyBook, URL) {
        let url = file ?? makeTempDir().appendingPathComponent("vocabulary.json")
        let clock = TickClock()
        return (VocabularyBook(fileURL: url, saveDelay: delay, clock: { clock.next() }), url)
    }

    // MARK: 加入 / 计数 / 去重

    func testFirstPlayCreatesEntry() async throws {
        let (book, _) = makeBook()
        let e = await book.recordPlay(english: "Hello", chinese: "你好")
        XCTAssertEqual(e?.english, "Hello"); XCTAssertEqual(e?.chinese, "你好")
        XCTAssertEqual(e?.playCount, 1)
        XCTAssertEqual(e?.firstAddedAt, e?.lastPlayedAt)
    }

    func testRepeatedPlayIncrementsCountWithoutDuplicates() async {
        let (book, _) = makeBook()
        let first = await book.recordPlay(english: "Hello", chinese: "你好")
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        let third = await book.recordPlay(english: "Hello", chinese: "你好")
        let all = await book.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(third?.playCount, 3)
        XCTAssertEqual(third?.firstAddedAt, first?.firstAddedAt)
        XCTAssertGreaterThan(third!.lastPlayedAt, first!.lastPlayedAt)
    }

    func testNormalizationDeduplicates() async {
        let (book, _) = makeBook()
        _ = await book.recordPlay(english: "Hello!", chinese: "你好")
        _ = await book.recordPlay(english: "  hello ", chinese: "你好")
        _ = await book.recordPlay(english: "HELLO", chinese: "你好")
        _ = await book.recordPlay(english: "Good   morning.", chinese: "早上好")
        _ = await book.recordPlay(english: "good morning", chinese: "早上好")
        _ = await book.recordPlay(english: "don\u{2019}t", chinese: "不要")
        _ = await book.recordPlay(english: "don't", chinese: "不要")
        let all = await book.entries(sortedBy: .alphabetical)
        XCTAssertEqual(all.map(\.id), ["don't", "good morning", "hello"])
        XCTAssertEqual(all.first { $0.id == "hello" }?.playCount, 3)
        XCTAssertEqual(all.first { $0.id == "hello" }?.english, "Hello!", "展示文本保留首次加入的写法")
    }

    func testDifferentChineseForSameEnglishAreKept() async {
        let (book, _) = makeBook()
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        let e = await book.recordPlay(english: "Hello", chinese: "您好")
        _ = await book.recordPlay(english: "Hello", chinese: "您好")
        let all = await book.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(e?.chinese, "你好")
        XCTAssertEqual(all.first?.otherChinese, ["您好"])
    }

    func testEmptyOrPunctuationOnlyIgnored() async {
        let (book, _) = makeBook()
        let a = await book.recordPlay(english: "  ", chinese: "x")
        let b = await book.recordPlay(english: "!!!", chinese: "x")
        let all = await book.entries()
        XCTAssertNil(a); XCTAssertNil(b); XCTAssertTrue(all.isEmpty)
    }

    func testConcurrentPlaysAreAllCounted() async {
        let (book, _) = makeBook()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<200 { g.addTask { _ = await book.recordPlay(english: "Hello", chinese: "你好") } }
        }
        let all = await book.entries()
        XCTAssertEqual(all.first?.playCount, 200)
    }

    // MARK: 持久化 / 后台写入

    func testPersistsAcrossInstances() async {
        let (book, url) = makeBook()
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        _ = await book.recordPlay(english: "Thanks", chinese: "谢谢")
        await book.flush()

        let (reloaded, _) = makeBook(file: url)
        let a = await book.entries(sortedBy: .alphabetical)
        let b = await reloaded.entries(sortedBy: .alphabetical)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b.first { $0.id == "hello" }?.playCount, 2)
    }

    func testRecordDoesNotWriteSynchronouslyAndFlushDoes() async {
        let (book, url) = makeBook(delay: 5)         // 很长的防抖：证明 record 本身不落盘
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await book.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let writes = await book.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testDebouncedBackgroundWriteHappensOnItsOwn() async throws {
        let (book, url) = makeBook(delay: 0.05)
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testBurstOfWritesIsCoalesced() async throws {
        let (book, _) = makeBook(delay: 0.1)
        for i in 0..<100 { _ = await book.recordPlay(english: "word \(i % 7)", chinese: "词") }
        try await Task.sleep(nanoseconds: 500_000_000)
        let writes = await book.writeCount
        XCTAssertGreaterThanOrEqual(writes, 1)
        XCTAssertLessThanOrEqual(writes, 3, "100 次点击应被合并成极少次落盘")
    }

    func testFileHasStableJSONSchema() async throws {
        let (book, url) = makeBook()
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        await book.flush()
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["version"] as? Int, 1)
        let entries = obj?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.first?["english"] as? String, "Hello")
        XCTAssertEqual(entries?.first?["playCount"] as? Int, 1)
        XCTAssertNotNil(entries?.first?["lastPlayedAt"] as? String)     // ISO8601 字符串
    }

    func testCorruptFileIsQuarantinedNotOverwritten() async throws {
        let dir = makeTempDir(); let url = dir.appendingPathComponent("vocabulary.json")
        try Data("{ this is not json".utf8).write(to: url)
        let (book, _) = makeBook(file: url)
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        await book.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("vocabulary.corrupt-") }, "坏文件应被改名保留")
        let all = await book.entries()
        XCTAssertEqual(all.count, 1)
    }

    func testRemoveAndRemoveAll() async {
        let (book, _) = makeBook()
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        _ = await book.recordPlay(english: "Thanks", chinese: "谢谢")
        await book.remove(id: "hello")
        let afterRemove = await book.entries()
        XCTAssertEqual(afterRemove.map(\.id), ["thanks"])
        await book.removeAll()
        let afterAll = await book.entries()
        XCTAssertTrue(afterAll.isEmpty)
    }

    // MARK: 导出

    func testCSVExportEscapingAndBOM() async throws {
        let (book, _) = makeBook()
        _ = await book.recordPlay(english: "Hello, \"world\"", chinese: "你好，世界")
        _ = await book.recordPlay(english: "=cmd|calc", chinese: "-危险")
        let out = makeTempDir().appendingPathComponent("v.csv")
        try await book.exportCSV(to: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("english,chinese,other_chinese,play_count,first_added,last_played\r\n"))
        XCTAssertTrue(text.contains("\"Hello, \"\"world\"\"\""))
        XCTAssertTrue(text.contains("'=cmd|calc"), "以 = 开头的单元格要加前缀防公式注入")
        XCTAssertTrue(text.contains("'-危险"))
    }

    func testJSONExportRoundTrips() async throws {
        let (book, _) = makeBook()
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        _ = await book.recordPlay(english: "Hello", chinese: "你好")
        let out = makeTempDir().appendingPathComponent("v.json")
        try await book.exportJSON(to: out)
        let (other, _) = makeBook(file: out)
        let a = await book.entries(), b = await other.entries()
        XCTAssertEqual(a, b)
    }
}

// MARK: - 与发音按钮的集成

@MainActor
final class VocabularyIntegrationTests: XCTestCase {
    private func make(book: VocabularyBook?, speaker: MockSpeaker) -> TranslationCoordinator {
        let p = MockProvider(id: "mock") { _, from, _ in from == .chinese ? "Hello" : "你好" }
        return TranslationCoordinator(service: TranslationService(providers: [p]), speaker: speaker,
                                      debounce: 0, vocabulary: book, monitor: LatencyMonitor())
    }
    private func bookAt(_ url: URL) -> VocabularyBook {
        let clock = TickClock()
        return VocabularyBook(fileURL: url, saveDelay: 0.05, clock: { clock.next() })
    }

    func testClickingPronounceAddsEntryAndCountsPlays() async {
        let url = makeTempDir().appendingPathComponent("v.json")
        let book = bookAt(url); let spk = MockSpeaker()
        let c = make(book: book, speaker: spk)
        c.update(text: "你好"); await c.settle()
        var all = await book.entries()
        XCTAssertTrue(all.isEmpty, "翻译完成本身不得写入单词本")

        c.pronounceTapped(); await c.settleVocabulary()
        all = await book.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.english, "Hello"); XCTAssertEqual(all.first?.chinese, "你好")
        XCTAssertEqual(all.first?.playCount, 1)

        c.pronounceTapped(); c.pronounceTapped(); await c.settleVocabulary()
        all = await book.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.playCount, 3)
        XCTAssertEqual(spk.spoken, ["Hello", "Hello", "Hello"])
    }

    // 新需求（2026-11-14）：英→中时点击英文原文的 🔊 也记入单词本（英文=原文，中文=译文）。
    func testEnglishSourceClickAddsEntry() async {
        let book = bookAt(makeTempDir().appendingPathComponent("v.json"))
        let spk = MockSpeaker()
        let c = make(book: book, speaker: spk)
        c.update(text: "hello"); await c.settle()
        var all = await book.entries()
        XCTAssertTrue(all.isEmpty, "只翻译不点击不得写入单词本")
        c.pronounceTapped(); await c.settleVocabulary()
        all = await book.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.english, "hello"); XCTAssertEqual(all.first?.chinese, "你好")
        XCTAssertEqual(all.first?.playCount, 1)
        c.pronounceTapped(); await c.settleVocabulary()
        all = await book.entries()
        XCTAssertEqual(all.count, 1); XCTAssertEqual(all.first?.playCount, 2)
        XCTAssertEqual(spk.spoken, ["hello", "hello"])
    }

    func testEnglishSourceAndChineseSourceShareDedupedEntry() async {
        let book = bookAt(makeTempDir().appendingPathComponent("v.json"))
        let c = make(book: book, speaker: MockSpeaker())
        c.update(text: "你好"); await c.settle(); c.pronounceTapped()     // 记 "Hello" / 你好
        c.update(text: "hello"); await c.settle(); c.pronounceTapped()    // 记 "hello" / 你好 → 同一条
        await c.settleVocabulary()
        let all = await book.entries()
        XCTAssertEqual(all.count, 1, "大小写/方向不同的同一英文只保留一条")
        XCTAssertEqual(all.first?.playCount, 2)
        XCTAssertEqual(all.first?.chinese, "你好")
        XCTAssertEqual(all.first?.otherChinese, [])
    }

    func testEnglishSourceNoClickNoEntry() async throws {
        let url = makeTempDir().appendingPathComponent("v.json")
        let book = bookAt(url)
        let c = make(book: book, speaker: MockSpeaker())
        for t in ["hello", "good morning", "thanks"] { c.update(text: t); await c.settle() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let all = await book.entries()
        XCTAssertTrue(all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNoClickNoFileEvenAfterManyTranslations() async throws {
        let url = makeTempDir().appendingPathComponent("v.json")
        let book = bookAt(url)
        let c = make(book: book, speaker: MockSpeaker())
        for t in ["你好", "谢谢", "再见"] { c.update(text: t); await c.settle() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPronounceTapStaysFastWithLargeBook() async throws {
        let url = makeTempDir().appendingPathComponent("v.json")
        let book = bookAt(url)
        for i in 0..<5000 { _ = await book.recordPlay(english: "word number \(i)", chinese: "词 \(i)") }
        await book.flush()

        let spk = MockSpeaker()
        let c = make(book: book, speaker: spk)
        c.update(text: "你好"); await c.settle()

        let t0 = LatencyMonitor.now()
        c.pronounceTapped()                                    // 主线程同步部分
        let ms = LatencyMonitor.ms(since: t0)
        XCTAssertLessThan(ms, 5.0, "点击发音在主线程的开销必须 < 5ms，不受单词本大小影响")
        await c.settleVocabulary()
        let all = await book.entries()
        XCTAssertEqual(all.count, 5001)
    }

    func testEnglishSourceTapStaysFastWithLargeBook() async throws {
        let url = makeTempDir().appendingPathComponent("v.json")
        let book = bookAt(url)
        for i in 0..<5000 { _ = await book.recordPlay(english: "word number \(i)", chinese: "词 \(i)") }
        await book.flush()

        let spk = MockSpeaker()
        let c = make(book: book, speaker: spk)
        c.update(text: "hello"); await c.settle()

        let t0 = LatencyMonitor.now()
        c.pronounceTapped()
        let ms = LatencyMonitor.ms(since: t0)
        print("english-source pronounceTapped main-thread: \(ms) ms")
        XCTAssertLessThan(ms, 5.0, "英文原文点击发音在主线程的开销必须 < 5ms")
        XCTAssertEqual(spk.spoken, ["hello"])
        await c.settleVocabulary()
        let all = await book.entries()
        XCTAssertEqual(all.count, 5001)
    }
}
