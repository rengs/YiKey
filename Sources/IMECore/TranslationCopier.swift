import Foundation

public protocol ClipboardWriting: AnyObject {
    func write(_ text: String)
}

public enum CopyOutcome: Equatable, Sendable {
    case copied(String)
    case nothingToCopy          // 输入为空或没有结果
    case failed(String)         // 翻译失败
    case superseded             // 等待期间输入又变了，放弃这次复制
}

/// 翻译面板里按 ↩：把当前输入的译文复制到剪贴板。
/// 若翻译还在防抖/进行中，异步等待它完成（不阻塞主线程），再确认结果对应的仍是当前输入后才写剪贴板。
@MainActor
public final class TranslationCopier {
    private let coordinator: TranslationCoordinator
    private let clipboard: ClipboardWriting

    public init(coordinator: TranslationCoordinator, clipboard: ClipboardWriting) {
        self.coordinator = coordinator; self.clipboard = clipboard
    }

    public func copyTranslation(of raw: String) async -> CopyOutcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .nothingToCopy }
        coordinator.update(text: text)                 // 已是当前文本则无操作；命中缓存则立即就绪
        var rounds = 0
        while case .loading = coordinator.phase, coordinator.sourceText == text, rounds < 100 {
            await coordinator.settle()                 // 挂起等待，不占用主线程
            rounds += 1
        }
        guard coordinator.sourceText == text else { return .superseded }
        switch coordinator.phase {
        case .ready(let r) where r.original == text:
            clipboard.write(r.translated)
            return .copied(r.translated)
        case .failed(let message):
            return .failed(message)
        default:
            return .nothingToCopy
        }
    }
}
