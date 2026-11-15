#if canImport(XCTest)
import XCTest   // FIX(CLT): 无 XCTest 时由 XCTestShim.swift 提供兼容层
#endif
import Foundation
import CoreGraphics
@testable import IMECore

/// 可编程的 AX mock：记录调用次数，授权状态可随时改变
final class MockAX: AXAnchorQuerying, @unchecked Sendable {
    var trusted = true
    var selection: CGRect?, caret: CGRect?, field: CGRect?, window: CGRect?
    private(set) var calls: [String] = []
    func isTrusted() -> Bool { calls.append("trust"); return trusted }
    func selectionBounds(pid: pid_t) -> CGRect? { calls.append("selection"); return selection }
    func caretBounds(pid: pid_t) -> CGRect? { calls.append("caret"); return caret }
    func focusedElementFrame(pid: pid_t) -> CGRect? { calls.append("field"); return field }
    func focusedWindowFrame(pid: pid_t) -> CGRect? { calls.append("window"); return window }
}

final class AnchorChainTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    private var screens: [CGRect] { [screen] }
    private var pairs: [(frame: CGRect, visible: CGRect)] { [(screen, visible)] }
    private let size = CGSize(width: 440, height: 183)
    private let mouse = CGPoint(x: 700, y: 500)

    private func run(_ ax: MockAX, imk: CGRect? = nil, mouse: CGPoint? = CGPoint(x: 700, y: 500), pid: pid_t? = 42) -> (AnchorInputs, PanelAnchor) {
        let i = AnchorChain.gather(ax: ax, pid: pid, imkCaret: imk, mouse: mouse, screens: screens)
        return (i, AnchorChain.choose(i, screens: screens))
    }

    func testSelectionWinsAndShortCircuits() {
        let ax = MockAX()
        ax.selection = CGRect(x: 200, y: 600, width: 300, height: 18)
        ax.caret = CGRect(x: 10, y: 10, width: 1, height: 18)
        let (_, a) = run(ax)
        XCTAssertEqual(a, .rect(CGRect(x: 200, y: 600, width: 300, height: 18), .selection))
        XCTAssertEqual(ax.calls, ["trust", "selection"], "找到选区后不再做多余的 AX 调用")
    }

    func testCaretWhenNoSelection() {
        let ax = MockAX(); ax.caret = CGRect(x: 300, y: 400, width: 1, height: 18)
        XCTAssertEqual(run(ax).1.strategy, .caret)
        XCTAssertEqual(ax.calls, ["trust", "selection", "caret"])
    }

    func testFieldWhenNoCaretAndTallFieldRejected() {
        let ax = MockAX(); ax.field = CGRect(x: 300, y: 100, width: 600, height: 40)
        XCTAssertEqual(run(ax).1, .rect(CGRect(x: 300, y: 100, width: 600, height: 40), .field))
        let ax2 = MockAX(); ax2.field = CGRect(x: 0, y: 100, width: 800, height: 300)   // 大文本区域/网页
        XCTAssertEqual(run(ax2).1, .mouse(mouse), "大区域不当作输入框，退到鼠标")
    }

    func testIMKCaretUsedWhenAXHasNothing() {
        let ax = MockAX()
        let imk = CGRect(x: 100, y: 300, width: 1, height: 16)
        XCTAssertEqual(run(ax, imk: imk).1, .rect(imk, .caret))
    }

    func testUntrustedSkipsAllAXAndUsesMouse() {
        let ax = MockAX(); ax.trusted = false
        ax.selection = CGRect(x: 200, y: 600, width: 300, height: 18)
        let (i, a) = run(ax)
        XCTAssertFalse(i.trusted)
        XCTAssertEqual(a, .mouse(mouse))
        XCTAssertEqual(ax.calls, ["trust"], "未授权时不做任何 AX 调用")
    }

    func testTrustCheckedEveryTimeNotCached() {
        let ax = MockAX(); ax.trusted = false
        ax.selection = CGRect(x: 200, y: 600, width: 300, height: 18)
        XCTAssertEqual(run(ax).1.strategy, .mouse)
        ax.trusted = true                      // 用户刚刚授权（进程不重启）
        XCTAssertEqual(run(ax).1.strategy, .selection)
        XCTAssertEqual(ax.calls.filter { $0 == "trust" }.count, 2)
    }

    func testUnusableRectsIgnored() {
        let ax = MockAX()
        ax.selection = CGRect(x: 9000, y: 9000, width: 10, height: 18)    // 屏幕外
        ax.caret = .zero
        XCTAssertEqual(run(ax).1.strategy, .mouse)
    }

    func testWindowWhenMouseUnavailable() {
        let ax = MockAX(); ax.window = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let (i, a) = run(ax, mouse: CGPoint(x: -5000, y: -5000))
        XCTAssertEqual(i.window, CGRect(x: 100, y: 100, width: 1000, height: 700))
        XCTAssertEqual(a, .window(CGRect(x: 100, y: 100, width: 1000, height: 700)))
    }

    func testFallbackWhenNothing() {
        let ax = MockAX(); ax.trusted = false
        XCTAssertEqual(run(ax, mouse: nil).1, .fallback)
        XCTAssertNil(AnchorChain.topLeft(for: .fallback, size: size, screens: pairs))
    }

    func testNoPidMeansNoAX() {
        let ax = MockAX(); ax.selection = CGRect(x: 200, y: 600, width: 300, height: 18)
        XCTAssertEqual(run(ax, pid: nil).1.strategy, .mouse)
        XCTAssertEqual(ax.calls, ["trust"])
    }

    // MARK: 位置

    func testMouseBelowRight() {
        let tl = AnchorChain.topLeft(for: .mouse(CGPoint(x: 700, y: 500)), size: size, screens: pairs)!
        XCTAssertEqual(tl.x, 712)                         // 鼠标右侧 12pt
        XCTAssertEqual(tl.y, 490)                         // 鼠标下方 10pt
    }

    func testMouseNearBottomRightIsClampedAndFlipped() {
        let tl = AnchorChain.topLeft(for: .mouse(CGPoint(x: 1430, y: 90)), size: size, screens: pairs)!
        XCTAssertEqual(tl.x, 1440 - 8 - 440, "不出右边")
        XCTAssertGreaterThan(tl.y - size.height, 90, "靠近底部 → 放到鼠标上方，不挡鼠标")
        XCTAssertLessThanOrEqual(tl.y, visible.maxY - 8)
    }

    func testWindowLowerThirdCentered() {
        let w = CGRect(x: 100, y: 100, width: 1000, height: 600)
        let tl = AnchorChain.topLeft(for: .window(w), size: size, screens: pairs)!
        XCTAssertEqual(tl.x, 600 - 220)                   // 水平居中
        XCTAssertEqual(tl.y - size.height / 2, 200, accuracy: 0.001)   // 中线在窗口下三分之一中间（100 + 600/6）
    }

    func testWindowPanelClampedToScreen() {
        let w = CGRect(x: 1300, y: 0, width: 300, height: 120)        // 窗口在右下、部分出屏
        let tl = AnchorChain.topLeft(for: .window(w), size: size, screens: pairs)!
        XCTAssertLessThanOrEqual(tl.x + size.width, visible.maxX - 8)
        XCTAssertGreaterThanOrEqual(tl.y - size.height, visible.minY + 8 - 0.001)
    }

    func testSelectionPlacedBelowSelection() {
        let sel = CGRect(x: 200, y: 600, width: 300, height: 18)
        let tl = AnchorChain.topLeft(for: .rect(sel, .selection), size: size, screens: pairs)!
        XCTAssertEqual(tl, CGPoint(x: 200, y: 594))
    }

    func testDescribeHasNoUserText() {
        let i = AnchorInputs(selection: CGRect(x: 1, y: 2, width: 3, height: 4), mouse: CGPoint(x: 5, y: 6), trusted: true)
        let line = AnchorChain.describe(i, anchor: .rect(i.selection!, .selection), app: "com.apple.Safari")
        XCTAssertEqual(line, "app=com.apple.Safari trusted=true strategy=selection selection=1,2,3x4 caret=- field=- mouse=5,6 window=-")
    }
}
