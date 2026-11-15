// FIX(CLT): 本机只装了 Command Line Tools，没有 XCTest.framework，但带有 swift-testing（Testing.framework）。
// 这个文件提供一个最小的 XCTest 兼容层，把 XCTAssert* 映射为 swift-testing 的 Issue.record，
// 让原有 XCTest 风格的测试源码无需改写即可用 `swift test` 运行。装了完整 Xcode 时（canImport(XCTest)）自动不启用。
#if !canImport(XCTest)
import Foundation
import Testing

open class XCTestCase {
    public required init() {}

    /// 与 XCTest.measure 类似：运行 10 次并打印每次耗时（毫秒）
    public func measure(_ block: () -> Void) {
        var times: [Double] = []
        for _ in 0..<10 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            block()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        print(String(format: "measure: avg %.3f ms, min %.3f ms, max %.3f ms (10 runs)", avg, times.min()!, times.max()!))
    }
}

public struct XCTUnwrapError: Error, CustomStringConvertible {
    public let description: String
}

@inline(__always)
private func fail(_ what: String, _ message: String, _ loc: SourceLocation) {
    Issue.record(Comment(rawValue: message.isEmpty ? what : "\(what) — \(message)"), sourceLocation: loc)
}

private func eval<T>(_ e: () throws -> T, _ loc: SourceLocation) -> T? {
    do { return try e() } catch { Issue.record(error, sourceLocation: loc); return nil }
}

public func XCTFail(_ message: String = "", fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    fail("XCTFail", message, sourceLocation)
}

public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                          fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    if let v = eval(e, sourceLocation), !v { fail("XCTAssertTrue failed", message(), sourceLocation) }
}

public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                           fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    if let v = eval(e, sourceLocation), v { fail("XCTAssertFalse failed", message(), sourceLocation) }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    guard let x = eval(a, sourceLocation), let y = eval(b, sourceLocation) else { return }
    if x != y { fail("XCTAssertEqual failed: (\(x)) is not equal to (\(y))", message(), sourceLocation) }
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             accuracy: T, _ message: @autoclosure () -> String = "",
                                             fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    guard let x = eval(a, sourceLocation), let y = eval(b, sourceLocation) else { return }
    if abs(x - y) > accuracy { fail("XCTAssertEqual failed: (\(x)) is not equal to (\(y)) +/- (\(accuracy))", message(), sourceLocation) }
}

public func XCTAssertNil(_ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                         fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    if let v = eval(a, sourceLocation), let some = v { fail("XCTAssertNil failed: \"\(some)\"", message(), sourceLocation) }
}

public func XCTAssertNotNil(_ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                            fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    if let v = eval(a, sourceLocation), v == nil { fail("XCTAssertNotNil failed", message(), sourceLocation) }
}

private func cmp<T: Comparable>(_ name: String, _ op: (T, T) -> Bool, _ sym: String,
                                _ a: () throws -> T, _ b: () throws -> T, _ message: String, _ loc: SourceLocation) {
    guard let x = eval(a, loc), let y = eval(b, loc) else { return }
    if !op(x, y) { fail("\(name) failed: (\(x)) is not \(sym) (\(y))", message, loc) }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    cmp("XCTAssertLessThan", (<), "less than", a, b, message(), sourceLocation)
}
public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                    _ message: @autoclosure () -> String = "",
                                                    fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    cmp("XCTAssertLessThanOrEqual", (<=), "less than or equal to", a, b, message(), sourceLocation)
}
public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    cmp("XCTAssertGreaterThan", (>), "greater than", a, b, message(), sourceLocation)
}
public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                       _ message: @autoclosure () -> String = "",
                                                       fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    cmp("XCTAssertGreaterThanOrEqual", (>=), "greater than or equal to", a, b, message(), sourceLocation)
}

public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                         fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) throws -> T {
    let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    if let v = try e() { return v }
    let m = message()
    fail("XCTUnwrap failed: expected non-nil value of type \"\(T.self)\"", m, sourceLocation)
    throw XCTUnwrapError(description: m.isEmpty ? "XCTUnwrap failed" : m)
}
#endif
