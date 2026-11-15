# 开发记录（YiKey，原工程名 Translate IME）

> 这是开发过程中的详细设计与验收记录，按时间追加，部分早期内容已被后面的章节更新。面向用户的说明见仓库根目录 README.md。

## 1. 关键难点：中文输入怎么办

macOS 同一时刻只有一个输入源在处理按键，输入法**不能叠加在系统拼音之上**。可行方案只有两类：

| 方案 | 做法 | 评价 |
|---|---|---|
| A. 内置拼音引擎 | IME 自己做 拼音→汉字（词库、切分、排序） | 需要大词库和排序算法，质量远不如系统拼音/搜狗；工作量大，与“翻译”主题无关 |
| **B. 热键翻译面板（选用）** | 全局热键 ⌃⌥T 唤起浮窗，在浮窗输入框里用**你正在用的系统拼音**打字；或先选中已有文本再按热键 | 复用高质量拼音，零词库；组词期间不翻译（`hasMarkedText` 判断），回车确认拼音后才翻译 |

**选 B**，并让 IME 本身负责英文侧：

- **英文组词模式**（本 IME 为当前输入源时）：打字母 → 下划线缓冲 + 光标处浮窗显示中文译文；`↩` 上屏原文，`⇥` 上屏译文，`⎋` 取消，空格追加（支持整句）。**`⌘V`**（2026-11-14 新增）：剪贴板里是英文时直接粘贴进组词并翻译；组词中按 ⌘V 追加到组词末尾；剪贴板是中文/纯数字/空/超过 500 字时不接管，应用照常粘贴。换行和制表符会变成空格。可在输入法菜单“⌘V 粘贴英文到组词并翻译”关闭。
- **翻译面板**（⌃⌥T，任何输入源下都可用）：输入框可打中文/英文。
  - **自动切到简体拼音**（2026-11-14 新增）：面板打开、输入框获得焦点时，自动切到**已启用**的“拼音 – 简体”（`com.apple.inputmethod.SCIM.ITABC`，没有则用其它已启用的简体拼音），关闭面板时恢复原输入源。只调用 `TISSelectInputSource`，不启用/添加输入源、不改系统设置。没有已启用的简体拼音时，输入框下方显示提示。可在输入法菜单“翻译面板打开时自动切到简体拼音”关闭。
  - **输入框自动变长**：随文字横向变长；超过 35 个汉字宽度才换行，换行后输入框变高、译文区域下移，不裁切。面板向右/向下长，靠近屏幕边缘时自动左移/上移。
  - **按键**（2026-11-14 21:00 更新）：
    - `↩` **复制译文并关闭**：复制到剪贴板，显示“已复制 ✓”约 0.5 秒后关闭面板、恢复原输入源、回到原应用，可直接 `⌘V`；下次打开输入框是空的（除非你在别处选中了文字，会自动预填）。翻译未完成时先显示“翻译中…”，就绪后复制再关闭；翻译失败则**不关闭**，显示错误。输入法菜单“复制后自动关闭面板”（默认开）关掉后，↩ 只复制不关闭。
    - `⇧⌥↩` **复制并清空**：复制译文，清空输入框，面板保持打开，继续输入下一句。
    - `⌥↩` 上屏译文（剪贴板 + 模拟 ⌘V，需要“辅助功能”授权）；`⌘↩`/`⇧↩` 上屏原文；`⎋` 关闭。
    - 拼音还在组词（有候选）时按 ↩ 交给拼音输入法确认拼音，不会复制。中文输入复制的是英文译文，英文输入复制的是中文译文。
  - **输入框**改为 NSTextView：高度 = 用同一套排版实测的文本高度（含拼音组词），始终从第一行开始完整显示，没有空白；超过 15 行才封顶并允许在框内滚动。
  - 支持 `⌘V`/`⌘C`/`⌘X`/`⌘A`/`⌘Z`（粘贴时换行变空格，粘贴后立即翻译）。
  - 有授权时，热键还会自动读取当前选中文本预填。

> 取舍说明：中文侧本质是“翻译面板”，IME 身份主要提供英文原位组词、进程常驻与菜单。如果以后想要“真·中文输入法”，在 `InputController.process` 里接入拼音引擎即可（方案 A 的扩展点），其余管线（翻译、浮窗、发音）不用改。

## 2. 架构

```
┌──────────────────────── IMECore（纯逻辑，可单测）────────────────────────┐
│ LanguageDetector  中/英判别（汉字数 vs 英文单词数；含假名→unknown）        │
│ TranslationProvider 协议 ──┬─ AppleTranslationProvider（本地，优先）       │
│                            ├─ BaiduTranslateProvider（在线备用）           │
│                            └─ LibreTranslateProvider（在线备用/自建）      │
│ TranslationService(actor)  按序回退 · 超时 · 缓存 · 取消不回退             │
│ TranslationCoordinator     防抖 200ms(150–300 可配) → phase；LRU 缓存同步命中   │
│                            pronounceTapped() ← 全工程唯一 speak 入口       │
│ SpeechService              AVSpeechSynthesizer，en-US                      │
│ CompositionBuffer          按键状态机（纯逻辑，可测）                       │
│ TranslationCache           线程安全 LRU，主线程可同步命中                   │
│ LatencyMonitor + Sinks     延迟统计/预算告警/os_log/文件日志                │
│ VocabularyBook(actor)      单词本：去重、计数、后台防抖落盘、导出           │
│ IMESettings / Factory      在线备用默认关闭，缺凭据则不联网                │
└────────────────────────────────────────────────────────────────────────┘
┌──────────────────────── TranslateIME（IME 外壳）─────────────────────────┐
│ main.swift            IMKServer 启动；--install 注册/启用输入源           │
│ InputController       IMKInputController：英文组词、marked text、上屏    │
│ PanelController       NSPanel(非激活) + SwiftUI：候选模式 / 翻译器模式    │
│ AppleTranslationBridge  把 SwiftUI .translationTask 包装成 async 调用     │
│ HotKeyManager         Carbon 全局热键 ⌃⌥T（无需权限）                     │
│ PasteCommitter        剪贴板 + ⌘V；SelectionReader 读选中文本（AX）       │
└────────────────────────────────────────────────────────────────────────┘
```

**翻译优先级**：Apple 本地（离线）→ 在线备用（仅当你启用并配置）。
- macOS 15+：Translation 框架可用。**macOS 14 没有可编程的 Translation API**，Apple provider 自动“不可用”，直接走在线备用；没配置则面板提示原因。
- 首次使用需下载语言包：系统设置 › 通用 › 语言与地区 › 翻译语言… 下载“中文(简体)”和“英语”。下载需要访问 Apple 服务器，网络不通时会失败并回退到在线备用。
- 备用接口默认**关闭**：关闭或缺凭据时代码路径根本不会产生网络请求（有测试）。

**发音**（2026-11-14 更新）：只读“英文那一侧”。中→英时英文**译文**旁有 🔊；英→中时英文**原文**旁有 🔊（候选浮窗里在原文右侧，翻译面板里在输入框右侧）。**只有点击**才调用 `AVSpeechSynthesizer`（`en-US`）。翻译完成、上屏、关闭、切换都不会播放；中文（无论是原文还是译文）永远不发音。🔊 用不抢焦点的 AppKit 按钮（`acceptsFirstMouse`、不成为第一响应者、不让浮窗变 key），点击不会提交组词、也不会上屏。`PronunciationTests` 里还有一个静态扫描测试，保证 `.speak(` 只出现在 `pronounceTapped` 内。

## 3. 目录（含新增 LatencyMonitor / TranslationCache / CompositionBuffer / Vocabulary）

```
Package.swift
Sources/IMECore/…            语言判别、翻译服务/提供者、发音、协调器
Sources/TranslateIME/…       IME 外壳与 UI
Resources/Info.plist         IMK 配置（连接名、控制器类、输入模式）
Resources/*.lproj            输入源显示名
scripts/build.sh install.sh uninstall.sh make_icon.swift
Tests/IMECoreTests/…         单元测试
```

## 4. 编译、安装、启用

前置：Xcode 16+（需要 macOS 15 SDK 才有 Translation 框架），Apple Silicon。

```bash
cd TranslateIME
# 0) 改成你自己的 Bundle ID（可选但推荐）：
#    Resources/Info.plist、Resources/*.lproj/InfoPlist.strings、Sources/TranslateIME/main.swift 里的
#    com.example.inputmethod.TranslateIME(.Translate) 全部替换

swift test                 # 单元测试
scripts/build.sh           # 生成 build/TranslateIME.app（arm64，ad-hoc 签名）
scripts/install.sh         # 复制到 ~/Library/Input Methods
```

启用：
1. **注销并重新登录**（新输入法通常需要这一步才会出现在列表）。
2. 系统设置 › 键盘 › 文字输入 › 输入法 › 编辑… › `+` › 搜索 “Translate IME” 添加。
   （或：`~/Library/Input\ Methods/TranslateIME.app/Contents/MacOS/TranslateIME --install`）
3. 用 ⌃Space / 菜单栏切换到 “译 · Translate IME”。
4. 菜单栏输入法图标 › “授予辅助功能权限…”（读取选中文本、自动粘贴需要；不授权也能用，只是退化为复制到剪贴板）。
5. 首次翻译前下载语言包（见上）。

可选，配置在线备用（以百度为例，国内可用，需自行申请 appid/密钥）：
```bash
defaults write com.example.inputmethod.TranslateIME baiduAppID  -string "你的appid"
defaults write com.example.inputmethod.TranslateIME baiduSecret -string "你的密钥"
# 然后在输入法菜单里勾选“启用在线备用翻译”
# 自建 LibreTranslate：onlineProvider=libretranslate, libreTranslateURL=http://host:5000
```
> 注意：启用在线备用后，输入文本会发送到对应服务。密钥目前存 UserDefaults，正式使用建议改 Keychain。

卸载：`scripts/uninstall.sh`。调试：改代码后 `scripts/build.sh && scripts/install.sh`，进程会被 `pkill` 重启（必要时在菜单里重新选择输入源）。

## 5. 单元测试

`swift test`，覆盖：
- **语言判别**：纯中/英、中英混排的主导判定、数字/标点/空串、含假名。
- **翻译接口**：中→英/英→中方向路由、回退链、不可用跳过、超时回退、全失败抛最后错误、无 provider、**取消后不回退**、缓存；百度签名(MD5)/表单编码/错误响应；LibreTranslate 解析；在线备用默认关闭。
- **发音只在点击时触发**：翻译完成不发音、多次更新/重置不发音、点击才发音（且次数正确）、英文→中文无发音、idle/loading/failed 点击无效、utterance 语音为 `en-US`、源码静态守卫。

UI 层（InputController / 浮窗 / Apple Translation 桥）依赖系统运行时，用下面的手工清单验收。

## 6. 手工验收清单

**基础**
- [ ] 注销后能在输入法列表找到 “译 · Translate IME”，可添加并切换，菜单栏显示“译”图标。
- [ ] 切到其它输入法后，⌃⌥T 仍能唤起面板（进程常驻；若不行，见“已知风险”）。

**英文组词（切到本 IME）**
- [ ] 在 TextEdit 输入 `hello` → 下划线缓冲 + 光标下方浮窗出现，约 0.3s 后显示“你好”；英文原文 `hello` 右侧出现 🔊，**不点就没有声音**，中文译文旁没有 🔊。
- [ ] 点原文旁的 🔊：读出美式 “hello”；下划线组词仍在、没有上屏任何文字、光标仍在宿主应用里，可以继续打字；单词本里出现 hello / 你好，再点一次播放次数 +1。
- [ ] `↩` 上屏 `hello`；再输入 `good morning` → `⇥` 上屏中文；`⎋` 取消并消除下划线。
- [ ] 空格可继续输入整句；`⌫` 逐字删除，删空后浮窗消失。
- [ ] 译文未出现时按 `⇥` 只响提示音、不上屏。
- [ ] 输入 `⌘C` 等快捷键：先上屏已输入原文，快捷键照常生效。
- [ ] 光标靠近屏幕底部时，浮窗自动出现在光标上方；多显示器位置正确。
- [ ] 点浮窗里的“上屏译文/上屏原文”按钮可用，且宿主应用不失焦。
- [ ] 数字、标点开头（如 `1.`、`,`）直接输入，不进入组词。

**翻译面板（⌃⌥T）**
- [ ] 弹出并自动聚焦输入框；用系统拼音输入“你好”：打拼音过程中**不**翻译，回车确认后才翻译，显示 “Hello” 与 🔊。
- [ ] 点 🔊 → 美式发音；不点绝不出声；连续点击重新播放；关闭面板不残留声音。
- [ ] 输入整句中文 / 中英混排（如 `iPhone 手机`）→ 方向正确；纯数字提示“无法识别语言”。
- [ ] `↩` 上屏译文、`⌘↩` 上屏原文到之前的应用（已授权辅助功能时自动粘贴并恢复原剪贴板；未授权时只复制并弹授权提示）。
- [ ] `⎋` 关闭并回到原应用；再次 ⌃⌥T 再次切换。
- [ ] 已授权时：先在别的应用选中一段中文再按 ⌃⌥T，面板自动预填并翻译。
- [ ] 若 IME 为当前输入源，面板输入框里按键直接放行（需要打中文时请先切到系统拼音）。

**离线 / 回退**
- [ ] 断网 + 已下载语言包：翻译正常，来源标签 “Apple 本地翻译（离线）”。
- [ ] 未下载语言包：系统弹出下载提示；8 秒无结果则提示失败或回退到在线备用。
- [ ] 启用在线备用且配置密钥后，关闭语言包/断开本地可用性时，来源标签变为“百度翻译（在线）”；未启用时用抓包确认**没有任何网络请求**。
- [ ] macOS 14：Apple provider 不可用，在线备用接管；未配置时提示信息清晰。

**稳定性**
- [ ] 快速连续输入，不闪烁、不出现旧结果覆盖新结果。
- [ ] 在 Safari、Chrome、微信、VS Code、终端、全屏应用中均能出现浮窗、上屏正确。
- [ ] 长时间运行 + 反复切换输入源，无崩溃、内存无明显增长。

## 7. 输入流畅度设计（硬性要求：单次按键主线程 < 5ms）

**按键路径（`InputController.handle`，主线程同步）只允许做 3 件事**，其余全部延后：

| 步骤 | 位置 | 成本 |
|---|---|---|
| NSEvent → `ComposeKey` → `CompositionBuffer` 状态机 | 同步 | 微秒级 |
| `setMarkedText`（对宿主应用的 IPC，任何输入法都必须做） | 同步 | 由宿主决定，单独记为 `clientIPC` |
| 登记“稍后更新浮窗”（多次按键合并成一次主线程异步更新） | 同步 | 微秒级 |

被移出按键路径的工作：
- **取光标矩形**（IPC）：每次组词只取一次并缓存，停笔 250ms 后才刷新；
- **`coordinator.update`**：在合并后的异步更新里执行——先同步查 LRU 缓存（命中即刻 ready，无防抖），未命中才起后台任务；
- **翻译**：防抖 200ms（`defaults write … debounceMs -int 150~300`）→ `TranslationService` actor（后台）→ 回主线程只做一次赋值；新输入会 **取消** 旧任务，且用 `generation` 计数保证过期结果绝不覆盖新结果；
- **SwiftUI 布局**：状态变化后节流 ≥16ms 才布局一次，且窗口几何只在尺寸/位置变化时才更新；去掉了转圈动画；
- **启动预热**：`AppContext.start()` 在启动时创建浮窗视图树、合成器，预读单词本、预查 Apple 语言可用性（并带 30s 缓存），避免“第一次按键”变慢。

**延迟日志**（`LatencyMonitor`，record 为一次加锁 + 环形缓冲写入，可放在按键路径上）

| 指标 | 含义 | 预算 |
|---|---|---|
| `keyHandling` | `handle()` 全程 | **5 ms** |
| `clientIPC` | setMarkedText / 取光标 | 3 ms |
| `panelUpdate` | 浮窗布局一次 | 8 ms |
| `keyToPanel` | 按键 → 浮窗状态更新 | 50 ms |
| `translation` | 最后一次输入 → 译文就绪（含防抖） | 不设 |
| `providerCall` | 单次翻译调用（后台） | 不设 |
| `vocabularyWrite` | 单词本落盘（后台） | 100 ms |

超预算 → `os_log` 警告；每 500 次按键输出一次 p50/p95/p99/max 汇总。日志里只含长度、provider 名等元数据，**不含用户输入的文字**。
```bash
# 实时查看
log stream --predicate 'subsystem == "com.example.inputmethod.TranslateIME" && category == "latency"' --level debug
# 同时写文件 ~/Library/Logs/TranslateIME/latency.log（1MB 轮转），并记录每一次采样：
defaults write com.example.inputmethod.TranslateIME latencyFileLog -bool true
defaults write com.example.inputmethod.TranslateIME latencyVerbose -bool true   # 可选
```
也可在输入法菜单里 “复制延迟报告” 直接得到统计表。

> 诚实说明：`setMarkedText`/取光标属于对宿主应用的进程间调用，耗时取决于宿主，单测无法复现。单测验证的是我们自己的同步逻辑；整体是否 < 5ms 以真机 `keyHandling` 指标为准。若某个宿主（如个别 Electron 应用）的 `clientIPC` 本身就超标，日志里会一眼看出是哪一段。

## 8. 单词本

- **触发**：只有点击 🔊 发音按钮才会加入（翻译完成、上屏、关闭都不会）。中→英点译文旁的 🔊、英→中点原文旁的 🔊 都会加入，记录的“英文”是英文那一侧，“中文”是中文那一侧，两个方向的同一英文共用一条。每次点击：不存在则新增，存在则 `playCount + 1` 并更新 `lastPlayedAt`。
- **记录内容**：英文、中文原文（同一英文的其它中文原文放 `otherChinese`）、首次加入时间、最近播放时间、播放次数。
- **去重**：英文归一化后比较（合并空白、统一弯/直撇号、去首尾标点、小写）：`Hello!` / ` hello ` / `HELLO` 是同一条；展示文本保留首次写法。
- **存储**：`~/Library/Application Support/TranslateIME/vocabulary.json`（`{"version":1,"entries":[…]}`，日期为 ISO8601，秒精度）。
- **不影响输入**：`pronounceTapped` 在主线程只做“播放 + 派发后台任务”；去重/计数/落盘都在 `VocabularyBook` actor 的后台执行器上；写入 0.3s 防抖合并，原子写（`.atomic`）；文件损坏时改名为 `vocabulary.corrupt-<时间戳>.json` 保留，不覆盖。
- **菜单栏入口**（输入法菜单）：查看单词本…（搜索/删除/刷新/导出）、导出为 CSV（UTF-8 BOM，Excel 可直接打开，含公式注入防护）、导出为 JSON、在 Finder 中显示文件。
- 隐私：单词本只存本地；翻译文本是否出网只取决于你是否启用了在线备用。

## 9. 单元测试（`swift test`）

在第 5 节基础上新增：
- **PerformanceTests**：慢 provider / 线程被卡死的 provider 下连续输入 240 字，按键同步逻辑 p95/p99 < 5ms；防抖把突发输入合并成 1 次调用；过期结果不覆盖新结果；reset 后取消的请求不发布；缓存命中同步出结果且不调 provider；LRU 淘汰；缓存查询 < 50µs；状态机吞吐；语言判别耗时。
- **LatencyMonitorTests**：百分位、环形窗口、预算告警（等于预算不算超）、周期汇总、线程安全、防抖设置钳制。
- **CompositionBufferTests**：开始组词规则、整句累积、↩/⇥/⎋/⌫、组合键与其它键。
- **VocabularyTests**：首次加入、重复点击计数、归一化去重、同英文不同中文、空输入忽略、200 并发计数准确、跨实例持久化、record 不同步写盘/flush 才写、防抖后台落盘、100 次点击合并写入、JSON 结构、损坏文件隔离、删除、CSV（BOM/转义/防注入）与 JSON 导出往返。
- **VocabularyIntegrationTests**：点击发音才入库且计数正确；英→中点击原文 🔊 也入库（英文=原文、中文=译文），两个方向同一英文共用一条；英→中不点击不入库；不点击不产生文件；5000 条的大词库下 `pronounceTapped`（两个方向）主线程开销 < 5ms。
- **PronunciationTests**（更新）：英→中只在点击时读英文原文、不自动读；连续输入/重置都不读；两个方向都绝不读中文；`pronunciationText` 方向正确；加载中点击无效。
- `PronunciationTests` 的静态守卫仍然成立：`.speak(` 只出现在 `pronounceTapped` 内。

> 计时类断言在负载很高的 CI 上可能抖动；本机跑时请关闭其它重负载。`max` 的阈值（25ms）是抖动上限，`p95/p99 < 5ms` 才是硬指标。

## 10. 新增手工验收清单

**流畅度**
- [ ] 开启 `latencyVerbose` 后，在 TextEdit / Safari / Chrome / VS Code / 微信 中各连续快速输入 200 字符，`keyHandling` 的 p95 < 5ms；若超标，对照 `clientIPC` 判断是否宿主造成。
- [ ] 按住字母键连发（重复输入）时，下划线与浮窗源文本无卡顿、无丢字。
- [ ] 一直打字不停笔时，不出现任何译文闪烁；停笔约 0.2s 后译文出现；继续打字旧译文不会“回跳”。
- [ ] 重复输入同一个词（命中缓存）：译文几乎瞬间出现（无 200ms 等待）。
- [ ] 断网、翻译很慢或失败时，打字手感不受影响（只是浮窗里显示失败原因）。
- [ ] 第一次按键（刚登录/刚切到本输入法）不卡。
- [ ] 浮窗里没有持续转圈动画；活动监视器里本进程空闲 CPU ≈ 0%。
- [ ] 速度对比：同一应用中切换到系统拼音/ABC 与本 IME，主观上无差别。

**单词本**
- [ ] 翻译后不点 🔊：单词本无新增、磁盘无 vocabulary.json。
- [ ] 点 🔊 一次：菜单“查看单词本…”出现该英文 + 中文原文 + 次数 1 + 时间；再点两次：次数 3，仍只有一条。
- [ ] `Hello` / `hello!` 去重为一条；同一英文换另一种中文原文不新增行。
- [ ] 狂点 🔊 时打字、浮窗不卡。
- [ ] 注销/重启后单词本仍在；用文本编辑器打开 JSON 结构正确。
- [ ] “导出 CSV…” 用 Excel/Numbers 打开中文不乱码；“导出 JSON…” 内容正确；“在 Finder 中显示” 能定位文件。
- [ ] 手工把 vocabulary.json 改坏后再点 🔊：旧文件被改名为 `vocabulary.corrupt-*.json`，新条目正常写入。
- [ ] 英文→中文（无 🔊）不会产生任何单词本记录。

## 12. 剪贴板英文监测（兼任翻译软件）

和英文应用聊天时：
1. 在对方消息上 **⌘C** → 右上角自动弹出“📋 剪贴板英文”面板：英文原文 + 中文译文（Apple 本地翻译），🔊 点击读英文并记入单词本。
2. 按 **↩**（或点“用中文回复”、⌃⌥T）→ 变成回复框：自动切到简体拼音，原文以小字留在上方。
3. 输入中文，按 **↩** → 英文译文已复制，面板关闭，回到原应用、恢复原输入法 → **⌘V** 发送。
4. **⎋** 关闭；在面板出现时直接继续打字，面板会关闭并把按键还给原应用（需辅助功能授权）。

不会弹出的情况：TranslateIME 自己复制的内容、密码管理器（Concealed/Transient/AutoGenerated 类型）、
仅链接/邮箱、文件路径、纯数字、代码、少于 2 个字母或超过 2000 字符、与上一次相同、中文；
正在用翻译面板或正在组词时也不打扰。

菜单：“监测剪贴板英文并自动翻译”（默认开）、“暂停剪贴板监测 1 小时 / 恢复”。
开销：每 0.5 秒只读一次剪贴板计数（约 0.1 µs），空闲 CPU ≈ 0。

**验收清单**
- [ ] 在 Safari/微信/Slack 复制英文 → 面板弹出、译文正确；原应用的光标和输入法没被切走。
- [ ] 面板出现后按 ↩ → 回复框、拼音已切换；打中文 ↩ → “已复制 ✓” 后关闭，回原应用 ⌘V 得到英文。
- [ ] 复制译文 / 上屏之后不会再弹出“剪贴板英文”面板。
- [ ] 1Password 等复制密码 → 不弹；复制链接、路径、代码、电话号码 → 不弹。
- [ ] 菜单关闭监测 / 暂停 1 小时后复制英文 → 不弹；恢复后正常。

## 13. 面板跟随输入框 + ↩ 自动填入

- 面板出现在当前应用光标（或输入框）的正下方；靠近屏幕底部时出现在上方；始终在屏幕内，不挡住正在输入的那一行。
  取光标位置：TranslateIME 是当前输入法时用 IMK；否则需要**辅助功能**授权（AX）；都没有时用原来的位置。
- 回复框/⌃⌥T 面板里按 **↩**：英文自动填进原应用的输入框（不用再 ⌘V），**不会替你按回车发送**，确认后自己按回车发送。
  - TranslateIME 是原应用的当前输入法 → 直接插入；
  - 否则需要辅助功能授权 → 自动 ⌘V，0.5 秒后恢复你原来的剪贴板；
  - 未授权 → 只复制并提示“已复制，请 ⌘V（开启辅助功能可自动粘贴）”。
- 菜单“回车后自动填入原输入框”（默认开）；⇧⌥↩ 复制并清空（面板保持）等其他按键不变。

**开启辅助功能**：系统设置 › 隐私与安全性 › 辅助功能 › “+” → 选 `~/Library/Input Methods/TranslateIME.app` 并打开开关
（或输入法菜单“授予辅助功能权限…”）。注意：本 App 是 ad-hoc 签名，**每次重新编译安装后都要在列表里把 TranslateIME 删掉再加一次**，
否则系统仍认为未授权（运行过 scripts/setup_signing.sh 后不再需要，见第 14 节）。检查：`open -g -n ~/Library/Input\ Methods/TranslateIME.app --args --ax-status /tmp/ax.txt; cat /tmp/ax.txt`

**验收清单**
- [ ] 在 TextEdit/备忘录里光标放在屏幕中部按 ⌃⌥T：面板在光标下方；光标移到屏幕底部再按：面板在上方；靠右边时面板不出屏。
- [ ] 复制英文 → 面板出现在当前输入框附近（需辅助功能，或 TranslateIME 为当前输入法）。
- [ ] 回复：↩ → 输入中文 → ↩：英文出现在原输入框里，没有被发送；剪贴板仍是原来的内容。
- [ ] 关闭辅助功能后重复：提示“已复制，请 ⌘V…”，⌘V 可粘贴。
- [ ] 菜单关闭“回车后自动填入原输入框”：↩ 恢复为复制并关闭。

## 14. 剪贴板面板的位置（锚点链）与签名

复制英文后面板依次尝试：选中的文字（需辅助功能）→ 光标 → 输入框 → **鼠标右下方** → 前台窗口下三分之一 → 右上角。
每次实际用了哪种，见 `~/Library/Logs/TranslateIME/placement.log`（只有坐标和策略，不含文字）。

**辅助功能授权在重装后保持**：先运行一次 `bash scripts/setup_signing.sh`（本机专用钥匙串 + 自签名证书，无需 sudo），
之后 `scripts/build.sh` 都用同一证书签名。第一次从 ad-hoc 换成证书签名后需要在 系统设置 › 隐私与安全性 › 辅助功能
里把旧的 TranslateIME 删掉、重新添加并打开，此后不再需要。

## 15. 回复时自动找到原应用的输入框（↩ 第二次）

问题：复制英文时焦点在聊天记录上，↩ 回复后英文没有落到输入框。现在的流程：

1. 剪贴板触发面板（或 ⌃⌥T 打开面板）时，记住来源应用的 pid 和当时的焦点窗口（`ReplySource`）。
2. 回复模式下按最后一次 ↩ 后：
   - 英文**始终写入剪贴板并保留**（不再还原旧剪贴板；带私有类型 + changeCount 标记，不会再次触发翻译面板）。
   - 激活来源应用并把记住的窗口置前（AXRaise / AXMain）。
   - 找输入框：当前焦点元素可编辑就直接用；否则在该窗口的辅助功能树里搜索（最多 0.3 秒 / 深度 30 / 4000 个节点，
     Electron 应用找不到时会打开 `AXManualAccessibility` 再搜一次），选**最靠下、最宽、可编辑、已启用**的输入框；
     跳过搜索框、密码框、只读文本；占位符像“消息 / message / reply / 输入”的优先；超过半个窗口高的大编辑区降权。
   - 聚焦：先 `AXFocused`，失败且已授权辅助功能时，在选中输入框中心单击一次。
   - 插入：优先设置 `AXSelectedText` 并读回校验；不行再发一次 ⌘V（发送前确认来源应用仍在最前且输入框已聚焦）。
   - **从不按回车、不按任何发送键**，只把英文放进输入框，由你自己确认后发送。
3. 提示：成功显示“已填入输入框（已同时复制）”；找不到显示“未找到输入框，已复制，请 ⌘V”。
4. `~/Library/Logs/TranslateIME/placement.log` 会记一行 `reply …`（结果、策略、候选数、选中控件的角色和位置、耗时），**不含文字内容**。

自测：`TranslateIME.app/Contents/MacOS/TranslateIME --selftest-reply <输出文件> <pid> <文字>`，
配合 `scripts/reply_scratch_app.swift`（模拟聊天窗口：顶部搜索框、密码框，中间只读记录（初始焦点），底部 “Type a message”）。

## 16. 回复时复制别的英文 → 立即切回英文阅读

在中→英回复（或 ⌃⌥T 中文输入）状态下，从别的地方复制了**新的英文**，面板会立即切回“英文 → 中文”阅读状态：
显示新英文、中文译文和 🔊，面板移到新复制的位置旁边，回复要填回的“来源应用/窗口”也换成新复制的地方。

- 只有满足原有过滤条件的**外部**英文才会打断：TranslateIME 自己写的剪贴板（私有类型 + changeCount 登记）、
  和面板正在显示/回复的英文**相同**的文字、网址、路径、数字、代码、密码类内容都不会打断。
  在面板里自己 ⌘C（TranslateIME 在前台）也不会打断。
- 半截中文草稿会**暂存**：之后对**同一来源**（同一应用 + 同一窗口）按 ↩ 回复时自动恢复；按 ⎋ / 关闭面板时丢弃。
- 正在用拼音组词（还有未确认的拼音）时也会切换：只在面板自己的输入框里取消这次组词（丢掉未确认的拼音字母，
  已上屏的汉字留在草稿里），不会向任何其他应用插入文字。
- 旧回复里还没完成的翻译 / 填入会被取消（不再找框、不再点击、不再 ⌘V）。
- 离开回复模式时恢复原来的输入法；再按 ↩ 回复时重新切到简体拼音。
- `placement.log` 记一行 `clipboard kind=overrideReply leftReply=1 draftStashed=1 …`（不含文字）。

实现：`IMECore/ClipboardWatcher.swift`（`ClipboardPanelState` / `ClipboardTriggerKind`）、`IMECore/ReplySession.swift`
（来源更新、草稿暂存/恢复/丢弃）、`FloatingPanel.showReading`。自测：`--selftest-override <输出> <pid> <英文>` 配合 pbcopy。

## 17. 离线术语表（术语保护 · 五套内置词表 · 我的词表）

全部离线，不联网、不用大模型。翻译前在原文里找出术语，把它换成**标准译法**再交给 Apple 本地翻译，译完检查术语都还在。

### 第 1 层：术语保护（中→英、英→中都做）
- 查找：中文用字典树（最长匹配，从左到右）；英文按整词匹配，不分大小写、认单复数（units / unit），支持多词术语。
  缩写（≥2 个大写字母，或大写+数字：CAN、ESP、I2C、LoRA、IoT、DevOps）**区分大小写**：can ≠ CAN、cot ≠ CoT；英→中时缩写默认原样保留。
- 方式（本机实测后选定）：
  1. **首选：直接嵌入目标术语**——中文句子里嵌英文术语（“检查pumping unit的strokes per minute”），英文句子里嵌中文术语。
     实测 12/12 保留，而且语法最自然（会自动补 the、介词）。
  2. **回退：占位符**——嵌入后有术语丢失，就用 `ZQXA`、`ZQXB`… 再译一次（10 种写法实测都 17/17 保留；ZQX+字母最不容易被改写），
     还原时容忍大小写变化和插空格（`zqx a`、`Z Q X B`），并补回被粘连的空格；两次取丢得少的。
  3. 整句就是一个术语：直接给出标准译法，不调用翻译引擎。
  4. 收尾：英文 a/an、句首大写；中文术语两边不留多余空格。
- 性能：1478 条全部启用时建索引约 29 ms（后台、启动时一次）；查表+生成方案 **0.024 ms/句**（调试版测试）、真机 0.02–0.06 ms/句；
  全在翻译 actor 上，不在按键路径上。词表变化时清空译文缓存。

### 第 2 层：五套内置词表（菜单里可分别开关，默认全开）
| 词表 | 条数 | 重点 |
|---|---|---|
| 石油工程（采油·注水·地面集输） | 582 | 抽油机、冲次、示功图、含水率、注水井、配注、集输、计量间、联合站、修井、压裂… |
| 人工智能 | 213 | 大语言模型、思维链、检索增强生成、LoRA、量化、幻觉… |
| 计算机 / 软件 | 233 | 单元测试、持续集成、合并请求、连接池、重构、微服务… |
| 仪器仪表与传感器 | 232 | 变送器、量程/零点、标定、涡街/电磁流量计、热电偶、定位器… |
| 单片机 / 嵌入式硬件 | 218 | 单片机、ADC、UART/SPI/I2C、CAN 总线、看门狗、晶振、引导程序… |

文件：`Resources/Glossaries/glossary-<领域>.csv`（列：zh,en,zh_alt,en_alt,flags,note；同义写法用 `|`）。
已做：停用词（“系统、数据、压力、well、pump、unit…”这类太宽泛的词不替换）、单字词不收、中英冲突检查（测试里也会检查）、
`z2e`（只用于中→英，如英文是普通词）、`x`（英→中时缩写也译成中文，如 SPM → 冲次）。

### 第 3 层：我的词表（优先级最高）
- 文件：`~/Library/Application Support/TranslateIME/glossary.csv`，列 **中文,英文,领域,备注**，UTF-8 带 BOM（Excel/Numbers 直接打开不乱码）。
  不存在时自动创建（带两行示例，可删）。多个写法用 `|`：`功图计产|功图量油`。用户词条不受停用词限制（单字也可以）。
- **保存后自动生效**（监视文件，约 0.3 s 内重新加载），不用重启。
- 菜单：`打开我的词表（N 条）`、`导入词表…（CSV / TSV / XLSX）`（同一中文的行会被更新，其余追加；CSV 支持 UTF-8 / GB18030）、
  `重新加载词表`、`术语保护（离线术语表）` 总开关、五套词表各自的开关（显示条数）。
- 面板里的 **纠正译法**：译文下方点“纠正译法”→ 出现两栏（原词 / 正确译法）。原词自动取输入框里选中的文字（没选中且整段很短时取整段），
  ↩ 保存 → 写入我的词表、立即重建索引并重新翻译；⎋ 只关闭这个小编辑器；保存或取消后光标回到原来的输入框。
- 结果行显示“Apple 本地翻译（离线）· 术语 N 个”。

### 实测（真机 Apple 本地翻译，五个领域各 20 句，中英各半）
术语全部保住（丢失 0）；100 句里 93 句走“嵌入”，5 句走“占位符回退”，2 句没有术语。例子：

| 原文 | 不用词表 | 用词表 |
|---|---|---|
| 请检查3号井抽油机的冲次和冲程。 | …check the flush and stroke of the No. 3 well oil pump. | …check the strokes per minute and stroke length of the pumping unit of well No. 3. |
| 示功图显示这口井供液不足，泵效只有35%。 | The power diagram shows… | The dynamometer card shows… insufficient fluid inflow… pump efficiency… |
| 本月含水率上升到92%，需要调整注水井的配注量。 | The water content… the filling amount of the injection well… | This month's water cut… the injection allocation of water injection well… |
| The sucker rod pump shows a fluid pound on the dynamometer card. | 吸杆泵在测力计卡上显示液体磅。 | 有杆泵在示功图上显示一个液击。 |
| The gathering system needs a pigging run to remove paraffin deposition. | 收集系统需要一个猪圈来去除石蜡沉积物。 | 集输系统需要清管运行来去除结蜡。 |
| 智能体会调用工具完成多步骤任务。 | Intelligent experience calls tools… | The agent will call the tool… |
| Prompt engineering improves zero-shot performance. | 及时工程改善了零射击性能。 | 提示工程提高零样本学习性能。 |
| The level transmitter uses guided wave radar. | 液位发射器使用导波雷达。 | 液位变送器使用导波雷达。 |
| 单片机通过SPI读取模数转换器的数据。 | The single-chip computer reads… analog-to-digital converter… | Microcontroller reads the data of ADC through SPI. |

完整对照：`probe/domains.out`（列：方向、原文、不用词表、嵌入后的原文、用词表、统计）。
重跑：`TranslateIME --selftest-translate probe/domains.tsv probe/domains.out --glossary`。
纠正译法自测（用临时词表，不碰真实词表）：`TRANSLATEIME_GLOSSARY_FILE=/tmp/x.csv TranslateIME --selftest-correct out.txt`。

已知局限：占位符回退时冠词可能缺（“has memory leak”）；句首术语有时少了 The；术语之外的部分仍由 Apple 翻译决定。

## 11. 已知风险（请重点验证）

1. **`.translationTask` 桥**：Translation 的可编程 API 只能经由 SwiftUI 修饰器拿到 session，宿主视图必须在可见窗口里。桥已处理取消/重入，但在“非激活浮窗 + 后台 App”下的行为（尤其是首次下载语言包的系统提示，需要窗口作为锚点）需要在 15/26 上实测。若有问题，macOS 26 可考虑改用其公开的直接构造 `TranslationSession` 的 API（以 26 SDK 文档为准）。
2. **非激活面板取得键盘焦点**：翻译器模式用了 `NSApp.activate` + 可成为 key 的 `.nonactivatingPanel`，并在关闭时恢复前台应用；不同应用下的焦点/粘贴时序需要实测，必要时调大 `PasteCommitter` 里的 0.2s 延迟。
3. **IME 进程是否常驻**：热键依赖 IME 进程在后台存活。系统通常在输入源被选中后保持其进程，但不保证；若发现热键失效，可把 TranslateIME.app 加入“登录项”。
4. **Info.plist 的 IMK 键**与 Bundle ID 命名需与你替换后的值保持一致；改名后需注销重登。
5. **macOS 14.0–14.3** 没有 Translation.framework，App 无法启动；建议最低 14.4。
6. 代码按 Swift 5 语言模式 + Xcode 16 编写（`MainActor.assumeIsolated` 包住所有 IMK 回调）。
7. **IMK `bundleIdentifier()` 与 `attributes(forCharacterIndex:)` 是否为 IPC** 取决于系统实现；我已把它们移出按键路径（激活时取一次 / 异步取一次并缓存），但仍建议用 `clientIPC` 指标实测。
8. 单词本日期为秒精度；多个 IME 进程同时写同一文件（多用户会话共享主目录的极端情况）未做文件锁。
