import Cocoa
import InputMethodKit
import Carbon

/// 可选：命令行注册并启用输入源（等价于在“系统设置 › 键盘 › 输入法”里手动添加）
///   ~/Library/Input\ Methods/TranslateIME.app/Contents/MacOS/TranslateIME --install
enum InputSourceInstaller {
    static let modeID = "com.example.inputmethod.TranslateIME.Translate"

    static func install() -> Int32 {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("TISRegisterInputSource:", status)
        let filter = ["TISPropertyInputSourceID": modeID] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, true),
              let list = unmanaged.takeRetainedValue() as? [TISInputSource],
              let source = list.first else {
            print("找不到输入源 \(modeID)：请确认 App 已放在 ~/Library/Input Methods，并注销/重新登录后再试")
            return 1
        }
        print("TISEnableInputSource:", TISEnableInputSource(source))
        return 0
    }
}

if CommandLine.arguments.contains("--install") { exit(InputSourceInstaller.install()) }
if CommandLine.arguments.contains("--ax-status") {
    exit(MainActor.assumeIsolated { InsertSelfTest.axStatus(CommandLine.arguments) })
}
if CommandLine.arguments.contains("--selftest-reply") {
    exit(MainActor.assumeIsolated { InsertSelfTest.runReply(CommandLine.arguments) })
}
if CommandLine.arguments.contains("--selftest-override") {
    exit(MainActor.assumeIsolated { InsertSelfTest.runOverride(CommandLine.arguments) })
}
if CommandLine.arguments.contains("--selftest-translate") {
    exit(MainActor.assumeIsolated { TranslateProbe.run(CommandLine.arguments) })
}
if CommandLine.arguments.contains("--selftest-correct") {
    exit(MainActor.assumeIsolated { CorrectionSelfTest.run(CommandLine.arguments) })
}
if CommandLine.arguments.contains("--selftest-insert") {
    exit(MainActor.assumeIsolated { InsertSelfTest.run(CommandLine.arguments) })
}
if CommandLine.arguments.contains("--snapshot-panel") {
    exit(MainActor.assumeIsolated { PanelSnapshot.run(arguments: CommandLine.arguments) })
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
        server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
        AppContext.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppContext.shared.flushBlocking()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
