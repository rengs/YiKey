import AppKit
import SwiftUI
import IMECore

/// 诊断：用真实的 Apple 本地翻译逐行翻译（离线），用来实测占位符是否被保留、对比加/不加术语表的译文。
///   TranslateIME --selftest-translate <in.tsv> <out.tsv> [--glossary]
/// in.tsv 每行：zh<TAB>文本 或 en<TAB>文本。带 --glossary 时同一句输出：原始译文 / 术语保护后的译文。
@MainActor
enum TranslateProbe {
    static func run(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--selftest-translate"), i + 2 < args.count else { return 2 }
        let inPath = args[i + 1], outPath = args[i + 2]
        let withGlossary = args.contains("--glossary")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard #available(macOS 15.0, *) else { try? "needs macOS 15".write(toFile: outPath, atomically: true, encoding: .utf8); return 1 }
        #if canImport(Translation)
        let bridge = AppleTranslationBridge()
        let host = NSHostingView(rootView: AppleTranslationHostView(bridge: bridge))
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.alphaValue = 0.01
        win.ignoresMouseEvents = true
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: 0, y: 0))
        win.orderFrontRegardless()
        let provider = AppleTranslationProvider(bridge: bridge)
        let glossary: GlossaryProbeCompare? = withGlossary ? GlossaryProbeCompare.make() : nil
        let lines = ((try? String(contentsOfFile: inPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        var out: [String] = []
        var done = false
        Task { @MainActor in
            for line in lines {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let from: TextLanguage = parts[0] == "zh" ? .chinese : .english
                let to = from.opposite
                let raw = (try? await provider.translate(parts[1], from: from, to: to)) ?? "<error>"
                if let g = glossary {
                    out.append(await g.compare(dir: parts[0], source: parts[1], raw: raw,
                                         translate: { t in (try? await provider.translate(t, from: from, to: to)) ?? "<error>" }))
                    _ = to
                } else {
                    out.append([parts[0], parts[1], raw].joined(separator: "\t"))
                }
                try? (out.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
            }
            done = true
        }
        let end = Date().addingTimeInterval(600)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try? (out.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
        return done ? 0 : 1
        #else
        return 1
        #endif
    }
}
