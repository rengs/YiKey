// 自检用的“假聊天应用”：上方搜索框 + 密码框，中间只读聊天记录（初始焦点在这里），底部消息输入框。
// 用法：swiftc -O scripts/reply_scratch_app.swift -o /tmp/ReplyScratch && /tmp/ReplyScratch <value-out-file>
// 每 0.2 秒把底部输入框、搜索框、密码框的内容写到 value-out-file，供自检独立核对。
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/reply-scratch-value.txt"
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let win = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 640, height: 460),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "TranslateIME Reply Scratch"
let content = NSView(frame: win.contentRect(forFrameRect: win.frame))
win.contentView = content

let search = NSSearchField(frame: NSRect(x: 12, y: 420, width: 300, height: 24))
search.placeholderString = "Search"
let secure = NSSecureTextField(frame: NSRect(x: 330, y: 420, width: 298, height: 24))
secure.placeholderString = "Password"
let scroll = NSScrollView(frame: NSRect(x: 12, y: 56, width: 616, height: 356))
let history = NSTextView(frame: scroll.bounds)
history.isEditable = false
history.isSelectable = true
history.string = "Alice: Hi! Could you send me the report?\nBob: Sure, give me a minute.\nAlice: Thanks!"
scroll.documentView = history
scroll.hasVerticalScroller = true
let input = NSTextField(frame: NSRect(x: 12, y: 12, width: 616, height: 32))
input.placeholderString = "Type a message"
for v in [search, secure, scroll, input] as [NSView] { content.addSubview(v) }

win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
win.makeFirstResponder(history)            // 焦点在聊天记录（不可编辑），不在输入框
history.setSelectedRange(NSRange(location: 7, length: 20))

Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    let s = "input=\(input.stringValue)\nsearch=\(search.stringValue)\nsecure.count=\(secure.stringValue.count)\n"
    try? s.write(toFile: out, atomically: true, encoding: .utf8)
}
app.run()
