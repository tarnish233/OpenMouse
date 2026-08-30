# Open Mouse

macOS 上的鼠标滚动与按键增强工具。三件事：把滚轮的**一格一格跳动**变成逐帧的像素级平滑滚动、**独立反转**鼠标滚动方向（不影响触控板）、把鼠标的**额外按键**映射成系统动作、自定义快捷键或**手势导航**。

菜单栏常驻，纯 `CGEventTap` 实现，**没有内核扩展、没有驱动、不需要关闭 SIP**。

手感默认值与滚动管线逐项对齐 [Mos](https://github.com/Caldis/Mos)；按键采用录入式配置（参考 Mos 与 Karabiner）；手势导航参考 Logi Options+ 与 [logiops](https://github.com/PixlOne/logiops)。

> **同类软件只能开一个。** Mos / LinearMouse / Mac Mouse Fix / Scroll Reverser / BetterTouchTool / Logi Options+ 都会在 `.cghidEventTap` 上 head-insert 自己的事件监听。最后注册的排在链条最前面，它吞掉滚轮事件并发出自己的合成事件，另一个只能看到已经被处理过的连续事件。谁赢取决于启动顺序，表现出来像随机失灵。Open Mouse 检测到这种情况会在设置页顶部直接点名。

---

## 功能

### 滚动

| 能力 | 说明 |
|---|---|
| 平滑滚动 | 吞掉离散滚轮事件，两级处理后逐帧合成像素级滚动 |
| 反转方向 | 垂直 / 水平独立开关。**只作用于滚轮鼠标**，触控板不受影响 |
| 最短步长 | 单次滚动事件至少走多少像素，默认 **33.6**（Mos 同值） |
| 速度增益 | 在系统上报的像素增量上再乘的倍数，默认 **2.70**（Mos 同值） |
| 平滑度 | 0% 干脆跟手 → 98% 顺滑绵长，默认 **91.5%** |
| 加速度 | 连续快速滚动时额外放大距离，1.0× 关闭（Mos 无此项，默认关） |
| 预设 | 默认 / 顺滑 / 干脆，只改手感参数，不动方向与设备选择 |
| 实时试滚区 | 设置页内嵌可滚动区域，拖动滑块即刻感受效果 |

为什么是「最短步长 × 速度增益」两个参数而不是一个「单格距离」：因为**原始增量取的是系统上报的像素增量**，它本身会随滚动变快而变大。最短步长只负责给慢速的一格兜底，增益负责整体缩放，快速滚动因此会自然加速。用「行数 × 固定距离」的话每格永远走一样远，技术上也平滑，但手感是发木的。

### 按键

不预设按键列表——不同鼠标能报出的按键并不一样，为不存在的硬件留一行是噪音。**按下你想用的键，它就出现在列表里**，然后为它选择动作。录入时可以同时按住修饰键，为同一个物理键配出不同组合：侧键 4 = 后退，⌘ + 侧键 4 = 调度中心。录入期间会临时挂起所有按键改写，所以已经映射成「调度中心」的键也能被重新录入而不会一按就触发。

动作按类别收进二级菜单（窗口与桌面 / 浏览与编辑 / 媒体 / 系统 / 自定义），不是一条几十项的长列表。

**手势导航**（Logi Options+ 风格）：把一个键设成手势导航，然后按住它——

| 操作 | 结果 |
|---|---|
| 原地单击（位移 ≤ 10px） | 调度中心 |
| 上划 | 调度中心 |
| 下划 | 应用程序窗口 |
| 左划 | 切到**右**边的桌面 |
| 右划 | 切到**左**边的桌面 |

横向是刻意反的：把鼠标往左推等于把当前桌面推开，和触控板划动同向。阈值 40px，某一轴要比另一轴多出 1.2 倍才算数（避免斜着划时替你乱猜），**一次按住只触发一个动作**——否则一次长划会反复越过阈值，一下跳三个桌面。手势期间指针原地不动。

其他动作：调度中心、应用程序窗口、显示桌面、启动台、左右切换桌面、后退 / 前进、新建 / 关闭标签页、复制 / 粘贴、放大 / 缩小、播放暂停、上下一曲、音量增减、静音、锁定屏幕、**自定义快捷键**、**打开指定应用**、**按住拖动以滚动**。

### 应用例外

为指定应用**完全不干预**，或使用**独立的滚动参数**。菜单栏可以一键为当前最前面的应用停用。

### 其他

- 冲突检测：同类软件在运行时直接点名
- 实时诊断：拦截了多少、合成了多少、合成比、帧源是 vsync 还是定时器兜底
- 检查更新：读取 GitHub Releases 的最新发布，有新版本就提示并链到发布页，不自动安装
- 登录时启动（`SMAppService`）
- 空闲时零开销：没有滚动时帧源会被销毁，事件掩码只订阅当前配置真正需要的事件

---

## 环境要求

- macOS 14 及以上
- 构建只需 **Xcode Command Line Tools**（不需要完整 Xcode）：`xcode-select --install`

## 构建与安装

```bash
make app        # 编译 + 组装 .app + 签名 → build/Open Mouse.app
make run        # 上面这些，然后启动
make install    # 拷到 /Applications 并启动（登录项注册需要装在这里）
make test       # 跑内置逻辑自检
make clean
```

首次启动会要求**辅助功能**权限：

> 系统设置 › 隐私与安全性 › 辅助功能 → 打开 Open Mouse

授权后引擎会在一秒内自动接管，不需要重启应用。配置存放在 `~/Library/Application Support/OpenMouse/preferences.json`，是给人看的 JSON，可以直接编辑。

### 关于签名与权限失效

TCC 记录辅助功能授权时会同时参考 bundle id、代码签名身份和二进制的 cdhash。构建脚本会自动挑一个可用的 `Apple Development` / `Developer ID` 证书签名（按证书**哈希**而不是名字选，因为钥匙串里常有多张同名证书导致 `codesign` 报 ambiguous）。

实测结论：用固定签名身份时，授权能扛过反复重新构建。但**刚重新签名后的第一次启动**可能短暂读不到授权（顶部弹出权限提示），下次启动就恢复了——看到提示先点「重新检查」，不要急着去系统设置里反复勾选。

如果机器上没有任何签名证书，脚本会退回 ad-hoc 签名，那么基本上每次重新构建都要重新授权。换过签名身份、或者系统设置里的条目变成了幽灵项（勾了也不生效），用这个清掉重来：

```bash
make tcc-reset   # tccutil reset Accessibility com.openmouse.OpenMouse
```

## 命令行开关

```bash
OpenMouse --self-check                  # 跑逻辑自检并退出，返回码即结果
OpenMouse --verbose                     # 把事件管线计数实时打到 stderr
OpenMouse --tab buttons                 # 启动即打开指定设置页（scroll/buttons/apps/general）
OpenMouse --check-update owner/repo     # 走真实网络检查更新并退出
```

`--verbose` 是排查「到底有没有在工作」最快的手段：

```
[  0.000] accessibility trusted: true
[  0.000] engine status: running
[  0.000] scroll: smoothing=true minStep=33.6 speed=2.7 smoothness=0.915 rate=0.085 ...
[  4.251] smoothed=3  synthesized=7  frameSource=displayLink amplification=2.3x
[  4.501] smoothed=11 synthesized=37 amplification=3.4x
[  4.751] smoothed=12 synthesized=67 amplification=5.6x
[  5.001]             synthesized=83 amplification=6.9x
```

`smoothed` 是被吞掉的滚轮格数，`synthesized` 是合成出去的像素滚动事件数。后者显著大于前者说明插值在跑；最后一行 `smoothed` 不涨而 `synthesized` 还在涨，那是输入停止后的惯性尾巴。`frameSource=displayLink` 表示帧源锁到了显示器 vsync；如果显示 `timer`，说明降级到了定时器兜底，那滚动会带轻微抖动。

---

## 实现要点

```
main.swift ──▶ AppDelegate ──▶ StatusItemController（菜单栏）
                    │
                    ├─▶ MouseEngine        事件掩码决策、tap 生命周期、权限轮询
                    │      └─▶ EventTapController   CGEventTap + 超时自动重启
                    │             └─▶ EventRouter   放行 / 改写 / 吞掉的判定
                    │                    ├─▶ ScrollAnimator
                    │                    │     ├─▶ ScrollAxis              一级：指数缓动
                    │                    │     ├─▶ ScrollSmoothingFilter   二级：一阶低通
                    │                    │     ├─▶ DisplayLinkTicker       vsync 帧源
                    │                    │     └─▶ ScrollEventPoster       postToPid 投递
                    │                    ├─▶ MouseGestureRecognizer（手势导航）
                    │                    └─▶ ActionRunner（按键动作）
                    │
                    ├─▶ SettingsStore      JSON 持久化 + ResolvedConfig 快照
                    ├─▶ ConflictMonitor    同类软件检测（事件驱动，不轮询）
                    ├─▶ UpdateCoordinator ──▶ UpdateChecker（GitHub Releases）
                    └─▶ SettingsWindowController ──▶ SwiftUI 设置界面
```

### 滚动管线：为什么要两级

只做插值还不够顺。一级的指数缓动每帧发送剩余距离的固定比例，问题是**第一帧就是最大的一帧**：默认参数下一格滚轮的第一帧直接发 `90 × 0.085 ≈ 7.65px`，凭空出现的这个突起就是每次滚动起手时的那一下「踢脚」。

Mos 用 `ScrollFilter` 解决这个问题（注释写着「用于去除滚动的起始抖动」）。它的 `polish` 生成一个 5 元数组，但只有下标 0 和 1 会被读，所以等效递推就是一个 **α = 0.23 的一阶低通，输出比输入滞后一帧**。这一级把那个突起摊到几帧里爬升上去。

所以顺序是：**指数缓动产生惯性 → 一阶低通削掉起手突起 → vsync 帧源发送**。滤波器有滞后，所以缓动收敛之后动画不能立刻停——必须等滤波器也排空，否则每次滚动的尾巴都会被切掉。

几个容易踩的坑，以及这里的处理方式：

**1. 怎么区分鼠标和触控板**
看 `kCGScrollWheelEventIsContinuous`。触控板和 Magic Mouse 本身就上报像素级连续增量，值为 1；滚轮鼠标是按「行」计数的离散事件，值为 0。默认只对后者做平滑——触控板已经是平滑的，吞掉它的事件会破坏手势与惯性。

**2. 原始增量要优先取 `PointDelta` 而不是行数**
`PointDelta` 是系统已经算好的像素增量，里面包含了 macOS 自己的滚动加速，滚得快它就大。取行数的话几乎恒为 ±1，每格永远走同样的距离，快速滚动完全不加速。取值顺序：`PointDelta` → `FixedPtDelta` → `DeltaAxis`，与 Mos 的 `usableValue` 一致。

**3. 合成事件必须声明自己是连续的**
只设 `PointDelta` 不够，还要 `IsContinuous = 1`，否则应用会把它量化回整行，插值等于白做。

**4. 用 `postToPid` 而不是投回 `.cghidEventTap`**
复制原始滚轮事件、只改增量，然后 `postToPid` 直投这一格原本瞄准的进程。这么做有三个好处：保留了原事件的位置 / 修饰键 / 时间戳；不会每帧重新流过我们自己的 tap；**惯性不会跟着光标走**——投回 HID 链的话，惯性还没结束时把鼠标移到另一个窗口，剩下的滚动会落到新窗口去。

**5. 自己发出的事件必须能被自己认出来**
合成事件仍可能重新流过 tap（比如兜底路径）。在 `kCGEventSourceUserData` 上打一个魔数，回调第一件事就是检查它并直接放行，否则一格滚轮会被无限重新插值。

**6. 帧源不要用 `NSScreen.main`**
`NSScreen.main` 的定义是「含有键盘焦点窗口的屏幕」，对没有窗口的菜单栏 App 会返回 **nil**，于是会静默降级到定时器——恰好在最常见的场景里丢掉 vsync。正确做法是取**指针所在的那块屏幕**：那才是即将滚动的屏幕，也该由它的刷新率驱动帧。所以 `--verbose` 会把实际帧源打出来，静默降级看起来和「平滑做得不好」一模一样。

顺便：这里用 `NSScreen.displayLink(target:selector:)`（macOS 14+）而不是 `CVDisplayLink`。后者已废弃，而且显示器唤醒 / 重连时会先报一个过渡刷新率，绑上去就只按低帧率绘制（Mos 为此专门写了刷新率复查逻辑，见其 issue #958）。帧源跑在独立线程的 run loop 上：事件 tap 和 SwiftUI 都在主 run loop，设置窗口正在重排版时不能拖慢滚动帧——否则用户调滑块的时候手感最差。

**7. 系统会偷偷关掉你的 tap**
回调超时后 macOS 会发一个 `tapDisabledByTimeout` 然后停用 tap，唯一的补救是收到它时自己 `CGEvent.tapEnable` 重新打开。不处理的话，应用看起来就是「用一阵子突然失灵」。发生次数会记在诊断面板里。相关地，按键动作一律 `DispatchQueue.main.async` 出去执行，不在 tap 回调里同步发合成按键——那会重新进入事件管线并占用回调时间。

**8. 反转方向要把三种增量都取反**
`DeltaAxis`（整数行）、`PointDelta`（整数像素）、`FixedPtDelta`（浮点像素）三个字段都得翻。漏掉任何一个，读那个字段的应用就会朝反方向滚。整数字段用整数存取器、浮点字段用浮点存取器，避免静默截断。

**9. 不要在 tap 回调里查最前面的应用**
那是一次 IPC 往返，而回调每个滚动事件都会跑。这里缓存 `frontmostBundleID`，只在收到 `didActivateApplicationNotification` 时失效重算，并把结果压成一个 `ResolvedConfig` 值类型快照供回调读取。

**10. 权限授予没有通知**
系统不会在用户勾选辅助功能时通知你。只能在被权限阻塞时轮询（这里 1 秒一次），拿到权限立刻启动，然后停止轮询。

**11. 配置文件的每个片段都要能单独降级**
Swift 合成的 `Decodable` **不使用属性默认值**：少一个键就抛错。如果整份配置是一次性解码的，那么将来给某个结构加一个字段，就会让所有老用户的**全部**设置被重置。所以 `Preferences` 及其各个子结构都手写了 `init(from:)`，逐字段独立回退。这条不是理论——按键从「预设中键+四个侧键」改成「录入式」时，正是它保住了用户已经配好的映射。

**12. Swift 语言模式**
`Package.swift` 里指定了 `.swiftLanguageMode(.v5)`。事件 tap 天生是 C 函数指针回调 + `Unmanaged` 指针，跑在主 run loop 上；Swift 6 的严格隔离会让这层代码充满仪式性的样板。跨线程共享的状态（配置快照、动画状态、滤波器、计数器）统一走 `Locked`（`OSAllocatedUnfairLock`）。

### 为什么测试是 `--self-check` 而不是测试 target

XCTest 和 swift-testing 都随 **Xcode** 提供，Command Line Tools 里没有。只装了 CLT 的机器连测试 target 都编译不出来。所以这些断言放在 app target 内，用 `OpenMouse --self-check` 跑——任何能构建这个应用的机器都能跑，同时它对已发布的构建也是一个可用的诊断。如果之后装了完整 Xcode，把 `SelfCheck.swift` 里的检查搬进 swift-testing 的 `@Test` 是机械改写。

自检里专门有一组「Mos 手感对齐」，把 `33.6`、`2.70`、`1 - √(4.35/5.2)`、`0.23` 这些换算关系钉住了。参数被误改会立刻失败，而不是等到某天有人觉得「好像没那么顺了」。

---

## 已知限制与后续方向

- **HID++ 层未实现。** Logitech 的 SmartShift、硬件 DPI 档位、高分辨率滚轮棘轮开关这些只能通过 HID++（IOKit HID）拿到，`CGEventTap` 看不见。这需要额外的**输入监控**权限，而且蓝牙直连下 Logi Options+ 会持续抢回控制权。定位应该是可选增强层，且只在 Unifying/Bolt 接收器这类传输上启用。
- **指针加速与 DPI 未实现**（LinearMouse 覆盖这块），目前只做滚动与按键。
- 手势导航目前是一次按住一个动作。Mos 那边试过在同一次按住里做横向连划，但很容易一下跳过好几个桌面，所以也收敛成了一次一个。
- 界面目前只有中文文案，全部集中在 `Strings.swift`，本地化是机械工作。
- 没有做 Apple 公证（notarization），首次打开需要在「系统设置 › 隐私与安全性」里放行。
