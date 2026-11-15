#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation   // FIX(CLT): XCTest 会隐式导出 Foundation，兼容层不会，所以显式导入
@testable import IMECore

final class CompositionBufferTests: XCTestCase {
    func testOnlyLettersStartComposition() {
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.character("1")), .passThrough)
        XCTAssertEqual(b.handle(.character(" ")), .passThrough)
        XCTAssertEqual(b.handle(.character(",")), .passThrough)
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.handle(.character("h")), .update)
        XCTAssertEqual(b.text, "h")
    }

    func testSentenceAccumulatesWithSpacesAndPunctuation() {
        var b = CompositionBuffer()
        for c in "Hello, world 2" { _ = b.handle(.character(String(c))) }
        XCTAssertEqual(b.text, "Hello, world 2")
    }

    func testCommitCancelKeys() {
        var b = CompositionBuffer()
        _ = b.handle(.character("a"))
        XCTAssertEqual(b.handle(.returnKey), .commitOriginal)
        XCTAssertEqual(b.handle(.tab), .commitTranslation)
        XCTAssertEqual(b.handle(.escape), .cancel)
        b.clear()
        XCTAssertEqual(b.handle(.returnKey), .passThrough)
        XCTAssertEqual(b.handle(.tab), .passThrough)
        XCTAssertEqual(b.handle(.escape), .passThrough)
        XCTAssertEqual(b.handle(.delete), .passThrough)
    }

    func testDelete() {
        var b = CompositionBuffer()
        _ = b.handle(.character("a")); _ = b.handle(.character("b"))
        XCTAssertEqual(b.handle(.delete), .update); XCTAssertEqual(b.text, "a")
        XCTAssertEqual(b.handle(.delete), .cancel); XCTAssertTrue(b.isEmpty)
    }

    func testModifiedAndOtherKeys() {
        var b = CompositionBuffer()
        XCTAssertEqual(b.handle(.modified), .passThrough)
        XCTAssertEqual(b.handle(.other), .passThrough)
        _ = b.handle(.character("a"))
        XCTAssertEqual(b.handle(.modified), .flushThenPass)
        XCTAssertEqual(b.handle(.other), .flushThenPass)
    }
}
