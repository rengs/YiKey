// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranslateIME",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TranslateIME", targets: ["TranslateIME"])],
    targets: [
        // 纯逻辑：语言判别、翻译服务/提供者、发音、协调器（可单元测试）
        .target(name: "IMECore", path: "Sources/IMECore"),
        // IME 外壳：IMKInputController、浮窗 UI、Apple Translation 桥、热键
        .executableTarget(name: "TranslateIME", dependencies: ["IMECore"], path: "Sources/TranslateIME"),
        .testTarget(name: "IMECoreTests", dependencies: ["IMECore"], path: "Tests/IMECoreTests"),
    ]
)
