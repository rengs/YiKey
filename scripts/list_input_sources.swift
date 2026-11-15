// 只读诊断：列出当前与已启用的键盘输入源（不切换、不启用任何输入源）。
// 用法：swift scripts/list_input_sources.swift
import Carbon
func str(_ s: TISInputSource, _ k: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(s, k) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func langs(_ s: TISInputSource) -> [String] {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages) else { return [] }
    return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
}
func flag(_ s: TISInputSource, _ k: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(s, k) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}
if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() { print("current:", str(cur, kTISPropertyInputSourceID) ?? "?") }
let filter = [kTISPropertyInputSourceIsEnabled as String: true,
              kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
let list = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
for s in list {
    print("enabled:", str(s, kTISPropertyInputSourceID) ?? "?", "|", str(s, kTISPropertyLocalizedName) ?? "",
          "|", langs(s).prefix(3).joined(separator: ","), "| selectable:", flag(s, kTISPropertyInputSourceIsSelectCapable))
}
