// 生成菜单栏模板图标（黑色“译”，透明背景）：swift scripts/make_icon.swift out.tiff
import AppKit
let size = NSSize(width: 32, height: 32)
let img = NSImage(size: size)
img.lockFocus()
let s = NSAttributedString(string: "译", attributes: [
    .font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.black])
let sz = s.size()
s.draw(at: NSPoint(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2))
img.unlockFocus()
try! img.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
