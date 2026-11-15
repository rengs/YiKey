#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
@testable import IMECore

final class LanguageDetectorTests: XCTestCase {
    func testChinese() {
        XCTAssertEqual(LanguageDetector.detect("你好"), .chinese)
        XCTAssertEqual(LanguageDetector.detect("今天天气很好，我们去公园吧。"), .chinese)
        XCTAssertEqual(LanguageDetector.detect("繁體中文也可以"), .chinese)
    }

    func testEnglish() {
        XCTAssertEqual(LanguageDetector.detect("hello"), .english)
        XCTAssertEqual(LanguageDetector.detect("How are you doing today?"), .english)
        XCTAssertEqual(LanguageDetector.detect("don't stop"), .english)
        XCTAssertEqual(LanguageDetector.detect("state-of-the-art"), .english)
        XCTAssertEqual(LanguageDetector.detect("iPhone15 review"), .english)
    }

    func testMixedTextFollowsDominantScript() {
        XCTAssertEqual(LanguageDetector.detect("iPhone 手机"), .chinese)          // 汉字 2 >= 单词 1
        XCTAssertEqual(LanguageDetector.detect("Hello 你好"), .chinese)
        XCTAssertEqual(LanguageDetector.detect("你好，world"), .chinese)
        XCTAssertEqual(LanguageDetector.detect("I want 苹果 juice please"), .english) // 汉字 2 < 单词 4
    }

    func testUnknown() {
        XCTAssertEqual(LanguageDetector.detect(""), .unknown)
        XCTAssertEqual(LanguageDetector.detect("   \n"), .unknown)
        XCTAssertEqual(LanguageDetector.detect("12345"), .unknown)
        XCTAssertEqual(LanguageDetector.detect("!!! ???"), .unknown)
        XCTAssertEqual(LanguageDetector.detect("こんにちは"), .unknown)
        XCTAssertEqual(LanguageDetector.detect("東京タワー"), .unknown)           // 含假名 → 不支持
    }
}
