# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目

Open Mouse：macOS 菜单栏鼠标增强工具，滚轮平滑、独立反向、按键与手势映射。纯 `CGEventTap`，无内核扩展、无驱动。

SwiftPM 构建（**没有 Xcode 工程**），单一可执行 target，AppKit 生命周期 + `NSHostingView` 装 SwiftUI 设置界面。`Package.swift` 里 `swift-tools-version: 6.0` 但 `.swiftLanguageMode(.v5)`，见下面「约定」。发布在 <https://github.com/tarnish233/OpenMouse>。

## 命令

```bash
make app      # swift build -c release + 组装正式名称的 .app → build/Open Mouse.app
make debug    # 独立测试包 → build/Open Mouse Debug.app
make debug-run # 构建并启动测试包；日常硬件/UI 测试必须用它，不能启动正式名称的包
make run      # 构建并启动正式名称的本地包，仅用于明确的发布前验证
make install  # 拷到 /Applications 并启动（登录项注册必须装在这里才生效）
make test     # 应用自检 332 项 + 更新助手自检 + 正式/社区发布签名检查，必须全过
CODESIGN_IDENTITY=<Developer ID 证书 SHA-1> make dist  # 严格发布签名、校验后打 zip + sha256
make clean
make tcc-reset  # 忘掉辅助功能授权，换过签名身份或授权变成幽灵项时用
```

只想快速编译看有没有语法/类型错误：`swift build -c release`（不组装不签名，最快）。

版本号的唯一来源是 `Resources/Info.plist` 的 `CFBundleShortVersionString`，`make dist` 从那里读。更新版本比较返回三态（新/不新/无法判断），无法解析时必须报失败且不能写入 24 小时抑制时间。自动检查由一次性定时器按持久化时间安排，并在系统唤醒后重新核对；不能只在启动时调用一次。

### 跑测试

```bash
make test                                        # 等价于 swift run -c debug OpenMouse --self-check
"build/Open Mouse.app/Contents/MacOS/OpenMouse" --self-check   # 对已构建/已安装的包做诊断
```

返回码即结果，失败会打出哪一条断言挂了。

**没有办法从命令行只跑一个检查。** `SelfCheck.run()` 里是 17 个 `group("名字") { ... }` 顺序执行，没有过滤参数。要单独跑一组，临时注释掉 `run()` 里其他的 `group(...)` 调用——不要为了图快改断言本身。

### 调试

```bash
OpenMouse --verbose                  # 事件管线计数实时打到 stderr
OpenMouse --tab buttons              # 启动即打开指定设置页（scroll/buttons/apps/general）
OpenMouse --check-update owner/repo   # 走真实网络检查更新并退出
```

`--verbose` 是判断「到底有没有在工作」最快的手段：`smoothed` 是被吞掉的滚轮格数，`synthesized` 是合成出去的事件数，后者显著大于前者说明插值在跑。`frameSource=timer` 表示没锁上 vsync。

诊断日志走 `Trace`（`os.Logger`，subsystem `com.openmouse.OpenMouse`，category `tap` / `gesture`）：

```bash
/usr/bin/log show --last 2m --predicate 'subsystem == "com.openmouse.OpenMouse"' --info
```

**用 `/usr/bin/log` 的全路径**——`log` 在这台机器上被 shell 函数遮蔽了。

### 没有的东西

没有 lint 配置、没有 CI、没有测试 target（原因见下）、没有 `.cursor/rules` 之类的其他规则文件。改完代码**必须**跑 `make test`——那些断言就是为了防止下面每一条被重新弄坏。

## 硬性约束

违反任何一条都会造成**静默失效**——事件成功发出、系统不理、功能看起来就是「没反应」。全都是实际踩过的坑，不是理论风险。

1. **tap 必须挂在 `.cgAnnotatedSessionEventTap`**，不能用 `.cghidEventTap`。`postToPid` 依赖 `kCGEventTargetUnixProcessID`，只有 annotated session 层会填这个字段；HID 层给的是「最前面的窗口」，不是实际路由目标。挂错层的后果是滚轮**整个失效**（悬停在后台窗口滚动时，合成帧全投给了前台窗口）。
2. **投不出去就不要吞。** 取不到有效 pid 时直接放行原事件。宁可少一次平滑，不能把一格滚轮变成什么都没发生。
3. **窗口管理快捷键必须带 `maskSecondaryFn`（`0x800000`）。** 少这一位不报错，WindowServer 直接忽略。
4. **不要硬编码系统快捷键，读 `com.apple.symbolichotkeys`**（`SystemHotkeys`）。用户能改也能关；键码 `65535` 是「未绑定」占位值。
5. **不要硬编码字符的虚拟键码。** 键码是物理位置不是字符：键码 8 在 AZERTY 上打 `Z`、Dvorak 上打 `J`。硬编码不是「失效」而是**发出另一个快捷键**（「关闭标签页」在 AZERTY 上变成撤销）。字符一律过 `KeyboardLayout.keyCode(for:)`；返回 `nil` 时放弃动作并写明原因，绝不能拿某个真键当失败哨兵。
6. **合成事件必须通过 `SyntheticEventTag.mark(_:)` 打魔数**（`kCGEventSourceUserData`），回调第一件事就是用同一抽象检查并放行自己发的事件，否则无限重新插值。
7. **合成滚动事件必须设 `IsContinuous = 1`**，否则应用把它量化回整行，插值白做。
8. **反转方向要翻三个字段**：`DeltaAxis` / `PointDelta` / `FixedPtDelta`。漏一个，读那个字段的应用就朝反方向滚。Apple 定义前两个为整数、`FixedPtDelta` 为 16.16 定点值；字段和存取器统一由 `ScrollEventFields` 定义，不要在调用点重写。
9. **帧源不能用 `NSScreen.main`** —— 对无窗口的菜单栏 App 返回 nil，会静默降级到定时器。要取指针所在的那块屏幕。
10. **必须同时处理 `tapDisabledByTimeout` 和 `tapDisabledByUserInput`**：收到就 `CGEvent.tapEnable` 重开、写诊断，并经过同一个恢复钩子清掉可能丢失抬起的按键/手势会话。只处理其中一条会留下永久开启的 motion tap 或下一次移动误触发。
11. **`Preferences` 及其子结构必须手写 `init(from:)` 逐字段降级。** Swift 合成的 `Decodable` 不使用属性默认值，少一个键就抛错——加一个字段会重置老用户的配置。目前 `ScrollSettings` / `KeyCombo` / `MouseAction` / `ButtonBinding` / `AppRule` / `UpdateSettings` / `Preferences` 都已覆盖；`buttons` 还必须逐元素容错，未知动作只降为 `.passthrough` 并在 `normalize()` 时移除自身，损坏的一行不能拖掉其余映射。见 `docs/code-review-2026-08-31.md` F3。
12. **动作不能在 tap 回调里同步执行**，一律 `DispatchQueue.main.async`。回调超时会被系统停用 tap。
13. **不要在 tap 回调里查应用身份**（IPC 往返）。按键/UI 使用缓存的 `frontmostBundleID`；滚动规则必须按事件的 `eventTargetUnixProcessID` 经 `ScrollRuleResolver` 的 pid→bundleID 快照解析。快照只由 `didLaunch` / `didTerminate` 通知维护，回调里不得调用 `NSRunningApplication(processIdentifier:)`。
14. **不要用全局键盘 tap 去探测键码**——那会捕获用户的真实输入。要验证按键是否有效，用「注入 + 读系统日志」（比如 `/usr/bin/log show --predicate 'subsystem == "com.apple.dock"'`）。注意**注入进程必须存活 ~400ms**，否则 WindowServer 不会处理队列——这会造成假阴性，我因此一次性误判了三个本来有效的按键。

## 代码分布

- `Core/` —— 事件管线与所有系统交互。改行为基本只动这里。
- `Model/` —— `Settings.swift`（`Preferences` / `MouseAction` / `KeyCombo` 等全部持久化类型，手写 `init(from:)` 的覆盖范围见约束 11）、`ActionKind.swift`（选择器用的扁平枚举 + 分组 + 双向转换）、`SettingsStore.swift`（JSON 持久化 + `ResolvedConfig` 快照）。
- `UI/` —— SwiftUI 设置页，一个 pane 一个文件。
- `App/` —— AppKit 生命周期、菜单栏、设置窗口。
- `Support/` —— `SelfCheck.swift`（断言）、`Trace.swift`（os.Logger）、`Strings.swift`（全部文案）、`Locked.swift`。

**新增一个动作要同时改三处**：`MouseAction`（`Model/Settings.swift`）、`ActionKind`（标题 + 分组 + `init(_:)` + `makeAction(preserving:)`）、`ActionRunner.stroke(for:)`。漏掉最后一处编译不过（见下），漏掉分组会被自检抓住。自定义快捷键的空状态只能用 `KeyCombo.unset`（`UInt16.max`），键码 0 是真实按键；投递边界必须检查 `isSet`。

## 结构

```
main.swift ──▶ AppDelegate ──▶ StatusItemController（菜单栏）
                    │
                    ├─▶ MouseEngine        事件掩码决策、tap 生命周期、权限轮询
                    │      ├─▶ EventTapController   主 tap（+ 超时自动重启）
                    │      │      └─▶ EventRouter   放行 / 改写 / 吞掉的判定
                    │      │             ├─▶ ScrollAnimator
                    │      │             │     ├─▶ ScrollAxis              一级：指数缓动
                    │      │             │     ├─▶ ScrollSmoothingFilter   二级：一阶低通
                    │      │             │     ├─▶ DisplayLinkTicker       vsync 帧源
                    │      │             │     └─▶ ScrollEventPoster       postToPid 投递
                    │      │             ├─▶ MouseGestureRecognizer（首次方向锁轴）
                    │      │             └─▶ ActionRunner（按键动作 / Logi 风格即时手势）
                    │      │                    ├─▶ SystemHotkeys      读系统快捷键配置
                    │      │                    ├─▶ KeyboardLayout     字符 → 当前布局键码
                    │      │                    └─▶ SpaceSwitchPacer   仅普通桌面动作节流
                    │      └─▶ EventTapController   motion tap（仅手势期间开启）
                    │
                    ├─▶ SettingsStore      JSON 持久化 + ResolvedConfig 快照
                    ├─▶ ConflictMonitor    同类软件检测（事件驱动，不轮询）
                    ├─▶ UpdateCoordinator ──▶ UpdateChecker（GitHub Releases）
                    └─▶ SettingsWindowController ──▶ SwiftUI 设置界面
```

事件掩码是**按当前配置动态算的**（`MouseEngine.eventMask(for:capturingButtons:)`）：没有生效的按键映射就不订阅按键事件，没有滚动时帧源会被销毁。所以「空闲时零开销」不是说法而是实现约束——加新功能时不要无条件扩大掩码。

配置存 `~/Library/Application Support/OpenMouse/preferences.json`。

## 滚动：为什么平滑要分两级

只做插值不够顺。一级的指数缓动每帧发剩余距离的固定比例，问题是**第一帧就是最大的一帧**：默认参数下一格滚轮第一帧直接发 `105 × 0.13 = 13.65px`，这个凭空出现的突起就是起手那下「踢脚」。Mos 用 `ScrollFilter` 解决——它的 `polish` 生成 5 元数组但只有下标 0 和 1 会被读，等效递推是 **α = 0.23 的一阶低通，输出滞后一帧**。

顺序是：**指数缓动产生惯性 → 一阶低通削掉起手突起 → vsync 帧源发送**。滤波器有滞后，所以缓动收敛后动画不能立刻停，必须等滤波器排空，否则每次滚动的尾巴被切掉。

**原始增量取值顺序 `PointDelta` → `FixedPtDelta` → `DeltaAxis`**（与 Mos 的 `usableValue` 一致）。`PointDelta` 含 macOS 自己的滚动加速，滚得快就大；取行数几乎恒为 ±1，快速滚动完全不加速。这也是为什么参数是「最短步长 × 速度增益」而不是一个「单格距离」。

**区分鼠标和触控板看 `kCGScrollWheelEventIsContinuous`**：触控板 / Magic Mouse 为 1（本身就是像素级连续），滚轮鼠标为 0。默认只平滑后者——触控板已经平滑，吞它的事件会破坏手势与惯性。

帧源用 `NSScreen.displayLink`（macOS 14+）而不是已废弃的 `CVDisplayLink`（后者在显示器唤醒 / 重连时会先报过渡刷新率，绑上去就只按低帧率绘制，见 Mos issue #958）。帧源跑在独立线程的 run loop：事件 tap 和 SwiftUI 都在主 run loop，设置窗口重排版时不能拖慢滚动帧。

## 按键动作

整张映射表是 `ActionRunner.stroke(for:)` 里一个对 `MouseAction` **穷尽的 `switch`**。这是刻意的：新增动作忘了实现会**直接编译不过**。「选得到但没反应」在这个项目里出现过两次，所以这一类 bug 交给编译器兜。不要退回成两张表（`run()` 一张、自检钉另一张）——那样自检钉住的和实际跑的不是同一份。

几个特殊路径：

- **⌘⇥ 需要真的按下 ⌘ 键。** App switcher 读的是系统的修饰键状态而不是事件 flags，只设 `maskCommand` 完全没反应（保留 / 释放修饰键两种都试过）。必须先发 ⌘ 键自己的 `flagsChanged`，见 `keyStrokeWithRealModifiers`。
- **单独绑定的“左右切换桌面”动作保留节流。** `SpaceSwitchPacer`：0.12s 间隔（Mos 同值），最多积压 2 步，反向时丢弃积压。**手势导航必须绕过 pacer**：2026-08-31 对 `logioptionsplus_agent` 的直接事件采样显示，它在每次物理按住的第一次方向锁定时立即发一次 `Control+Fn+Left/Right Arrow`，即使前一段桌面动画还在运行也不排队。
- **媒体键不是键码**，走 `NSEvent.otherEvent(with: .systemDefined, subtype: 8)` + `NX_KEYTYPE_*` 装在 `data1`。
- **功能行键码要一个个实测**：`160` = 调度中心、`131` = 启动台、`178` = 控制中心，在 macOS 26.6 上验证有效。`177`（聚焦）与 `176`（听写）实测**已失效**，故意没收入——宁可没有这一项，不要一个选得到但不动的选项。注意 Mos 的标识符 `appExpose` 看名字像「应用程序窗口」，但它界面上写的是「启动台」；名字不是证据，日志才是。

## 手势导航

**按下被吞掉之后，位移事件换了类型。** 绑定了动作的侧键，其 `otherMouseDown` 被吞掉后系统认为它从未按下，后续移动不再是 `otherMouseDragged` 而是普通的 **`mouseMoved`**。所以有第二个 motion tap，订阅四种位移事件，**只在手势进行中开启**（`mouseMoved` 是系统里最密集的事件流，没手势时没理由让每次移动都过一遍回调）。

**不能只读增量字段。** 某些鼠标发的 `otherMouseDragged` 三个增量字段全是 0，只读它们的话累积位移永远是 0，每次按住都被判成「原地单击」。识别器用事件坐标做差分，增量字段非零时才优先采信（屏幕边缘会夹住坐标，那时差分为 0 而增量字段仍然对）。

阈值：7px 后锁轴，某轴要比另一轴多 1.2 倍（避免斜划乱猜）。锁轴的第一个带符号增量立即映射为一个动作：上 = 调度中心、下 = 应用程序窗口、左 = 右桌面、右 = 左桌面。**一次按住只触发一次**；同一按住中的继续移动和反向都忽略。松开重按才开始下一次识别，且桌面动作直接走 `ActionRunner.runGestureNavigation`，不能进入 `SpaceSwitchPacer`。

采样到的 Logi 左右桌面序列是：`keyDown(Control+Fn+Arrow)` → `keyUp(Fn+Arrow)` → `flagsChanged(0)`，来源状态为 `.hidSystemState`。`ActionRunner.gestureSpaceEvents` 保持这个形状。没有发现 Logi 发 `type 29/30` Dock-swipe 或滚轮动量来完成桌面切换。`DockSwipeSynthesizer` 仅保留为私有协议诊断与编码实验（来源和许可证见 `THIRD_PARTY_NOTICES.md`），**不得接回生产手势路径**；实测强行补 progress 会造成跳跃且仍无法复现 Logi 的提交行为。

**被吞掉的按下拥有它的抬起。** `EventRouter` 在 mouse-down 时记录 claim；mouse-up 只按这份会话状态收尾，不能重新解析当时的修饰键、绑定或前台应用。任何 tap 重建、权限丢失、引擎关闭与自动恢复都必须经统一 teardown 清掉 claim、gesture session、motion tap 和权限轮询。

## 约定

- `.swiftLanguageMode(.v5)`。事件 tap 天生是 C 函数指针回调 + `Unmanaged`，Swift 6 的严格隔离会让这层充满仪式性样板。不要为了「现代化」把它切到 v6。
- 跨线程共享状态统一走 `Locked`（`OSAllocatedUnfairLock`）：配置快照、动画状态、滤波器、计数器。
- 界面文案全部集中在 `Strings.swift`，目前只有中文。
- 设置界面遵循 `macos-settings-ui` skill 的写法（`NSWindowController` + `.fullSizeContentView` + 透明 `Form`）。
- 本地 UI / 硬件测试只能启动 `Open Mouse Debug.app`（`com.openmouse.OpenMouse.debug`），其配置目录为 `OpenMouse Debug`；不要再用 `open -n` 启动多个正式名称实例。
- 应用级 `.custom` 规则必须能编辑 `ScrollSettings` 的全部存储字段；`AppRuleScrollField` 与编码键的自检负责在模型扩字段时阻止 UI 静默漏项。
- 状态栏图标同时由总开关和 `MouseEngine.status` 决定，必须通过 Observation 持续订阅两者；只在菜单动作里手动刷新会漏掉启动、权限变化和 tap 失败/恢复。
- 权限授予没有系统通知，只能在被阻塞时轮询（1 秒一次），拿到就启动并停止轮询；任何离开运行态的分支都通过同一个 teardown 同时停止主 tap、motion tap、会话与轮询。
- 偏好变化只有在主 tap 的事件掩码发生变化时才允许重建监听；滚动参数、应用规则等快照更新不能中断正在进行的手势。主 tap 创建失败不是终态，必须安排有限间隔的重试并在离开失败态时取消定时器。
- 偏好 JSON 的 400ms 去抖编码/写盘必须由 `PreferencesSaveWorker` 在 detached utility task 完成，不能占用主线程上的事件 tap run loop；`saveNow()` 只用于窗口关闭/进程退出的显式同步落盘。
- 注释写「为什么」，尤其是那些看起来可以简化但不能简化的地方——这个项目里大部分坑都长得像多余的代码。

## 测试为什么是 `--self-check`

XCTest 和 swift-testing 都随 Xcode 提供，Command Line Tools 里没有——只装 CLT 的机器连测试 target 都编译不出来。所以断言放在 app target 内，任何能构建的机器都能跑，对已发布的构建也是可用的诊断。装了完整 Xcode 之后搬进 `@Test` 是机械改写。

自检里「Mos 风格滚动」那组把调优后的默认值 `35`、`3.00`、`0.87` 以及 Mos 风格滤波系数 `0.23` 钉住了，参数被误改立刻失败。「动作实现完整性」那组保证 65 个动作都有实现，并在 `.character` 经过当前布局解析成真实键码之后检查重复，能抓到多个动作塌到同一个键上的问题。

**修 bug 之后要补一条断言，别让同一个 bug 回来第二次。** 但**不要以为约束已经都被钉住了**：约束 1 / 2 / 3 / 4 / 5 / 6 / 8 / 11 / 13 有断言，约束 **7 / 9 / 12 零覆盖**；约束 10 已覆盖两种系统禁用原因及统一会话拆除，约束 14 是流程约束、本质上无法断言。「滚动帧源生命周期」那组会驱动真实的 `DisplayLinkTicker`，但只钉生命周期一致性——**选哪块屏幕**（约束 9 本身）仍然没有断言，也刻意不断言「帧真的会来」，那要依赖有显示器，红在 SSH 上比没有这条更糟。

约束 5 原来的同义反复断言曾漏掉 15 个动作字符；第 3 批已改为从生产动作表反向枚举。审查报告 F4 把 `PointDelta` 误判成浮点字段，复核时依据 Apple 文档和真实 `CGEvent` 行为驳回了该结论，但仍把三个字段及其存取器收口并补了翻转断言。第 4 批把按键 claim、两条 tap 禁用路径、权限状态收敛和连续设备反向统一为可测试的必经路径。详见 `docs/code-review-2026-08-31.md` §4。

## 参考实现

`~/workspace/Mos` 有 Mos 源码（fork 的分支 `codex/mouse-gesture-navigation`，PR Caldis/Mos#1023 是加的手势识别）。**鼠标行为的事实来源是那份源码，不要凭记忆。** 手感参数与交互模式照抄成熟工具，不要自己发明数值。

## 签名与权限

TCC 记录辅助功能授权时同时看 bundle id、签名身份和 cdhash。只有 Developer ID Application 身份既能跨版本稳定，又能在没有开发描述文件时分发运行。日常 `make app` 在没有 Developer ID 时使用 ad-hoc 签名；`make dist-community` 也明确产出 ad-hoc 社区包，所以重建或升级可能需要重新授权。彻底重来用 `make tcc-reset`。

`make dist` 与社区发布的签名策略不同：正式发布必须显式传 `CODESIGN_IDENTITY`，使用 Developer ID Application + hardened runtime + Apple 安全时间戳；`bundle.sh` 会读回 Authority / Timestamp / runtime flags，任一不符直接失败。`make dist-community` 使用 ad-hoc + hardened runtime，并实际启动主程序和更新助手做冒烟检查，防止再把只能开发机运行的 Apple Development 构建发出去。不要为了“先出包”绕过任一签名校验。

## git

这台机器上 `git push` 到 GitHub 会挂两分钟然后报 `RPC failed; HTTP 408`（HTTP/2 的大 POST 被中断，**不是**在等密码）。仓库的 `.git/config` 已经写了 `http.version=HTTP/1.1` 和 `http.postBuffer=524288000`。调试推送问题时带 `GIT_TERMINAL_PROMPT=0`，让它快速失败而不是挂住。`gh` 也会偶发 `unexpected EOF`，重试前先检查有没有留下未完成的草稿 release。
