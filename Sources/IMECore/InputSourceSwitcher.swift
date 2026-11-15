import Foundation

/// 一个输入源的描述（来自 TIS，测试里用假数据）
public struct InputSourceInfo: Equatable, Sendable {
    public var id: String
    public var localizedName: String
    public var languages: [String]
    public var isEnabled: Bool
    public var isSelectCapable: Bool
    public init(id: String, localizedName: String = "", languages: [String] = [],
                isEnabled: Bool = true, isSelectCapable: Bool = true) {
        self.id = id; self.localizedName = localizedName; self.languages = languages
        self.isEnabled = isEnabled; self.isSelectCapable = isSelectCapable
    }
}

/// 对系统输入源的最小抽象：真实实现用 TISCopyCurrentKeyboardInputSource / TISCreateInputSourceList / TISSelectInputSource，
/// 只会选择**已启用**的输入源，不会启用/添加输入源，也不改系统设置。
@MainActor
public protocol InputSourceSystem: AnyObject {
    func currentSourceID() -> String?
    func enabledSources() -> [InputSourceInfo]
    @discardableResult func select(id: String) -> Bool
}

public enum InputSourcePicker {
    /// 优先：系统自带“拼音 – 简体”
    public static let preferredIDs = ["com.apple.inputmethod.SCIM.ITABC"]

    public static func pickSimplifiedPinyin(from sources: [InputSourceInfo]) -> InputSourceInfo? {
        let usable = sources.filter { $0.isEnabled && $0.isSelectCapable }
        for id in preferredIDs { if let s = usable.first(where: { $0.id == id }) { return s } }
        return usable.first(where: isSimplifiedPinyin)
    }

    public static func isSimplifiedPinyin(_ s: InputSourceInfo) -> Bool {
        let id = s.id.lowercased(), name = s.localizedName.lowercased()
        if id.contains("tcim") || id.contains("traditional") || name.contains("繁") || name.contains("traditional") { return false }
        let pinyin = id.contains("pinyin") || id.contains("itabc") || name.contains("pinyin") || name.contains("拼音")
        let hans = s.languages.isEmpty || s.languages.contains { l in
            let x = l.lowercased(); return x.hasPrefix("zh-hans") || x == "zh" || x == "zh-cn"
        }
        return pinyin && hans
    }
}

/// 翻译面板打开时切到简体拼音，关闭时恢复原输入源。
@MainActor
public final class InputSourceSwitcher {
    public enum Outcome: Equatable, Sendable {
        case switched(from: String?, to: String)
        case alreadyActive(String)
        case noPinyin
        case selectFailed(String)
    }

    private let system: InputSourceSystem
    public private(set) var savedSourceID: String?
    public private(set) var switchedToID: String?

    public init(system: InputSourceSystem) { self.system = system }

    public func activatePinyin() -> Outcome {
        let current = system.currentSourceID()
        guard let target = InputSourcePicker.pickSimplifiedPinyin(from: system.enabledSources()) else {
            return .noPinyin
        }
        if current == target.id {
            if switchedToID == nil { savedSourceID = nil }     // 本来就是拼音：关闭时不需要恢复
            return .alreadyActive(target.id)
        }
        guard system.select(id: target.id) else { return .selectFailed(target.id) }
        if switchedToID == nil { savedSourceID = current }     // 重复调用时保留最初的输入源
        switchedToID = target.id
        return .switched(from: current, to: target.id)
    }

    /// 面板打开后焦点稳定时再确认一次（应用激活是异步的，第一次切换可能被激活过程覆盖）
    @discardableResult
    public func reassertIfNeeded() -> Bool {
        guard let target = switchedToID, system.currentSourceID() != target else { return false }
        return system.select(id: target)
    }

    /// 恢复打开面板前的输入源；只在本次确实切换过时恢复，且只恢复一次。
    @discardableResult
    public func restore() -> Bool {
        defer { savedSourceID = nil; switchedToID = nil }
        guard switchedToID != nil, let previous = savedSourceID else { return false }
        guard system.currentSourceID() != previous else { return false }
        return system.select(id: previous)
    }
}
