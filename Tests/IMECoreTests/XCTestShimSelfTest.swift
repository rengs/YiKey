// FIX(CLT): 兼容层自检 —— 证明 XCTAssert* 失败时确实会让测试失败（否则 withKnownIssue 会报错）。
#if !canImport(XCTest)
import Testing

@Suite("XCTestShimSelfTest") struct XCTestShimSelfTest {
    @Test func failingAssertionsAreRecorded() {
        withKnownIssue { XCTAssertEqual(1, 2) }
        withKnownIssue { XCTAssertTrue(false) }
        withKnownIssue { XCTAssertLessThan(6.0, 5.0) }
        withKnownIssue { XCTAssertNil(Optional(1)) }
        withKnownIssue { XCTFail("boom") }
        withKnownIssue { _ = try XCTUnwrap(Optional<Int>.none) }
    }
    @Test func passingAssertionsRecordNothing() throws {
        XCTAssertEqual(1, 1); XCTAssertTrue(true); XCTAssertLessThan(4.0, 5.0)
        XCTAssertEqual(0.1 + 0.2, 0.3, accuracy: 1e-9); XCTAssertNotNil(Optional(1))
        XCTAssertEqual(try XCTUnwrap(Optional(3)), 3)
    }
}
#endif
