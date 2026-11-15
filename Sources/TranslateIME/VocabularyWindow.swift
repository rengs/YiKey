import SwiftUI
import AppKit
import IMECore

@MainActor
final class VocabularyViewModel: ObservableObject {
    @Published var entries: [VocabularyEntry] = []
    @Published var query = ""
    // FIX(CLT): 选中状态放进 ViewModel（@Published），避免使用 @State —— 仅装 Command Line Tools 时没有 SwiftUIMacros 插件
    @Published var selection = Set<String>()
    let book: VocabularyBook
    init(book: VocabularyBook) { self.book = book }

    var filtered: [VocabularyEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.english.lowercased().contains(q) || $0.chinese.contains(q) || $0.otherChinese.contains { $0.contains(q) }
        }
    }

    func reload() {
        Task { entries = await book.entries(sortedBy: .lastPlayedDescending) }
    }

    func delete(_ ids: Set<String>) {
        Task {
            for id in ids { await book.remove(id: id) }
            entries = await book.entries(sortedBy: .lastPlayedDescending)
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var model: VocabularyViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索英文或中文", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Text("\(model.filtered.count) 条").foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { model.reload() }
                Button("删除所选") { model.delete(model.selection); model.selection.removeAll() }.disabled(model.selection.isEmpty)
                Button("导出 CSV…") { AppContext.shared.exportVocabulary(csv: true) }
                Button("导出 JSON…") { AppContext.shared.exportVocabulary(csv: false) }
            }
            .padding(10)
            Divider()
            Table(model.filtered, selection: $model.selection) {
                TableColumn("英文") { e in Text(e.english).textSelection(.enabled) }
                TableColumn("中文原文") { e in Text(e.chinese).textSelection(.enabled) }
                TableColumn("播放次数") { e in Text("\(e.playCount)") }.width(70)
                TableColumn("最近播放") { e in Text(e.lastPlayedAt.formatted(date: .abbreviated, time: .shortened)) }.width(150)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}

@MainActor
final class VocabularyWindowController {
    private var window: NSWindow?
    private let model: VocabularyViewModel
    init(book: VocabularyBook) { model = VocabularyViewModel(book: book) }

    func show() {
        model.reload()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: VocabularyView(model: model)))
            w.title = "单词本"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 440))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
