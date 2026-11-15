# 编译修复记录（2026-11-14，在 MacBook Air 上：macOS 27.2.1 arm64，仅 Command Line Tools，Swift 6.4.2）

最初的工程此前从未编译过。为了在**只装了 Command Line Tools（没有 Xcode.app）**的机器上编译和测试，做了以下修改，功能逻辑没有改动：

1. `Sources/TranslateIME/VocabularyWindow.swift`
   - 问题：`@State` 是 SwiftUI 宏，宏插件 `SwiftUIMacros` 只随 Xcode 提供，CLT 下报错
     `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`。
   - 修复：把表格的选中状态 `selection` 从 View 的 `@State` 挪到 `VocabularyViewModel` 的 `@Published var selection`，
     View 里改用 `model.selection` / `$model.selection`。行为相同。

2. 测试：CLT 不带 `XCTest.framework`（`swift test` 报 `unable to resolve module dependency: 'XCTest'`），但带有 swift-testing。
   - 新增 `Tests/IMECoreTests/XCTestShim.swift`：最小 XCTest 兼容层（XCTestCase、XCTAssert*/XCTFail/XCTUnwrap、measure），
     失败时调用 swift-testing 的 `Issue.record`。
   - 新增 `Tests/IMECoreTests/XCTestBridge.swift`（由 `scripts/gen_xctest_bridge.py` 生成）：把 67 个 XCTest 方法逐一注册成
     `@Test`，每个用例新建实例、按套件串行执行；`@MainActor` 的测试类在主 actor 上运行。
   - 新增 `Tests/IMECoreTests/XCTestShimSelfTest.swift`：用 `withKnownIssue` 证明兼容层的断言失败确实会让测试失败。
   - 7 个测试文件的 `import XCTest` 改为 `#if canImport(XCTest) import XCTest #endif` 并显式 `import Foundation`。
   - 以上三个新文件都包在 `#if !canImport(XCTest)` 里：装了完整 Xcode 后自动走原生 XCTest，原测试源码未改断言。
   - 注意：若新增测试方法，需要重新运行 `python3 scripts/gen_xctest_bridge.py`。
   - 注意：CLT 下增量编译偶发找不到 TestingMacros 插件，`swift package clean` 后重跑即可。

## 结果
- `swift build -c release --arch arm64`：成功（仅 1 个无害警告：InputController.swift:27 多余的 `as?`）。
- `swift package clean && swift test --no-parallel`：69 个测试（67 个原有 + 2 个兼容层自检）全部通过，用时约 3.8 秒。
- `scripts/build.sh`：生成 `build/TranslateIME.app`（arm64，ad-hoc 签名，`codesign --verify --deep --strict` 通过）。
- `scripts/install.sh`：已安装到 `~/Library/Input Methods/TranslateIME.app`；手动启动 4 秒未崩溃。

# 功能更新（2026-11-14 17:10 PT）：英文输入也加发音

需求：英文输入（英→中）时，英文原文旁也显示 🔊，只有点击才用 en-US 朗读英文原文，并记入同一个去重单词本；中文译文仍然不发音。

- `Sources/IMECore/TranslationCoordinator.swift`
  - 新增 `pronunciationText`（中→英 = 英文译文；英→中 = 英文原文；否则 nil）、`canPronounceSource`、`canPronounceTranslation`；
    `canPronounce` 改为“任一方向有英文可读”。
  - `pronounceTapped()` 读 `pronunciationText`，单词本记录 english=英文那一侧、chinese=中文那一侧。仍是全工程唯一的 `.speak(` 调用（静态守卫测试仍通过）。
- `Sources/TranslateIME/PanelViews.swift`
  - 候选浮窗：英文原文右侧加 🔊；翻译面板：输入框右侧加 🔊（仅英→中且结果已就绪时显示）。中→英时译文旁的 🔊 保留。
  - 新增 `SpeakerButton`（AppKit `NoFocusButton`）：`acceptsFirstMouse = true`、不接受第一响应者、`needsPanelToBecomeKey = false`，
    点击只调用 `pronounceTapped()`，不抢焦点、不提交组词、不上屏。原来的 SwiftUI 🔊 按钮也换成它。
- `Sources/TranslateIME/FloatingPanel.swift`：浮窗内容视图改为 `FirstMouseHostingView`（`acceptsFirstMouse = true`），候选浮窗不会成为 key，第一次点击就能送达按钮。
- 测试：
  - 删除过时的 `testEnglishSourceHasNoPronunciation`、`testEnglishToChineseNeverAddsEntry`（断言旧行为）。
  - 新增 `PronunciationTests`：`testEnglishSourcePronouncesOriginalOnlyWhenTapped`、`testNoAutoSpeakForEnglishSourceAcrossUpdatesAndReset`、
    `testChineseIsNeverSpokenInEitherDirection`、`testPronunciationTextPerDirection`、`testEnglishSourceTapIgnoredWhileLoading`。
  - 新增 `VocabularyIntegrationTests`：`testEnglishSourceClickAddsEntry`、`testEnglishSourceAndChineseSourceShareDedupedEntry`、
    `testEnglishSourceNoClickNoEntry`、`testEnglishSourceTapStaysFastWithLargeBook`。
  - 重新生成 `XCTestBridge.swift`（74 个用例）。

## 结果（2026-11-14 17:14 PT）
- 期间本机装了 Xcode.app 且被设为当前开发者目录，但 Xcode 许可协议尚未同意（需要 `sudo xcodebuild -license`，未执行）。
  因此本次所有命令都用 `DEVELOPER_DIR=/Library/Developer/CommandLineTools` 临时指定 CLT（只对该命令生效，不改系统设置）。
  以后要自己编译：`export DEVELOPER_DIR=/Library/Developer/CommandLineTools` 再运行 `swift test` / `scripts/build.sh`；
  或者自行同意 Xcode 许可后直接用 Xcode（届时 canImport(XCTest) 为真，会自动走原生 XCTest）。
- `swift package clean && swift test --no-parallel`：76 个测试（74 个功能测试 + 2 个兼容层自检）全部通过，4.3 秒。
- `scripts/build.sh` 成功；`scripts/install.sh` 结束了正在运行的旧 TranslateIME 进程并装上新版本；签名校验通过；手动启动 4 秒未崩溃。

# 功能更新（2026-11-14 20:40 PT）：拼音自动切换、输入框变长、↩ 复制译文、⌘V 粘贴

环境：此时本机已装好完整 Xcode 27.2 且已同意许可，`swift test` 走**原生 XCTest**（兼容层自动不启用）。

1. 翻译面板自动切到简体拼音
   - 新增 `Sources/IMECore/InputSourceSwitcher.swift`：`InputSourceInfo`、`InputSourceSystem` 协议、`InputSourcePicker`
     （优先 `com.apple.inputmethod.SCIM.ITABC`，其次其它已启用的简体拼音，排除繁体、未启用、不可选择的输入源）、
     `InputSourceSwitcher`（activatePinyin / reassertIfNeeded / restore；只恢复一次；本来就是拼音则不恢复）。
   - 新增 `Sources/TranslateIME/InputSources.swift`：`TISInputSourceSystem`（只用 TISCopyCurrentKeyboardInputSource /
     TISCreateInputSourceList(已启用) / TISSelectInputSource，不启用/添加输入源）和 `SystemClipboard`。
   - `FloatingPanel.swift`：`showTranslator` 打开后切到拼音，150ms 后若被激活过程切回则再确认一次；`hide` 时先恢复输入源再回到原应用；
     没有拼音时在输入框下方显示提示。菜单可关闭（`autoSwitchPinyin`）。
   - 新增只读诊断脚本 `scripts/list_input_sources.swift`。本机实测：已启用 `com.apple.inputmethod.SCIM.ITABC`（Pinyin – Simplified），会被选中。
2. 输入框随文字变长，35 个汉字才换行
   - 新增 `Sources/IMECore/InputBoxLayout.swift`（`InputBoxSizer`）：单行宽度 ≤ 35 个汉字宽（按实际字体量“中”的宽度）时横向变长；
     超过后宽度封顶、按折行高度变高（最多 10 行），含正在组词的拼音。
   - `PanelViews.swift`：输入框始终是可换行的 NSTextField，宽高由 sizer 给出；面板宽度 = max(380, 输入框 + 🔊 + 边距)；
     `FloatingPanel.relayout` 让变宽/变高的面板保持在屏幕内。
3. ↩ 复制译文
   - 新增 `Sources/IMECore/TranslationCopier.swift`：有未完成的翻译时 `await` 等待（不阻塞主线程），确认结果仍对应当前输入才写剪贴板；
     空输入/失败/等待期间输入变化都不写。
   - 面板：↩ = 复制译文并提示“已复制 ✓”；⌥↩ = 上屏译文（原 ↩ 行为）；⌘↩/⇧↩ = 上屏原文；组词中的 ↩ 不拦截。新增“复制译文”按钮。
4. ⌘V 粘贴
   - `CompositionBuffer`：新增 `ComposeKey.paste` 与 `PasteNormalizer`（换行/制表符→空格，去控制字符，最多 500 字）；
     空组词时只接管英文；组词中追加；不接管时放行给应用。
   - `InputController`：组词路径识别 ⌘V 并读剪贴板（耗时记入 clientIPC/pasteboard）。菜单可关闭（`pasteIntoComposition`）。
   - 翻译面板输入框：IME 进程没有“编辑”菜单，新增 ⌘V/⌘C/⌘X/⌘A/⌘Z 处理（`FocusingTextField.performKeyEquivalent`）。
5. 测试：新增 `Tests/IMECoreTests/PanelFeatureTests.swift`（36 个：InputBoxSizerTests 8、PasteCompositionTests 9、
   TranslationCopierTests 9、InputSourceSwitcherTests 10）；重新生成 `XCTestBridge.swift`（110 个）。

## 结果
- `swift package clean && swift test --no-parallel`（原生 XCTest）：110 个测试，0 失败，5.9 秒。
- `scripts/build.sh` 成功（Xcode 工具链）；`scripts/install.sh` 结束旧 TranslateIME 进程并覆盖安装；签名校验通过；手动启动 4 秒未崩溃。

# 修复（2026-11-14 21:00 PT）：翻译面板换行后“中文遮挡”+ ↩ 复制后自动关闭

## 中文遮挡
现象：长句折成 2 行后，第一行只露出下半截，第二行可见，输入框与分隔线之间有一大块空白。
根因：
1. 旧输入框是 NSTextField。编辑时真正显示文字的是 field editor，它放在 NSTextField 内部一个按“开始编辑时的单行高度”建立的
   裁剪视图里；折到第二行时 field editor 滚动到光标所在的最后一行，于是第一行被推出顶部。外框后来按我们算的高度变高，
   但内部裁剪视图不跟着变，下面就空出一块。
2. 旧高度用 `boundingRect + 4` 估算，与 NSTextField 实际排版（内边距、lineFragmentPadding）不一致。
3. 改成 NSScrollView + NSTextView 的第一版里，文本视图用 autoresizingMask 跟随宽度，滚动视图从 0 尺寸长大时被算成 850pt 宽、
   原点 -35pt（截图诊断工具实测发现），同样会把第一行推出顶部。
修复：
- `Sources/IMECore/InputBoxTextMeasurer.swift`（新增）：用与输入框**完全相同**的 NSLayoutManager/NSTextContainer 配置
  （同字体、textContainerInset、lineFragmentPadding）测量单行宽度和折行高度；`configure(_:)` 把输入框 NSTextView 配成同一套参数。
- `InputBoxSizer`：输入框高度 = 实测文本高度 + 上下内边距（单行和多行都实测）；超过 15 行才封顶并标记 `scrolls`。
- `PanelViews.swift`：输入框改为 NSScrollView + `PanelInputTextView`（NSTextView）：
  - `TopPinnedClipView`：文本放得下时滚动位置永远钉在顶部；`scrollRangeToVisible`/滚轮只在超过 15 行时生效；
  - `PanelInputScrollView.syncDocumentFrame()`：文本视图宽度 = 可见宽度、原点 (0,0)，不再用 autoresizingMask；
  - 拼音组词（setMarkedText/unmarkText）时也重新测量；占位文字自己绘制；⌘V/C/X/A/Z 照旧支持。
  - 面板根视图贴顶对齐（宿主比内容大时也不会把顶部挤出去）。
- `FloatingPanel.swift`：输入框尺寸变化不走 16ms 节流，下一轮主循环立即重新布局面板；面板顶部固定，靠近屏幕底部时上移。
- 新增诊断命令 `TranslateIME --snapshot-panel <out.png> <文字> [停留秒数]`（`PanelSnapshot.swift`）：用真实面板代码排版、
  打印尺寸并渲染 PNG；不读写设置、不切换输入源。

## ↩ 复制后自动关闭（新需求）
- 新增 `Sources/IMECore/PanelSubmitPolicy.swift`：按键映射（↩ 复制 / ⇧⌥↩ 复制并清空 / ⌥↩ 上屏译文 / ⌘↩、⇧↩ 上屏原文）
  和复制后的动作（0.5 秒后关闭 / 清空并保持 / 保持 / 失败显示错误）。
- `FloatingPanel.copyTranslation`：成功 → “已复制 ✓”约 0.5 秒后 `hide()`（清空输入、恢复输入源、回到原应用）；
  ⇧⌥↩ → 清空输入继续下一句；失败 → 不关闭，显示“翻译失败，未复制：…”；用会话计数防止误关下一次打开的面板。
- 菜单新增“复制后自动关闭面板”（`closeAfterCopy`，默认开）；面板底部提示改为
  “↩ 复制并关闭 · ⇧⌥↩ 复制并清空 · ⌥↩ 上屏译文 · ⌘↩ 上屏原文 · ⎋ 关闭”。

## 测试与结果
- 新增 `Tests/IMECoreTests/PanelLayoutRegressionTests.swift`（17 个）：真实字体 + 真实 NSTextView 排版下 1/2/3/10 行的
  输入框高度 == 实际文本高度（误差 ≤1pt）且行数一致；35 字一行、36 字两行；拼音混排；空文本；超过 15 行封顶；
  以及 PanelSubmitPolicy 的按键映射、复制后关闭/清空/失败不关闭、提示文字、默认开关、等待翻译后复制。
- 原生 XCTest：127 个测试，0 失败（6.3 秒）。
- `--snapshot-panel` 实测（已安装版本）：20/45/80/325 字（1/2/3/10 行）均 RESULT OK：所需高度 = 可见高度，滚动原点 0，空白 0；
  700 字（20 行）封顶 15 行、从顶部显示、可滚动。`screencapture -l` 截到的真实窗口截图也确认每一行完整可见、无空白。

# 功能更新（2026-11-14 21:25 PT）：剪贴板英文监测（兼任翻译软件）

## 行为
- 在任何应用里 ⌘C 复制一段**英文**，约 0.5 秒内屏幕右上角自动弹出面板：英文原文 + Apple 本地中文译文；
  英文旁 🔊 仅点击才读（en-US），点击即记入单词本（与之前同一套去重规则）。
- 面板以“非激活 key 面板”出现：原应用仍在前台、输入法不变，但 ↩ / ⎋ 先到面板：
  - **↩**（或点“用中文回复”、或 ⌃⌥T）→ 切到**中→英回复模式**：清空输入、自动切到简体拼音、聚焦输入框，
    对方的英文原文以小字保留在输入框上方；输入中文后 **↩** 复制英文译文并关闭，恢复原输入法、回到原应用，直接 ⌘V。
  - **⎋** 关闭。
  - 其他普通按键 → 面板立即关闭并把这个按键补发给原应用（需辅助功能授权；未授权时这个键会丢失）。
  - ⌘/⌃ 快捷键不拦截。
- 不打扰：翻译面板正在输入、正在组词、或 TranslateIME 自己的窗口（单词本等）在前台时不弹出。

## 不误触发（`Sources/IMECore/ClipboardWatcher.swift` → `ClipboardTextFilter`）
- 自己写的剪贴板：所有写入统一走 `OwnPasteboard`（复制译文、上屏、恢复原剪贴板、复制延迟报告），
  带私有类型 `com.example.inputmethod.TranslateIME.own` **并**登记 changeCount，两道保险。
- 密码管理器：`org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`（以及 1Password 等私有类型）。
- 仅链接/邮箱、文件路径、纯数字/电话/金额/订单号、代码（符号密度、`func`/`=>`/`&&`/`git `等标记、camelCase/snake_case、缩进代码块）。
- 少于 2 个字母、超过 2000 字符、与上一次弹出的文本相同、中文/日文。
- 启动时剪贴板里已有的内容不弹；关闭后重新开启也不回放关闭期间的复制。

## 菜单
- “监测剪贴板英文并自动翻译”（`clipboardWatch`，默认开）
- “暂停剪贴板监测 1 小时” / “恢复剪贴板监测（已暂停至 HH:mm）”（`clipboardPausedUntil`，重启 IME 后仍有效）

## 实现
- `ClipboardWatcher.poll()`：每 0.5 秒（`Timer`，tolerance 0.25 秒允许系统合并唤醒）只读 `changeCount`；
  没变化时不读任何内容。变化后才读类型 + 文本并过滤；整个过程不在按键路径上。
- `PanelViewModel.Mode` 新增 `.reading`；`PanelController.showReading / startReply / handleReadingKey`；
  `FirstMouseHostingView.keyHandler` 接收阅读模式的 ↩ / ⎋。
- 新延迟指标 `clipboardPoll`（只记录剪贴板发生变化的那次判定，预算 3ms）。

## 测试与结果
- 新增 `Tests/IMECoreTests/ClipboardWatcherTests.swift`（23 个）：过滤规则（英文触发、中文/日文、敏感类型、私有类型、
  链接/邮箱、路径、数字、代码、过短/过长、重复、普通英文里的 return/let 不误判）、监测器（启动不弹、只处理一次、
  未变化不读内容、自写按 changeCount / 私有类型忽略、关闭/重新开启不回放、暂停 1 小时、面板忙时不打扰、敏感复制）、
  阅读 → ↩ 回复 → ↩ 复制英文的完整流程（复制的英文不会再次弹出）。
- 修正 `PanelLayoutRegressionTests` 里向兼容层传 `file:/line:` 导致仅装 CLT 时无法编译的问题。
- 全部 152 个测试通过（0 失败，6.4 秒；另有 7 个是兼容层自检的“预期失败”）。
- 性能：空闲轮询 0.13 µs/次；剪贴板变化后一次判定 0.11 ms；过滤 0.49 ms/次（debug 构建，含 1900 字长文本样本）；
  按键 keyHandling p95 0.03–0.04 ms、max 0.07 ms；↩ 复制的主线程同步部分 0.005 ms。
- 真机（已安装 release 版）：复制 URL、文件路径 → 不弹；复制英文句子 → 3.5 秒内右上角弹出 440×183 面板，Apple 本地译文正确
  （截图 build/snap/clipboard-reading.png）。进程 20 秒内 CPU 时间仅增加 0.01 秒（≈0.05%，含 40 次轮询）。
  测试前完整备份了剪贴板（含 HTML/Chrome 私有类型），测试后已原样恢复。

# 功能更新（2026-11-14 21:45 PT）：面板跟随输入框 + 回车自动填入原输入框

## 面板跟随当前应用的输入位置
- ⌃⌥T 面板和剪贴板英文面板打开时（在激活本应用之前），先找到原应用的光标位置：
  1. TranslateIME 正是该应用的当前输入法 → IMK `attributes(forCharacterIndex:lineHeightRectangle:)`；
  2. 已授权辅助功能 → `AXFocusedUIElement` 的 `AXSelectedTextRange` + `AXBoundsForRange`（光标处），
     拿不到再用输入框本身的 `AXPosition/AXSize`（只用于高度 ≤200pt 的输入框；大文本区域用默认位置）；AX 调用设了 0.15s 超时；
  3. 都拿不到 → 原来的位置（⌃⌥T 在鼠标所在屏幕中上部，剪贴板面板在右上角）。
- `IMECore/PanelPlacement`：默认放在光标行下方 6pt、左对齐；下方放不下放上方；都放不下放空间大的一侧并贴边；
  水平方向夹在屏幕可见区域内（8pt 边距）；面板变高时每次重新计算，不挡光标行。多屏、Quartz→Cocoa 坐标转换已处理。

## ↩ 自动填入原输入框（菜单“回车后自动填入原输入框”，`autoInsertAfterReturn`，默认开）
- 回复模式和 ⌃⌥T 面板里按 ↩：等译文就绪 → 等 ↩ 松开（防止长按回车的连发落到原应用变成“发送”）→
  关闭面板、恢复输入源、回到原应用 → 插入：
  1. 原应用里当前输入法是 TranslateIME → IMK `client.insertText`（不碰剪贴板，不需要辅助功能）；
  2. 已授权辅助功能 → 剪贴板写入英文（带自写标记）→ 0.12s 后模拟 **⌘V**（发送前再确认前台就是原应用，否则不发）→
     0.5s 后恢复用户原剪贴板（全部类型；若期间用户自己又复制了别的就不覆盖），恢复也登记为自写，剪贴板监测不会再弹；
  3. 都不行 → 只复制，面板显示“已复制，请 ⌘V（开启辅助功能可自动粘贴）”，1.8s 后关闭。
- **只插入文字，绝不发送回车**：代码里只有 ⌘V 一种合成按键。
- ⇧⌥↩（复制并清空、面板保持）、⌥↩、⌘↩、⎋ 不变；关闭该菜单项则恢复“↩ 复制并关闭”。
- 新增 `IMECore/AutoInserter.swift`（`InsertionPlanner` + `AutoInserter`，依赖协议便于测试）、
  `TranslateIME/AutoInsertSupport.swift`（`CaretLocator`、`SystemPasteboardStore`、`CGEventPasteSender`、`IMKClientInserter`）。
- 诊断：`TranslateIME --ax-status <file>` 输出本 App 是否已获辅助功能授权；`--selftest-insert <file> <text>` 只对 TextEdit 做一次自动填入自检。

## 测试与结果
- 新增 `Tests/IMECoreTests/AutoInsertTests.swift`（19 个）：位置（下方默认、靠近底部改上方、左右边缘夹取、面板过高、副屏偏移原点、
  只有输入框矩形、坐标转换、无效光标）；策略矩阵与提示；IMK 插入不碰剪贴板/不发按键；IMK 不可用时降级为 ⌘V 或仅复制；
  ⌘V 时剪贴板是译文、之后恢复原剪贴板（含全部类型）；用户期间复制了别的不覆盖；粘贴与恢复都不会让剪贴板监测再弹出。
- 全部 **169 个测试，0 失败**（6.9 秒）。这次 SwiftPM 直接用上了原生 XCTest；另外**不要再设置
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`**：新版 SwiftPM 构建后端在这个设置下找不到 swift-testing 宏插件，
  直接 `swift test` 即可（xcode-select 已指向 CLT）。
- 真机：本 App 当前**未获辅助功能授权**（`--ax-status` → false）。TextEdit 自检走“仅复制”降级：没有发送任何按键，
  剪贴板写入英文并登记为自写；测试前后完整备份/恢复了用户剪贴板。

# 修复（2026-11-14 21:55 PT）：复制英文后面板仍出现在右上角

## 原因
1. 面板位置只找“光标 / 输入框”：复制时焦点通常在网页正文、聊天记录这类**不可编辑**的内容上，
   没有光标也没有输入框 → 直接退回右上角。
2. 授予辅助功能之前就已启动的 IME 进程，再加上 ad-hoc 签名每次重装都会让授权失效，AX 往往根本没生效。

## 修复：剪贴板面板的锚点链（`IMECore/AnchorChain.swift`）
1. **selection**：焦点元素的选中范围 `AXSelectedTextRange` + `AXBoundsForRange`（刚复制的文字本身；多行选区取最后一行），
   再试 WebKit/Chromium 的 `AXSelectedTextMarkerRange` + `AXBoundsForTextMarkerRange`；
2. **caret**：光标处（AX，或 TranslateIME 为当前输入法时的 IMK）；
3. **field**：焦点输入框矩形（高度 ≤200pt）；
4. **mouse**：检测到剪贴板变化那一刻的鼠标位置，面板放在鼠标右下方（右 12pt、下 10pt），靠边时翻到上方/左移；
5. **window**：前台应用焦点窗口下三分之一的中间；
6. **fallback**：右上角（最后手段）。
- 每次都实时调用 `AXIsProcessTrusted()`（不缓存启动时状态）；未授权时不做任何 AX 调用。
- AX 查询放到后台任务里做（每个元素 0.15s 超时），不在主线程/按键路径上；找到一个就不再问后面的。
- 诊断日志 `~/Library/Logs/TranslateIME/placement.log`（256KB 轮转）：每次弹出记录 app、是否授权、所用策略、各候选矩形、鼠标、
  AX 耗时、面板位置；**不记录任何文字**。

## 签名稳定（辅助功能授权不再因重装失效）
- 新增 `scripts/setup_signing.sh`：在 `~/Library/Keychains/translateime-signing.keychain-db` 建一个**专用**钥匙串
  （密码随机生成，存于 `~/Library/Application Support/TranslateIME/signing/`，权限 600），内含自签名代码签名证书
  “TranslateIME Local Signing”。不需要 sudo，不改系统设置，不碰登录钥匙串，也不需要信任该证书。
- `scripts/build.sh`：有该证书时用它签名，并把 designated requirement 固定为
  `identifier "com.example.inputmethod.TranslateIME" and certificate leaf = H"<本机证书 SHA1>"`；没有时退回 ad-hoc。
- 从 ad-hoc 换成证书签名这一次，系统仍会认为是“新 App”，**需要重新授权一次**；之后重新编译安装都保持授权。

## 测试与结果
- 新增 `Tests/IMECoreTests/AnchorChainTests.swift`（16 个）：选区优先且短路、无选区用光标、输入框（过高的拒绝）、IMK 光标、
  未授权不调 AX → 鼠标、授权状态实时变化（不缓存）、无效矩形忽略、鼠标不可用 → 窗口、全无 → 右上角、
  鼠标右下方位置与靠边翻转/夹取、窗口下三分之一居中与夹取、选区下方、日志不含文字。
- `swift test`（不设 DEVELOPER_DIR）：**185 个测试，0 失败**。
- 真机：安装后旧进程已结束；`--ax-status` → false（签名方式切换导致，需重新授权一次）。
  `pbcopy` 英文 → 日志 `strategy=mouse mouse=736,342 axMs=11.7 panel=748,190`，窗口实际位于鼠标右下方
  （截图 build/snap/clipboard-mouse.png），不再在右上角；测试后剪贴板已恢复、测试进程已结束。


## 更新：↩ 回复后自动找到来源应用的输入框

- 新增 `IMECore/ReplyInserter.swift`（`InputBoxFinder` 评分 + `ReplyInserter` 流程，可测）与 `TranslateIME/ReplyDriver.swift`
  （AX 实现：激活来源窗口、BFS 搜索输入框、AXFocused/单击、AXSelectedText、⌘V 兜底、提示 HUD）。
- 剪贴板触发与 ⌃⌥T 打开面板时都记住来源 pid + 窗口；最终 ↩ 时英文始终保留在剪贴板（不还原、不再触发）。
- 从不发送回车/发送键；⌘V 只在来源应用在最前、输入框已聚焦时发送。
- 新增测试 19 个（候选评分、跳过搜索/密码框、焦点优先、聚焦/插入兜底顺序、剪贴板保留且不再触发、日志不含文字）。
  `swift test`：**204 个测试，0 失败**。
- 固定证书签名构建并重装：安装前后 `--ax-status` 都是 `AXIsProcessTrusted=true`（授权在重装后保留）。
- 真机自测（自建的模拟聊天窗口，焦点在只读记录上）：`result=insertedAX target=searched focus=ax candidates=4
  role=AXTextField`，底部输入框得到 “Hello from TranslateIME”，搜索框/密码框为空；剪贴板已在测试后恢复，测试进程已结束。

### 请手工验证
1. 微信 / Slack / 浏览器网页聊天：在聊天记录里复制一句英文 → 面板出中文 → ↩ → 输入中文 → ↩，
   英文应出现在底部输入框（**不会自动发送**），同时剪贴板里也有这句英文。
2. 若提示“未找到输入框，已复制，请 ⌘V”，手动 ⌘V 即可，并把 `~/Library/Logs/TranslateIME/placement.log`
   最后几行 `reply` 记录发给我（只含控件角色/位置，不含文字）。


## 更新：回复模式中复制别的英文 → 立即切回英文阅读

- 剪贴板监测改为按面板状态判断（`ClipboardPanelState`）：阅读中换新英文、回复中被新的外部英文覆盖（`overrideReply`）；
  组词 / TranslateIME 自己的窗口在前台仍不打扰；自写、相同文字、过滤规则照旧。
- 新增 `ReplySession`：来源更新为新复制的位置；回复草稿暂存，对同一来源再 ↩ 时恢复，⎋ 丢弃。
- 切换时：取消面板内的拼音组词（只影响面板自身输入框）、取消旧回复的翻译/填入（`ReplyInserter` 新增 `.cancelled`）、
  恢复原输入源；面板按锚点链移到新复制处。
- 用前台应用判断“是否在面板里打字”（`NSApp.isActive` 切走瞬间可能未更新，自测中发现并修正）。
- 新增测试 16 个；`swift test`：**220 个测试，0 失败**。
- 固定证书签名构建并重装：`--ax-status` → `AXIsProcessTrusted=true`。
- 真机自测（自建 scratch 窗口 + pbcopy，`--selftest-override`，不切系统输入源、不发按键）：
  回复中（含未确认拼音 “fa”）自写剪贴板 → 忽略；pbcopy 相同英文 → 忽略；pbcopy 新英文 → 立即切到阅读，
  `kind=overrideReply leftReply=1 draftStashed=1`，拼音已取消，来源=scratch，面板移到选中文字下方（`strategy=selection`）；
  再 ↩ → 草稿 “我明天会” 恢复；⎋ → 草稿丢弃。测试后剪贴板已恢复，测试进程已结束。

### 请手工验证
1. 微信/Slack：复制英文 A → ↩ → 输入一半中文（可留着拼音没确认）→ 去聊天记录复制英文 B：面板应立即显示 B 的中文译文和 🔊，
   输入法恢复成原来的；在同一聊天窗口按 ↩：刚才的半截中文回来了；⎋ 则丢弃。
2. 回复中再复制一次 A（同一句）不应打断；在面板输入框里 ⌘C 也不应打断。

## 更新：离线术语表（三层）

- 第 1 层：`GlossaryIndex`（中文字典树 / 英文整词 token 树，单复数、缩写区分大小写）、`TermPlan`（嵌入目标术语为主，
  ZQX+字母 占位符回退，容错还原、补空格、a/an、句首大写、中文去空格）、`TranslationService` 接入（单术语直出、缓存随词表清空）。
- 占位符方案由真机实验决定：10 种占位符 × 17 句 + 直接嵌入 12 句（`probe/ph.out`）；`{1}` 会变 `{{1}}`、`TERM1` 让整句全大写，
  直接嵌入保留率最高且语法最自然。
- 第 2 层：五套内置词表 1478 条（石油 582、AI 213、软件 233、仪表 232、嵌入式 218），`Resources/Glossaries/*.csv`，
  build.sh 拷进 App；菜单分别开关 + 总开关。真机 100 句对照（`probe/domains.out`）：术语丢失 0。
  修正：调整了多条歧义词条（对齐/推理等泛词去掉、混合专家模型重复、信号隔离器、液位变送器、调节阀定位器、中文列里的英文写法）。
- 第 3 层：我的词表 `~/Library/Application Support/TranslateIME/glossary.csv`（BOM、模板、热重载 `FileChangeWatcher`）、
  导入 CSV/TSV/XLSX（`XLSXSheet` + 系统 unzip）、面板“纠正译法”（`CorrectionField`，⎋ 只关编辑器、焦点回输入框、
  剪贴板监测在编辑时不打断）。
- 测试 +38 个，`swift test`：**258 个测试，0 失败**；性能 0.024 ms/句（<1 ms）。
- 固定证书签名构建并重装：`--ax-status` → `AXIsProcessTrusted=true`；真机：纠正译法自测 320 ms 内译文更新、焦点回输入框；
  修改真实 glossary.csv 后 App 自动重新加载（日志 `glossary reload user=N`），测试行已删除、文件已恢复。

### 请手工验证
1. 菜单里能看到五套词表（带条数）和“打开我的词表”；关掉“石油工程”后“抽油机”不再强制译成 pumping unit。
2. 打开我的词表，加一行 `抽油机,beam pumping unit,,` 保存 → 不重启，翻译“检查抽油机”就用新译法。
3. 面板里选中一个词 → 点“纠正译法” → 填译法 ↩：译文立刻更新，光标回到输入框，可以继续打字。

## 更新：剪贴板监测剔除终端命令（评分制）

- 新增 `IMECore/ShellCommandDetector.swift`，在 `ClipboardTextFilter` 里新增忽略原因 `.shellCommand`（排在 codeLike 之前）。
- 每行打分，≥3 分算命令行；单行文本该行达标即剔除，多行文本命令行占 ≥50% 才剔除（反斜杠续行的下一行自动算命令行）。
  - 加分：提示符 `$ % # > ❯ ➜` 或 `user@host dir %`（+2）；首词是常见命令（ls/cd/git/brew/npm/pip/swift/xcodebuild/curl/docker/kubectl/sed/awk/tar/codesign/defaults/launchctl… 约 200 个，+3；
    make/open/find/cat/head/echo/swift/python 这类也是普通单词的 +2，后面跟 build/test/install 等子命令再 +1）；
    `./script.sh`、`/usr/bin/x` 开头（+2）；`FOO=bar cmd` 赋值前缀（每个 +3）；`-x` / `--foo` 参数、`| || && > >> 2>&1 ;`、
    `$VAR` `$()` 反引号（各 +2，封顶）；`~/`、`./`、`/abs`、`*.swift`、带扩展名的文件名、`a/b/c` 路径（+1，封顶 2）；`key=value`、续行 `\`。
  - 直接判 5 分的 shell 输出：git status/log/diff/push 输出、`path:行:列: error`、`fatal:/error:/warning:/hint:`、`zsh: command not found`、
    `ls -l` 行、Python Traceback、JS 调用栈、swift build 进度、`total N`、git log 的 Author/Date 头。
  - 减分（自然语言）：首词是首字母大写的普通单词（−2）；句末 `. ? !`（−2）；引号外的 the/you/please/to/for… 常用词（每个 −1，最多 −4）；
    ≥6 个普通单词且没有任何命令符号（−2）。引号内的内容（如 `git commit -m "fix the bug"`）不算自然语言。
  - 单独一个词：只有 ls、cd、git、npm、brew 这类不是英文单词的才剔除；单独的 swift、open、make 照常翻译。
- 测试：新增 `ShellCommandFilterTests`（73 条命令/输出样本全部剔除，28 条正常英文——含 Find/Make/Open/Go/Kill/Touch/Run 开头和小写
  “find the git log”“open the door”——全部照常翻译）；`swift test`：**262 个测试，0 失败**（未设置 DEVELOPER_DIR）。
- release 构建、固定证书签名重装：`--ax-status` → `AXIsProcessTrusted=true`。
- 真机 pbcopy 实测（运行中的输入法，看 placement.log 是否出现弹出记录）：git log、`cd … && swift test`、`$ brew install`、`find . -name`、
  `make install`、`open ~/Library/Input\ Methods`、`FOO=bar swift build`、`ps aux | grep`、git status 输出 → 均未弹出；
  “Can you find the git log for me?” → 正常弹出。剪贴板已恢复（文本内容一致）。

### 残留局限
- 没有任何命令特征的极短命令仍可能被当英文：如单独的 `make`、`top`、`echo hello`、`open Safari`（模糊命令名只有 2 分）。
- 一段英文里夹着命令（如 “Run npm install first.”）按句子翻译，这是有意的。
- 自然语言多、命令少的混合多行文本（命令行 <50%）仍会弹出。
