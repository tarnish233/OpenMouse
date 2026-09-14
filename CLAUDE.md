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
make test     # 应用自检 416 项 + 更新助手自检 + 正式/社区发布签名检查，必须全过
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

**没有办法从命令行只跑一个检查。** `SelfCheck.run()` 里是 21 个 `group("名字") { ... }` 顺序执行，没有过滤参数。要单独跑一组，临时注释掉 `run()` 里其他的 `group(...)` 调用——不要为了图快改断言本身。

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
- `Model/` —— `Settings.swift`（`Preferences` / `MouseAction` / `KeyCombo` / `DraftSections` 等全部持久化类型，手写 `init(from:)` 的覆盖范围见约束 11）、`ActionKind.swift`（选择器用的扁平枚举 + 分组 + 双向转换）、`PointerSpeedSettings.swift`（指针速度的持久化类型与实测常量）、`SettingsStore.swift`（JSON 持久化 + 草稿会话 + `ResolvedConfig` 快照）。
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
                    ├─▶ SettingsStore      JSON 持久化 + 草稿会话 + ResolvedConfig 快照
                    ├─▶ ConflictMonitor    同类软件检测（事件驱动，不轮询）
                    ├─▶ UpdateCoordinator ──▶ UpdateChecker（GitHub Releases）
                    └─▶ SettingsWindowController ──▶ SwiftUI 设置界面

AppDelegate ──▶ PointerSpeedController   逐设备写 HID 加速属性（不碰事件 tap）
                    ├─▶ IOHIDEventSystemClient      设备增删/唤醒时作废重建（见约束 1）
                    └─▶ IOServiceAddMatchingNotification  设备增删触发重新施加
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

## 指针速度

给任意品牌鼠标改指针速度的路子是 **per-device 写 HID 加速属性**，和 Logitech HID++ 那条 DPI 路径没有任何关系。`PointerSpeedController` 挂在 `AppDelegate` 上而不是 `MouseEngine` 里——它不碰事件 tap，tap 因权限被挡住时它照样要工作。

**不能叫 DPI。** `HIDPointerResolution` 才是线性速度（真正等价于 DPI），2026-09-02 在 macOS 26.6.2 实测**写入返回 false 且毫无效果**，补 acceleration latch 也没用。能用的是 `HIDMouseAcceleration`，那是加速**曲线**：同一档下快速甩动被放大的比例高于慢速微调。所以硬件档继续叫「切换 DPI」，这个功能叫「指针速度」，MCHOSE 在 DPI 项下永远不亮。

实测数据（三方吻合的默认值 `0.6875` = 16.16 的 `45056`：设备 service、`IOHIDSystem` 全局属性、LinearMouse 的 `fallbackPointerAcceleration`）：

| 键 | 读 | 写 | 效果 |
|---|---|---|---|
| `HIDMouseAcceleration` / `HIDPointerAcceleration` | 45056 | **true** | **可感知**（0.25 慢 / 2.0 快） |
| `HIDPointerResolution` | nil | **false** | 无效 |
| `HIDUseLinearScalingMouseAcceleration` | nil | false | LinearMouse 的「关闭加速」开关在本机是死的 |

规律：**读得到的键才写得进去。** 所以「加速键读不到」= `.unsupported`，在尝试之前就能判定。

五条硬性约束，全都踩过：

1. **client 不能长期持有，service 句柄不能跨调用缓存。** 这是两条互相约束的事实，都实测过：
   - `IOHIDServiceClient` 是父 `IOHIDEventSystemClient` 会话里的句柄，父 client 一释放，用它就 **SIGSEGV**。所以每次 pass 重新枚举、用完即弃，绝不存下来。
   - 反过来，client 的 service 列表跨一次拔插会**永久过期**：2026-09-02 实测，一个跨过拔出的 client，`CopyServices` 仍然返回那只设备**已经死掉的 service**（`found=yes` 而每个属性都读 nil），并且**再也不会**出现插回来后的新 service；同一时刻新建的 client 读得毫无问题。**拿同一个 client 重试多少次都不可能恢复。**

   所以做法是：缓存 client（新建一次 1.6 ms vs 复用 0.006 ms，拖滑块是逐格 reconcile，逐格做 IPC 握手会压到和事件 tap 同一条主 run loop 上），但在**设备增删和系统唤醒时作废重建**。另有一条自愈兜底：只要出现「曾经 `.applied` 的设备现在读不到属性」这个签名（`looksStale`），就重建 client 重跑一遍 pass——它是从 v0.7.0 的现场故障里得出来的，有断言钉住。「全部恢复系统默认」按钮强制用新 client：那是人觉得不对劲时才点的按钮，恰是缓存最可能已经不对的时刻。
2. **必须检查 `IOHIDServiceClientSetProperty` 的 Bool 返回值，还要读回校验。** 返回 true 只说明事件系统收下了消息。LinearMouse 丢掉了这个返回值（`fc305e9` 加过、`2d01c2e` 撤回），它的 Pointer Speed 滑块在这台机器上写了也白写而毫无提示；它 PR #1052 断言 Tahoe 上 "writing still succeeds"，**实测为 false，不要采信**。Apple 正在逐步拆这套属性，所以「写失败」是常规路径。
3. **`ApplyState` 五种状态不能折叠。** `disabled` / `applied` / `offline` / `unsupported` / `rejected` 各有独立文案，自检钉住这一点。这条是对 HID++ 那个「四种失败在界面上长得一模一样」问题的不重犯。`unsupported` 必须在**未勾选时也上报**——否则复选框是灰的却不说为什么。
4. **不能启动时设一次。** 鼠标休眠/断开后 service 直接从事件系统消失（实测 service 数 134 → 133），而且**拔插会把设备的加速值重置回系统默认**，所以重新施加是必要的而不是锦上添花。重新施加的触发是设备增删（`IOServiceAddMatchingNotification` on `IOHIDDevice`）、系统唤醒、偏好变化；前两者都先作废 client（见约束 1）。设备增删后跑一小串 pass（约 0.4 / 1.2 / 3 / 6 秒），所有已勾选设备都 `.applied` 就提前收工——service 不一定在注册表项出现的同一刻就发布。**用注册表通知而不是 `IOHIDManager`**：后者要 `IOHIDManagerOpen` 打开设备，会把「输入监控」权限拖进一个本来不需要任何权限的功能。这条通知链路在 v0.7.1 发布时还是「各环节分别验过、组合未验」，2026-09-02 已在真实应用里确认——设备变化时日志确实打出 `device change, rescanning`。那行日志刻意保留：第一次排查这个功能时，最先问不出答案的就是「通知到底有没有触发」。
5. **恢复默认值要去读 `IOHIDSystem` 的系统全局值，不能存「启动时抓下来的原值」**（照 LinearMouse `Device.restorePointerAcceleration()`）。存下来的原值在用户改过系统跟踪速度后就是错的。只恢复**我们真正改过**的设备——别的工具可能拥有其他设备的值，「未启用」不等于「可以覆盖」。

**权限：不需要辅助功能。** 2026-09-02 用从未授权过的 debug 包实测，日志 `started trusted=false` 的同时 `applied ... value=0.750000` 成功、读回确认。所以 `PointerSettingsPane` **不放 `PermissionBanner()`**——贴一个与本页无关的权限横幅是误导。`start()` 里那行 `trusted=` 日志刻意保留，用来回答故障报告里「是不是权限问题」。

`ConformsTo(GenericDesktop=1, Mouse=2)` **远不是充分过滤**：本机 135 个 service 里 4 个命中，其中一个是 Kzzi-K75 **键盘**、一个是 Karabiner 的**虚拟指针设备**，`kIOHIDBuiltInKey` 在它们身上全是 nil 所以也没法拿来区分。没有可靠的自动过滤，**所以是用户勾选而不是自动接管**——这不是偷懒，是把无解的分类问题换成一个复选框。

设备身份用 **VID/PID**，不用名字或序列号（重新配对后会变，LinearMouse #764 / #1102）。代价是两只同型号鼠标共用一行，且杂牌占位 ID 可能撞——接受，因为每次重连都丢设置是更糟的失败。

**但更尖锐的代价是三模鼠标：同一只鼠标每种连接方式是一套完全不同的身份。** 2026-09-02 实测 MCHOSE A5：

| 连接 | 名称 | VID/PID |
|---|---|---|
| 有线 | `MCHOSE A5` | `0x2023`/`0xF019` |
| 蓝牙 | `MCHOSE A5 5.0` | `0x1234`/`0xFFFF` |

**拔掉线它不会消失，而是 0.5 秒内切到蓝牙回来**（插回时两个身份会短暂同时存在）。蓝牙那个身份的加速属性同样可读可写，所以这不是「无线下没法用」，纯粹是键值对不上。

**刻意没有按名字前缀把两者认成同一台。** 那正是「名字不是证据」，而且会把用户没勾选的设备的指针速度也改掉。做法是把连接方式（`kIOHIDTransportKey`）作为一等信息显示出来，让两行读起来是「两种连接方式」而不是「一个 bug」，用户把两行都勾上——勾一次就永久记住。`PointerTransport` 只用于显示，永远不能进入身份。

诊断：

```bash
/usr/bin/log stream --predicate 'subsystem == "com.openmouse.OpenMouse" && category == "pointer"'
```

自检那组**只覆盖纯逻辑，IOKit 侧零覆盖**——和 HID++ 一样，全绿完全不能说明某只鼠标能用。

## 草稿与保存

设置窗口里「能用身体感觉到」的那几段是**草稿**：改了立刻生效（所以能体验），但只有点右上角「保存」才写盘，切换设置页、关闭窗口或退出应用前会提示**保存 / 不保存 / 取消**；只有明确选择不保存才放弃并恢复。

分界写在 `DraftSections`（`Model/Settings.swift`）：

- **草稿区** `scroll` / `buttons` / `rules` / `pointer`
- **即时生效** `enabled`（菜单栏总开关）/ `update`（后台行为）——这两个不是「试用」型设置，藏在一个用户可能从不打开的窗口的保存按钮后面会把它们困死
- 「登录时启动」「菜单栏图标」压根不进 `Preferences`（直接走 `LoginItem`），天然在体系外，不是特例

机制：`preferences` **始终是实时状态**（这才是改动能被感觉到的原因），草稿靠记住「磁盘现在应该是什么」来跟踪——`SettingsStore.savedDraft` 只在窗口开着时非 nil，`persistedPreferences` 把即时段取实时值、草稿段取上次保存值。**400ms 自动落盘走的也是这个**，否则「只有保存才算数」在重启后就是假话。

`beginEditing()` 在 `SettingsWindowController.show()` 里、窗口创建**之前**调用，保证任何 pane 绑定时已经在会话内。`endEditing()` 在 `windowWillClose` 里放弃未保存改动——这也是未保存的指针速度会弹回去的原因。

**窗口外的改动必须立刻提交**：`resetAll()`（显式的破坏性操作，一半挂在保存按钮后面会让按钮的含义取决于你看哪一段）和状态菜单的 `toggleBypassRule`（菜单动作，不是编辑手势）都走 `commitImmediately()`。所以 `StatusItemController` 调 `store.toggleBypassRule(...)` 而不是直接改 `store.preferences`。

**给 `Preferences` 加字段时必须显式归类。** 自检 `draftSectionsPartitionEveryPreferenceField()` 比对编码出来的顶层键集合与两个显式集合，漏了会直接红——不归类的默认行为是「即时生效」，对一个能被感觉到的设置来说那会悄悄违背保存按钮的承诺。

## 手势导航

**按下被吞掉之后，位移事件换了类型。** 绑定了动作的侧键，其 `otherMouseDown` 被吞掉后系统认为它从未按下，后续移动不再是 `otherMouseDragged` 而是普通的 **`mouseMoved`**。所以有第二个 motion tap，订阅四种位移事件，**只在手势进行中开启**（`mouseMoved` 是系统里最密集的事件流，没手势时没理由让每次移动都过一遍回调）。

**不能只读增量字段。** 某些鼠标发的 `otherMouseDragged` 三个增量字段全是 0，只读它们的话累积位移永远是 0，每次按住都被判成「原地单击」。识别器用事件坐标做差分，增量字段非零时才优先采信（屏幕边缘会夹住坐标，那时差分为 0 而增量字段仍然对）。

阈值：7px 后锁轴，某轴要比另一轴多 1.2 倍（避免斜划乱猜）。锁轴的第一个带符号增量立即映射为一个动作：上 = 调度中心、下 = 应用程序窗口、左 = 右桌面、右 = 左桌面。**一次按住只触发一次**；同一按住中的继续移动和反向都忽略。松开重按才开始下一次识别，且桌面动作直接走 `ActionRunner.runGestureNavigation`，不能进入 `SpaceSwitchPacer`。

采样到的 Logi 左右桌面序列是：`keyDown(Control+Fn+Arrow)` → `keyUp(Fn+Arrow)` → `flagsChanged(0)`，来源状态为 `.hidSystemState`。`ActionRunner.gestureSpaceEvents` 保持这个形状。没有发现 Logi 发 `type 29/30` Dock-swipe 或滚轮动量来完成桌面切换。`DockSwipeSynthesizer` 仅保留为私有协议诊断与编码实验（来源和许可证见 `THIRD_PARTY_NOTICES.md`），**不得接回生产手势路径**；实测强行补 progress 会造成跳跃且仍无法复现 Logi 的提交行为。

**被吞掉的按下拥有它的抬起。** `EventRouter` 在 mouse-down 时记录 claim；mouse-up 只按这份会话状态收尾，不能重新解析当时的修饰键、绑定或前台应用。任何 tap 重建、权限丢失、引擎关闭与自动恢复都必须经统一 teardown 清掉 claim、gesture session、motion tap 和权限轮询。

## Logitech HID++

**厂商 ID `0x046D` 是第一道过滤，非 Logitech 鼠标完全不适用。** HID++ 是 Logitech 私有协议，DPI 走 feature `0x2201 ADJUSTABLE_DPI`；别的品牌没有这套东西，这不是没做而是做不到。

三条实现范围限制，写清楚是因为它们在界面上**完全看不出来**：

1. **只支持蓝牙直连。** `LogitechHIDPPManager.attach()` 要求 transport 含 `bluetooth` 且 primary usage 为 `0x0001`/`0x0002`。Bolt / Unifying 接收器在 IOKit 里 transport 是 `USB`，直接被挡；就算放行，device index 也写死了 `0xFF`（直连寻址），接收器需要 1–6。USB 有线的 HID++ 端点 usage 是 `0xFF43`/`0x0202`，同样过不了。**这个 `return` 之前没有任何日志**，所以「插了 Bolt 接收器」和「压根没接鼠标」在日志里长得一模一样。
2. **DPI 档位按 M750 硬编码** 400–4000 / 100 步进（`LogitechDPILevels.swift`），从不调 `getSensorDPIList`。MX Master 3S 的 4000–8000 段和 50 步进拿不到。
3. **`0x1B04 REPROG_CONTROLS_V4` 是 DPI 的硬前置。** 不支持它的鼠标 `stage = .failed`，DPI 一并失效——这是实现耦合，不是设备的锅。

**`.failed` 是终态，除了蓝牙重连或重启 App 没有任何重试。** 蓝牙鼠标在 App 启动那一刻恰好省电休眠，discovery 1.5s 超时后 DPI 键就永久失效。

链路挂掉时 **UI 零反馈**：「没找到设备」「不支持」「没给输入监控权限」「超时」四种情况在界面上完全一样——两个档位照常可点，只是不高亮、不显示「当前 XXXX DPI」。诊断只能看日志，category 是 `hidpp`：

```bash
/usr/bin/log stream --predicate 'subsystem == "com.openmouse.OpenMouse" && category == "hidpp"'
```

只有 `manager started` 而没有 `device connected` 就是第 1 条的过滤没过。自检那组**只覆盖纯编解码，IOKit 侧零覆盖**——全绿完全不能说明某只鼠标能用。

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

TCC 通过 bundle id 与 Designated Requirement 识别同一应用。`v0.4.0` 至 `v0.6.0` 的 ad-hoc Requirement 只含 CDHash，每次编译都会变化。自 `v0.6.1` 起，社区包使用固定自签名身份 `Open Mouse Community Signing`，Requirement 明确锁定 Bundle ID 与公开证书 SHA-1 `0DD76541008E2DD109E45A07942A0A2EBAC48D42`。公开证书跟踪在 `Resources/OpenMouseCommunitySigning.cer`；私钥和 `.p12` 永远不能进入 Git。彻底重置权限用 `make tcc-reset`。

维护者登录钥匙串中有该证书时，日常 `make app` / `make debug` 也使用固定身份，避免每次重建测试包都重置 TCC；没有私钥的贡献者仍回落 ad-hoc。第二台发布 Mac 只能导入同一个加密 `.p12`，运行 `Scripts/import-community-signing-identity.sh /path/to/OpenMouseCommunitySigning.p12`，绝不能创建同名新证书。当前 Mac 的加密备份在 `~/Library/Application Support/OpenMouse Signing/OpenMouseCommunitySigning.p12`，密码保存在登录钥匙串服务 `Open Mouse Community Signing Backup Password`；仍需把 `.p12` 另存到安全的离线位置。

`make dist` 与社区发布的签名策略不同：正式发布必须显式传 `CODESIGN_IDENTITY`，使用 Developer ID Application + hardened runtime + Apple 安全时间戳；`make dist-community` 必须找到仓库公开证书对应的固定私钥，使用 self-signed certificate + hardened runtime + 无时间戳，并同时验证 Authority、runtime flags、TeamIdentifier 和精确 Requirement。两个发布路径都实际启动主程序与更新助手做冒烟检查。不要为了“先出包”绕过任一签名校验。

## 应用内更新

两道门，别把它们搞混：

1. **`supportsAutomaticInstallation`（`UpdateCodeSignature.swift`）只决定 UI 提不提供「下载并安装」。** 认两种身份：`Developer ID Application:` 前缀，或 leaf 证书 SHA-1 等于 `communitySigningCertificateSHA1`。**必须按指纹判，不能按证书名称**——自签名证书的 CN 谁都能伪造，按名字匹配等于没设防。这个常量在 Swift 和 `Scripts/community-signing.sh` 里各存一份，证书没进 bundle 所以运行时无法比对，由 `Scripts/test-community-signature.sh` 钉住两份一致。
2. **`validate(candidateURL:matchesCurrentAppAt:)` 才是真正的安全边界**：要求下载包满足**当前运行包自己的** Designated Requirement。社区包的 DR 已经锁定证书指纹，所以放开第 1 道门不会放宽实际装进去的东西。更新助手在宿主退出后**再校验一次**，闭合校验与换盘之间的窗口。

ad-hoc 包永远不可能自动更新——它的 DR 是每次构建都变的 CDHash，下一个版本不可能满足。`v0.6.1` 及更早的用户必须手动装一次。

`UpdateHandoff`（`OpenMouseUpdateSupport`）里两个超时的**顺序**是不变量：宿主 12s 放弃等待自身退出，助手 30s 放弃等待宿主。宿主必须先认输，否则 `installationState` 卡在 `.installing`、`isBusy` 恒真，`reconcileAutomaticSchedule` / `launchAutomaticCheck` / `check` 三处 guard 全部短路——整个进程生命周期内更新检查彻底死掉，界面还留着转圈。`NSApp.terminate` 是请求不是保证，兜底定时器必须挂在 `.common` 模式，否则模态循环里不触发。

**`installationState` 不只会卡住检查，还会挡住检查结果。** `GeneralSettingsPane` 的 `outcomeRow` 先 switch `installationState`，只有 `.idle` 才落到 `checkOutcomeRow`。更新后重启时 `consumeUpdaterLaunchResult()` 把它设成 `.installed(version)`，而 v0.7.1 之前**没有任何地方复位它**——于是「已更新到 X」永久占住那一行，后续检查发现的新版本连带安装按钮一起看不见，**应用内更新在第一次成功使用后自我禁用**（0.7.0 → 0.7.1 现场复现：检查跑了、发现了 0.7.1、「上次检查」时间也更新了，界面仍写着已更新到 0.7.0）。规则收在 `UpdatePolicy.shouldRetireInstallationNotice`：发现新版本、或用户主动点检查 ⇒ 让位；**自动检查只确认「已是最新」时保留**，否则刚装完一秒后定时检查一跑，那句确认就凭空消失。断言两个方向都钉，只钉一边很容易过度修成把确认也弄没了。

这一类 bug 的教训：更新相关的断言原本 10 条全在测网络解析与调度，**没有一条测结果到不到得了用户眼前**。

安装位置在**下载之前**检查（`ApplicationReplacement.locationProblem`）：App Translocation 只读副本按路径含 `AppTranslocation` 识别（`SecTranslocateIsTranslocatedURL` 没有 Swift 绑定），容器不可写另算一种。没有任何更新包能让只读位置变可写，所以先花流量再失败是纯浪费。

诊断为什么没有安装按钮：`OpenMouseUpdater --describe-auto-install <app 路径>`，打印身份、指纹和判定原因。加它是因为 `supportsAutomaticInstallation` 把五种不同失败全折叠成 `false`，「没有按钮」原本无法回答。

## git

这台机器上 `git push` 到 GitHub 会挂两分钟然后报 `RPC failed; HTTP 408`（HTTP/2 的大 POST 被中断，**不是**在等密码）。仓库的 `.git/config` 已经写了 `http.version=HTTP/1.1` 和 `http.postBuffer=524288000`。调试推送问题时带 `GIT_TERMINAL_PROMPT=0`，让它快速失败而不是挂住。`gh` 也会偶发 `unexpected EOF`，重试前先检查有没有留下未完成的草稿 release。
