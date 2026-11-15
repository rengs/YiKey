#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
import CryptoKit
@testable import IMECore

final class TranslationServiceTests: XCTestCase {

    // MARK: 路由

    func testChineseInputTranslatesToEnglish() async throws {
        let p = MockProvider(id: "a") { _, _, _ in "Hello" }
        let r = try await TranslationService(providers: [p]).translate("你好")
        XCTAssertEqual(r.translated, "Hello")
        XCTAssertEqual(r.source, .chinese); XCTAssertEqual(r.target, .english)
        XCTAssertEqual(p.calls, [.init(text: "你好", from: .chinese, to: .english)])
    }

    func testEnglishInputTranslatesToChinese() async throws {
        let p = MockProvider(id: "a") { _, _, _ in "你好" }
        let r = try await TranslationService(providers: [p]).translate("  hello \n")
        XCTAssertEqual(r.target, .chinese)
        XCTAssertEqual(p.calls.first?.text, "hello")      // 已裁剪
    }

    func testEmptyAndUnknownThrow() async {
        let svc = TranslationService(providers: [MockProvider(id: "a") { _, _, _ in "x" }])
        do { _ = try await svc.translate("  "); XCTFail() } catch { XCTAssertEqual(error as? TranslationError, .emptyInput) }
        do { _ = try await svc.translate("12345"); XCTFail() } catch { XCTAssertEqual(error as? TranslationError, .unsupportedLanguage) }
    }

    // MARK: 回退链

    func testFallsBackWhenFirstProviderThrows() async throws {
        let a = MockProvider(id: "apple") { _, _, _ in throw TranslationError.providerFailed("boom") }
        let b = MockProvider(id: "online") { _, _, _ in "Hi" }
        let r = try await TranslationService(providers: [a, b]).translate("你好")
        XCTAssertEqual(r.providerID, "online")
        XCTAssertEqual(a.calls.count, 1); XCTAssertEqual(b.calls.count, 1)
    }

    func testSkipsUnavailableProvider() async throws {
        let a = MockProvider(id: "apple", available: false) { _, _, _ in "never" }
        let b = MockProvider(id: "online") { _, _, _ in "Hi" }
        let r = try await TranslationService(providers: [a, b]).translate("你好")
        XCTAssertEqual(r.providerID, "online")
        XCTAssertTrue(a.calls.isEmpty)
    }

    func testTimeoutFallsBack() async throws {
        let slow = MockProvider(id: "slow") { _, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return "late" }
        let fast = MockProvider(id: "fast") { _, _, _ in "ok" }
        let r = try await TranslationService(providers: [slow, fast], timeout: 0.1).translate("你好")
        XCTAssertEqual(r.providerID, "fast")
    }

    func testAllFailThrowsLastError() async {
        let a = MockProvider(id: "a") { _, _, _ in throw TranslationError.providerFailed("a") }
        let b = MockProvider(id: "b") { _, _, _ in throw TranslationError.providerFailed("b") }
        do { _ = try await TranslationService(providers: [a, b]).translate("你好"); XCTFail() }
        catch { XCTAssertEqual(error as? TranslationError, .providerFailed("b")) }
    }

    func testNoProvidersThrows() async {
        do { _ = try await TranslationService(providers: []).translate("你好"); XCTFail() }
        catch { XCTAssertEqual(error as? TranslationError, .noProviderAvailable) }
    }

    func testCancellationDoesNotFallBack() async throws {
        let a = MockProvider(id: "a") { _, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return "x" }
        let b = MockProvider(id: "b") { _, _, _ in "y" }
        let svc = TranslationService(providers: [a, b])
        let t = Task { try await svc.translate("你好") }
        try await Task.sleep(nanoseconds: 100_000_000)
        t.cancel()
        let outcome = await t.result
        if case .success = outcome { XCTFail("应被取消") }
        XCTAssertTrue(b.calls.isEmpty, "取消后不应去调用备用接口")
    }

    func testCacheAvoidsSecondCall() async throws {
        let p = MockProvider(id: "a") { _, _, _ in "Hello" }
        let svc = TranslationService(providers: [p])
        _ = try await svc.translate("你好"); _ = try await svc.translate("你好")
        XCTAssertEqual(p.calls.count, 1)
    }

    // MARK: 在线备用接口（百度）

    func testBaiduRequestSignatureAndParsing() async throws {
        let http = StubHTTP(body: #"{"from":"zh","to":"en","trans_result":[{"src":"你好","dst":"Hello"}]}"#)
        let p = BaiduTranslateProvider(appID: "APP", secret: "SEC", http: http, makeSalt: { "12345" })
        let out = try await p.translate("你好", from: .chinese, to: .english)
        XCTAssertEqual(out, "Hello")

        let body = String(data: try XCTUnwrap(http.lastRequest?.httpBody), encoding: .utf8)!
        let expected = Insecure.MD5.hash(data: Data("APP你好12345SEC".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(body.contains("sign=\(expected)"))
        XCTAssertTrue(body.contains("from=zh")); XCTAssertTrue(body.contains("to=en"))
        XCTAssertTrue(body.contains("q=%E4%BD%A0%E5%A5%BD"))
        XCTAssertEqual(http.lastRequest?.httpMethod, "POST")
    }

    func testBaiduErrorResponseThrows() async {
        let http = StubHTTP(body: #"{"error_code":"54001","error_msg":"Invalid Sign"}"#)
        let p = BaiduTranslateProvider(appID: "A", secret: "S", http: http, makeSalt: { "1" })
        do { _ = try await p.translate("hi", from: .english, to: .chinese); XCTFail() }
        catch { guard case .providerFailed(let m) = error as? TranslationError else { return XCTFail() }
                XCTAssertTrue(m.contains("54001")) }
    }

    func testLibreTranslateParsing() async throws {
        let http = StubHTTP(body: #"{"translatedText":"你好"}"#)
        let p = LibreTranslateProvider(baseURL: URL(string: "https://example.test")!, http: http)
        let out = try await p.translate("hello", from: .english, to: .chinese)
        XCTAssertEqual(out, "你好")
        XCTAssertEqual(http.lastRequest?.url?.path, "/translate")
    }

    // MARK: 设置工厂：默认不联网

    func testOnlineFactoryDisabledByDefault() {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        d.set("id", forKey: IMESettings.baiduAppID); d.set("sec", forKey: IMESettings.baiduSecret)
        XCTAssertTrue(OnlineProviderFactory.make(defaults: d).isEmpty)       // 未启用 → 空
        d.set(true, forKey: IMESettings.onlineFallbackEnabled)
        XCTAssertEqual(OnlineProviderFactory.make(defaults: d).map(\.id), ["baidu"])
        d.removeObject(forKey: IMESettings.baiduSecret)
        XCTAssertTrue(OnlineProviderFactory.make(defaults: d).isEmpty)       // 缺凭据 → 空
    }
}
