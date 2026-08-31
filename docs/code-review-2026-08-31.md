# 代码审查报告 — 2026-08-31

审查对象：`open_mouse` @ `main`（v0.1.0 发布后）。全量 6,256 行，10 个独立视角扫描 + 逐条验证。

审查时的构建状态：`swift build -c release` 干净无警告，`make test` **136/136 全过**。
也就是说下面每一条都**不在现有断言的覆盖范围内**——这本身是问题之一，见 [§4](#4-自检与文档的准确性问题)。

## 修复进度

按 [§6](#6-建议的修复顺序) 分批修，这里是当前状态。**在另一台机器上接着修的话先看这一节。**

| 批次 | 内容 | 状态 |
|---|---|---|
| 1 | F1、`cancel()` 漏重置运行态、F5、C3 | **已修复并核实**（自检 136 → 143 项） |
| 2 | F3 | 未开始 |
| 3 | F4、F2、§4.3 三处潜伏漂移、§4.2 两条同义反复的断言 | 未开始 |
| 4 | F7、F9、F10、F11 | 未开始 |
| 5 | F8、F6、F12、F14、F13、F15、C1、C2、C4 | 未开始 |

第 1 批的核实方式：读代码确认锁序无反转（animator 锁 → ticker 锁，三个调用点方向一致）、真机 26 段滑行放大稳定在 9.6x 且无投递失败、空闲 CPU 0.0%。遗留的三点小问题记在 §6 末尾。

`CLAUDE.md` 里 §4 指出的两句假话已经改掉了（约束 11 的覆盖范围、测试一节声称的断言覆盖）。

## 怎么读这份文档

- **判定**一栏只有两种值：
  - `已确认` —— 我直接读源码确认了代码事实与推导链条。
  - `待确认` —— 逻辑成立，但触发它需要一个尚未证明会真实发生的输入。修之前先判断值不值得。
- 每条都给了**修复要建立的性质**而不是具体补丁。挑实现方式是修的人的事，但那条性质必须成立。
- **应补断言**一栏不是可选项。项目的约定是「修 bug 之后要补一条断言」，而 §4 说明了为什么这次特别重要。
- 编号 `F1`–`F15` 是已验证的缺陷，`C1`–`C9` 是未逐条验证的候选项。

## 优先级总表

| # | 位置 | 问题 | 判定 |
|---|---|---|---|
| **P0 —— 滚轮永久失效，只能重启进程** | | | |
| F1 | `Core/ScrollEngine.swift:197` | `running` 与帧源生命周期不在同一临界区，竞态后闩死 | 已确认 |
| F5 | `Core/ScrollAxis.swift:39` | 无 `isFinite` 检查，一个 NaN 让动画永不终止 | 待确认 |
| **P1 —— 已经破掉的硬性约束** | | | |
| F4 | `Core/EventRouter.swift:277` | 约束 8：`PointDelta` 用了整数存取器，亚像素增量被抹成 0 | 已确认 |
| F2 | `Core/KeyboardLayout.swift:31` | 约束 5：键码兜底返回 `0`（一个真键），发出另一个快捷键 | 已确认 |
| F3 | `Model/Settings.swift:118` | 约束 11：`KeyCombo` / `MouseAction` 没有手写 `init(from:)`，会静默清空用户映射 | 已确认 |
| **P2 —— 功能性缺陷** | | | |
| F7 | `Core/EventRouter.swift:320` | 松开修饰键再松开按键，手势会话被搁死，motion tap 永久订阅 | 已确认 |
| F9 | `Core/MouseEngine.swift:109` | 未授权分支不拆 motion tap，`isRunning` 变陈旧真，重新授权后手势永久失效 | 已确认 |
| F10 | `Core/MouseEngine.swift:59` | 手势拆除钩子挂在了不带按键事件的那个 tap 上 | 已确认 |
| F11 | `Core/EventRouter.swift:129` | 平滑分支无视 `reverseContinuousDevices`，触控板被违愿反向 | 已确认 |
| F8 | `Model/ActionKind.swift:299` | 自定义快捷键默认 `keyCode: 0`，未录入就会打出一个字母 | 已确认 |
| F6 | `Core/MouseGestureRecognizer.swift:106` | 10–40px 与所有斜划既不触发方向也不算单击，按键表现为坏了 | 已确认 |
| F12 | `Model/Settings.swift:381` | 应用规则按最前应用取，事件按 `postToPid` 投——两者不同一时规则用错进程 | 已确认 |
| F14 | `Core/UpdateCoordinator.swift:29` | 「每 24 小时」实际是「每次启动一次」；`跳过此版本` 写了个没人读的字段 | 已确认 |
| F13 | `Core/UpdateChecker.swift:38` | 解析不出的版本号被报成「已是最新版本」 | 待确认 |
| F15 | `Scripts/bundle.sh:41` | `make dist` 可能用开发证书签名，产出无法公证、别人打不开的包 | 已确认 |

---

## 1. P0：两个会让滚轮永久失效的闩锁

这两条要单独成节，因为它们命中的正是整个架构在防的那一种失效：**事件被吞掉、系统不理、用户看到的是「滚轮没反应」**。而且两者都**无法由用户恢复**。

先说清楚这个共同前提：

```swift
// ScrollEngine.swift:150 —— cancel()
func cancel() {
    state.withValue { state in
        state.vertical.reset()
        state.horizontal.reset()
        state.filterY.reset()
        state.filterX.reset()
        state.target = nil
        // ← 没有 state.running = false
    }
}
```

`cancel()` 重置了轴、两个滤波器和 target，**唯独没有重置 `running`**。而 `running` 恰好是 F1 和 F5 闩死的那个位。所以：设置里关掉再打开不行（走的是 `cancel()`），撤销再重新授权也不行，只能杀掉进程重启。

### F1 —— `running` 与帧源生命周期不在同一临界区（已确认）

**位置**：`Core/ScrollEngine.swift:197`（`tick()` 的 `.finish` 分支）、`:142`（`enqueue()` 的守卫）、`:167`（`startTicker()`）、`Core/DisplayLinkTicker.swift:73`（`start()` 的守卫）

**线程配对**：`enqueue()` 跑在事件 tap 回调（主 run loop），`tick()` 跑在 display link 自己那条线程的 run loop。两者真的会交错。

**触发路径**：

1. 一次滑动的最后一帧，`tick()` 在锁**里**把 `state.running = false`，返回 `.finish`
2. 出锁。`.ended` 相位下先做一次 `poster.post()`——一次 IPC 往返，把窗口拉得很宽
3. 此时一格滚轮到达：`enqueue()` 过掉 `guard !state.running`（此时已是 false），置 `running = true`，调 `startTicker()`
4. `DisplayLinkTicker.start()` 撞上 `guard !alreadyRunning else { return }`——`alreadyRunning` 判的是 `link != nil || fallbackTimer != nil`，而 `link` 还没被清掉，**于是什么都不做直接返回**
5. `tick()` 继续执行 `stopTicker()`，把 `link` 置 nil、线程 cancel

**终态**：`running == true`，但没有任何帧源。此后每一次 `enqueue()` 都因 `guard !state.running` 返回 `shouldStart == false`，而永远不会再有 `tick()` 来把 `running` 清掉。`EventRouter.handleWheel` 于是对每一格滚轮都返回 `nil`（吞掉）。

**根因**：`running` 这个布尔量声称的是「有一个帧源正在跑」，但它的翻转和帧源的实际生死不在同一个临界区里，而 `start()` 判断「是否已在跑」用的又是第三个事实（`link != nil`）。三处对同一件事各有一份真相。

**修复要建立的性质**：

> `state.running == true` ⟺ 存在一个活着的帧源。这条等价关系必须在单个临界区内维持。

具体走哪条路自己定，但要注意两个坑：

- 单纯把 `running = false` 挪到 `stopTicker()` **之后**没用——中间到达的 `enqueue()` 会看到 `running == true` 而返回 `shouldStart == false`，帧源随后被拆掉，同样闩死。
- `start()` 必须在主线程调用（`NSScreen` 是 main-actor 状态），所以不能简单地把整个 ticker 生命周期塞进 `tick()` 持有的那把锁里。可行方向之一是让 ticker 句柄进同一个 `Locked`，并让 `start()` 以 `running` 而非 `link != nil` 作为幂等判据；另一条是引入代次计数器让 stop/start 串行化。

**另外必须做的**（不管 F1 怎么修）：`cancel()` 要一并重置 `running` **并**拆掉帧源。它现在是唯一一条用户能触达的恢复路径，却恰好漏掉了那个位。

**应补断言**：现在这个组里没有任何东西检查 `running` 与帧源的一致性。至少要有一条能覆盖「结束帧与新一格交错」的顺序：把 `tick()` 走到 `.finish`、在 `stopTicker()` 之前注入一次 `enqueue()`，然后断言帧源仍然活着或 `running` 已被清掉——两者必有其一成立。要做到这一点可能需要把帧源抽成一个可注入的协议，值得。

### F5 —— 无 `isFinite` 检查，NaN 让动画永不终止（待确认）

**位置**：`Core/ScrollAxis.swift:39`（`advance()`）；入口在 `Core/EventRouter.swift:158`（`rawDelta`）和 `travel(forRawDelta:)`

**现象**：从 CGEvent 增量到缓动累加器之间，全程没有任何有限性检查。一个 `Inf` 乘上符号就得到 `NaN`。

**为什么 NaN 会让终止条件不可达**——三个判断全部失效，方向还都是「错」的那一侧：

| 判断 | NaN 下的取值 | 期望 |
|---|---|---|
| `remaining != 0` | `true` | 应为 false |
| `abs(remaining) < settleThreshold` | `false` | 应为 true |
| `abs(remaining) < 0.001` | `false` | 应为 true |

于是 `isIdle` 永远不成立。同时 `ScrollSmoothingFilter.isDraining`（`abs(state) >= 0.001`）在 NaN 下为 `false`，所以 `drained == true`。`tick()` 里 `if axesIdle, drained`（`ScrollEngine.swift:196`）永远进不去 → `.finish` 永不触发 → `stopTicker()` 永不被调用。

**终态**：ticker 按显示器刷新率（120Hz）空转烧电，同时每一格滚轮都被吞。滤波器状态被污染到进程结束，因为 `reset()` 只在那个不可达的分支和 `cancel()` 里被调到。

**为什么是「待确认」**：缺少检查这件事是确定的；但 macOS 是否真的会上报一个非有限的滚动增量未经证明。**建议照修**——一次 `isFinite` 判断的成本对比「永久空转 + 滚轮全失效」完全不成比例，而且这个检查同时也是对畸形第三方驱动事件的防线。

**修复要建立的性质**：

> 进入累加器的每个增量都是有限值；任何非有限输入在管线入口被丢弃并放行原事件（约束 2：投不出去就不要吞）。

**应补断言**：喂一个 `.infinity` 和一个 `.nan` 给 `ScrollAxis.add(_:)` / `travel(forRawDelta:)`，断言 `isIdle` 在有限步数内成立。

---

## 2. P1：已经破掉的硬性约束

三条都以同一种方式破的：**约束靠每个调用点自己遵守，而不是收在一个必经的收口处**。所以修法不只是改这三处，还要考虑能不能让下一次漂移编译不过或被断言抓住。

### F4 —— 约束 8：`PointDelta` 用了整数存取器（已确认）

**位置**：`Core/EventRouter.swift:277-280`（垂直）、`:291-294`（水平）

**代码事实**——我把两边并排读过：

```swift
// open_mouse, EventRouter.swift:277
event.setIntegerValueField(
    .scrollWheelEventPointDeltaAxis1,
    value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
)
```

```swift
// ~/workspace/Mos/Mos/ScrollCore/ScrollEvent.swift:124 —— MEMORY.md 指定的事实来源
scrollEvent.event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -scrollEvent.Y.scrollFix)
scrollEvent.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -scrollEvent.Y.scrollPt)
scrollEvent.event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -scrollEvent.Y.scrollFixPt)
```

Mos 对 `PointDelta` 用 `setDoubleValueField`，只对 `DeltaAxis` 用整数存取器。

**这个项目自己的其他地方也和 Mos 一致**——`EventRouter.swift:160`（`rawDelta`）和 `ScrollEngine.swift:62` 都用浮点存取器读 `PointDelta`。**只有 `flipAxes` 一处不一致**，而它的注释（`:269-270`）还明确写着与参考实现相反的断言：

```
/// The line and point deltas are integer fields and the fixed-point ones are doubles;
/// each is read back with the matching accessor so nothing is silently truncated.
```

这句话是错的，而且它正是让这个 bug 看起来「已经想过了」的原因。修的时候连注释一起改。

**失效场景**：高分辨率 / 自由滚轮，或走「连续设备不平滑但反向」那条路（`:141`）的 Magic Mouse，增量为 0.5 这类亚像素值时：`getIntegerValueField` 返回 0，取反得 `-0`，像素增量被**抹掉**而不是取反。应用读 `NSEvent.scrollingDeltaY` 得到 0 —— 反向看起来像「滚不动了」，而不是「反了」。

**修复要建立的性质**：

> 每个增量字段都用与其真实类型匹配的存取器读写，且这一点在项目内只有一个地方定义。

考虑把「三个字段 + 各自的存取器」抽成一处（比如一个 `ScrollField` 描述表），让 `flipAxes`、`rawDelta`、`ScrollEventPoster` 都从它取，这样存取器不匹配就没有第二个地方可以漂移。

**应补断言**：构造一个 `PointDelta = 0.5` 的 CGEvent，翻转后断言读回 `-0.5`。`flipAxes` 目前是 `private`，需要放开可见性——这是可接受的代价，约束 8 现在一条断言都没有。

### F2 —— 约束 5：键码兜底返回 `0`，那是一个真键（已确认）

**位置**：`Core/KeyboardLayout.swift:31`（兜底）、`:70`（缓存失败的读取）、`:110`（构表时不带修饰键）

**现象**：

```swift
return ansiFallback[character] ?? 0   // 0 == kVK_ANSI_A
```

兜底值 `0` 不是「无效」哨兵，是 A 键的物理位置。

**覆盖缺口**：`ActionRunner.stroke(for:)` 实际用到 24 个字符 —— `m h w q [ ] t c v x z a f = - n d i g 1 2 3 4 8`。`ansiFallback` 只有 9 个 —— `c v w t q [ ] - =`。缺的 15 个里包含 `1 2 3 4`（Finder 四种显示方式）和 `8`（反转颜色）。

**为什么数字键特别危险**：`build()` 在 `:110` 用**零修饰键**做翻译。法语 AZERTY 上数字要按 Shift 才出，所以它们**永远进不了那张表**，必然落到兜底。`viewAsIcons`（⌘1）于是解析成键码 0 —— AZERTY 上那个位置打的是 **Q** —— 实际发出 **⌘Q**，退出当前应用、丢掉未保存内容。

约束 5 自己的措辞已经预言了这一类后果：**不是「失效」而是发出另一个快捷键**。

**`:70` 让这件事从「小语种用户遭殃」变成「所有人都可能遭殃」**：

```swift
let built = build() ?? [:]
```

一次 TIS 读取失败（启动早期、输入法尚未初始化、快速用户切换）就把**空表**永久缓存下来——`invalidate()` 只挂在输入源变更通知上，不会因为这次失败而重试。此后整个会话里 24 个字符全部退化到那 9 条兜底。

**修复要建立的性质**（两条，都要）：

> 1. 解析不出键码时返回「无」而不是某个真键，调用方据此放弃动作并记一条带原因的日志（对齐 `postSystemHotkey` 已有的做法：**silence with a reason beats silence**）。
> 2. 一次失败的布局读取不得被缓存为成功结果。

顺带看一下 `build()` 要不要带 Shift 再翻译一轮，把数字键真正纳入表内——但即便如此，第 1 条仍然必须成立。

**应补断言**：现有的 `hasFallbackForEveryCharacter`（`SelfCheck.swift:818`）是同义反复的，见 §4——它必须改成从 `ActionRunner.stroke(for:)` **反向枚举**实际用到的字符集，再断言每个都能解析出非 `nil` 键码。

### F3 —— 约束 11：`KeyCombo` / `MouseAction` 没有手写 `init(from:)`（已确认）

**位置**：`Model/Settings.swift:106`（`KeyCombo`）、`:118`（`MouseAction`）

**代码事实**（grep 确认）：`Settings.swift` 里的 `init(from decoder:)` 在 77、217、280、312、334 行，分别属于 `ScrollSettings`、`ButtonBinding`、`AppRule`、`UpdateSettings`、`Preferences`。`KeyCombo` 和 `MouseAction` **一个都没有**，用的是 Swift 合成的 `Decodable`。

约束 11 要求 `Preferences` **及其子结构**都手写。CLAUDE.md 第 83 行还断言这三个「全部手写 `init(from:)`」——对其中两个是假的，见 §4。

**数据丢失链条**：

1. 给 `KeyCombo` 加一个字段，或改名 / 删除任一 `MouseAction` case
2. 老配置里的 `.keyStroke` 解码抛错
3. `ButtonBinding.init(from:)` 把错误映射成 `?? .passthrough`（`:222`）
4. `normalize()` 执行 `buttons.removeAll { !$0.isActive }`（`:354`）
5. `SettingsStore` 在 mutation 时自动保存（`SettingsStore.swift:14`）

**结果**：在新版本上启动**一次**，`preferences.json` 里所有自定义按键映射被静默清空。没有备份，无法恢复。这正是约束 11 存在的理由——而且它现在是**已装填状态**，下一个碰这两个类型的人就会触发。

**修复要建立的性质**：

> `Preferences` 可达的每个 `Decodable` 类型，遇到未知或缺失的键都降级到默认值，绝不抛错；解码任何单个按键绑定失败都不得导致其他绑定被丢弃。

`MouseAction` 是带关联值的枚举，手写 `init(from:)` 要留意未知 case 的降级（降到 `.passthrough` 并保留原始 payload，还是整条绑定跳过并保留其余的——后者更符合上面那条性质）。

**应补断言**：喂一份含未知 `MouseAction` 判别值和多出一个未知字段的 `KeyCombo` 的 JSON，断言其余绑定**全部存活**。约束 11 现在只有 `Preferences` 层被覆盖到。

---

## 3. P2：功能性缺陷

### F7 —— 按键松开时重新解析绑定，手势会话被搁死（已确认）

**位置**：`Core/EventRouter.swift:320`（`handleButton`）、`:317`、`:354-355`（被违背的注释）、`Model/Settings.swift:230-236`（`resolve`）

**现象**：`handleButton` 对按下和松开**都**调用 `bindings.value.resolve(button:modifiers:)`。绑定是「⌘ + 侧键 4」时，按下带 ⌘ 命中；但用户**先松 ⌘ 再松按键**的话，松开事件的 `modifiers == 0`，`resolve` 跳过精确匹配分支、又找不到无修饰键绑定，返回 `nil` → `:322` 把 mouse-up **放行**。

这直接违背 `:354-355` 自己写下的不变量：*swallow the matching release, so the app underneath never sees half a click*。

**三重后果**（比「漏一个 up」严重）：

1. 下方应用收到一个没有配对 down 的裸 mouse-up
2. `gestureSessions[button]` 永远不被移除 → `onGestureActivityChanged(false)` 永不触发 → **motion tap 在整个进程生命周期里保持订阅 `.mouseMoved`**（系统里最密集的事件流，正是它只在手势期间开启的理由）
3. 识别器仍处于待命状态 → **下一次普通指针移动超过 40px 就会触发一次莫名的桌面切换**

`config.value.buttonsActive` 在按住过程中翻假（`:317`）也会走进同一个搁死状态。

**修复要建立的性质**：

> 一个被吞掉的按下，其配对的松开必须无条件被吞掉并完成会话拆除，与当时的修饰键状态和配置状态无关。

也就是说：按下时把「这个按键的这一次按住归我处理」记下来，松开时**查这份记录**，而不是重新解析绑定。

**应补断言**：模拟「带修饰键按下 → 无修饰键松开」，断言会话已拆除且 up 被吞掉。

### F9 —— 未授权分支不拆 motion tap，`isRunning` 变成陈旧的真（已确认）

**位置**：`Core/MouseEngine.swift:108-113`（`needsPermission` 分支）、对照 `:99-106`（`disabled` 分支）、`:182`（`setMotionTapRunning`）、`Core/EventTapController.swift:93`

**两条分支不对称**：

| | `tap.stop()` | `motionTap.stop()` | `cancelGestures()` | `cancelInFlightScrolling()` |
|---|---|---|---|---|
| 偏好关闭（`:99-106`） | ✓ | ✓ | ✓ | ✓ |
| 无辅助功能权限（`:108-113`） | ✓ | ✗ | ✗ | ✗ |

**为什么会永久失效**：`EventTapController.isRunning` 只在 `stop()` 内部被置假（`EventTapController.swift:93`）。权限被撤销时系统已经把 tap 作废了，但没人调 `stop()`，所以它**仍然报 `isRunning == true`**。用户重新授权后，`setMotionTapRunning(true)` 的 `guard !motionTap.isRunning`（`:182`）看到陈旧的真值直接返回 → motion tap 永远不会被重建 → **手势导航在该进程内永久死亡**。

**顺带**：1Hz 权限轮询（`:202`）只在 `isTrusted` 翻转时失效——`stop()`（`:86`）和 `.off` 分支都不取消它，所以在一台永远不给授权的机器上它会一直跳到进程结束。CLAUDE.md 明确写了「拿到就启动并停止轮询」，这里只做了一半。

**修复要建立的性质**：

> 所有把引擎带出运行态的分支，拆除动作完全一致；`isRunning` 反映的是「这个 tap 现在真的活着」，而不是「上一次 start 成功过」。

考虑把三条分支的拆除动作抽成一个 `teardown()`，让「新增一条状态分支时忘了拆某个东西」不再可能。

**应补断言**：模拟 `needsPermission → active` 转换，断言 motion tap 能被重新启动。

### F10 —— 手势拆除钩子挂在了不带按键事件的那个 tap 上（已确认）

**位置**：`Core/MouseEngine.swift:54`、`:57-58`（注释）、`:59`、`:160`（`eventMask`）、`:171`（`motionMask`）、`Core/EventTapController.swift:107`

**注释说的是对的**：tap 在按住过程中被停用时，它永远看不到那个 button-up，所以必须显式拆除会话。

**但接线是反的**：

- `motionMask`（`:171`）= `mouseMoved` + 三种 drag —— **不含** `.otherMouseUp`
- `.otherMouseUp` 只由主 tap 通过 `eventMask`（`:160`）订阅
- 而 `cancelGestures()` 挂在 **motion tap** 的 `onAutoReenable` 上
- **主 tap** 的 `onAutoReenable`（`:54`）只做 `autoReenableCount += 1`

于是真正会丢掉 button-up 的那种情况——主 tap 在按住过程中被停用——什么都不做。会话保持待命、motion tap 保持活着，下一次指针移动超过 40px 就是一次假的桌面切换。**两个闭包实际上是调换了的。**

**雪上加霜**：`EventTapController.dispatch` 对 `.tapDisabledByUserInput`（`EventTapController.swift:107`）的处理是直接重新启用，**从不调用 `onAutoReenable`**。所以即便上面的接线改对了，这条停用路径依然不做任何拆除，也不留任何诊断痕迹。约束 10 只落实了一半。

**修复要建立的性质**：

> 任何一条 tap 停用/重启路径都会触发手势会话拆除，且拆除挂在真正持有按键事件的那个 tap 上；两种停用原因都产生可观测的诊断。

**应补断言**：约束 10 现在零覆盖。至少断言 `.tapDisabledByTimeout` 和 `.tapDisabledByUserInput` 两条路径都会调到拆除钩子。

### F11 —— 平滑分支无视 `reverseContinuousDevices`（已确认）

**位置**：`Core/EventRouter.swift:129-130`（平滑分支）、`:116`（`wantsReverse`）、对照 `:140-146`（非平滑分支）、`:125-128`（投不出去的兜底）、`Model/Settings.swift:20`、`:40-42`

**现象**：`wantsReverse`（`:116`）正确地把 `reverseContinuousDevices` 纳入判断，非平滑分支也照做了（`:140-146`）。但**平滑分支的 `signY` / `signX` 直接取 `reverseVertical` / `reverseHorizontal`**，`wantsReverse` 在那里根本没被用到。

字段语义在 `Settings.swift` 里写得很清楚：`reverseContinuousDevices` 是连续设备的**闸门**（*Reverse continuous devices too. Independent of affectContinuousDevices*），`reverseVertical` 是**只对鼠标**的自然滚动开关。

**失效组合**：反向垂直开 + 平滑触控板开 + 反向触控板关 → 触控板照样被反向。**而这恰好是设两个独立开关唯一想表达的那个组合。**

**同一处还有第二个不一致**：`:125-128` 那条「取不到投递目标」的兜底路径**不翻转**就放行，而滚轮路径在同样情形下**会翻转**（`:229`）。结果是在一个拿不到路由 pid 的窗口上，触控板和滚轮朝相反方向滚。

**修复要建立的性质**：

> 「是否反向」由单一判定产出，平滑与非平滑、可投递与不可投递四条路径全部消费同一个结果。

**应补断言**：把四条路径 × 反向开关的组合钉住，尤其是上面那个「反向垂直开 + 反向触控板关」的组合。

### F8 —— 自定义快捷键默认 `keyCode: 0`，未录入就会打出一个字母（已确认）

**位置**：`Model/ActionKind.swift:299`（`makeAction(preserving:)`）、`Core/ActionRunner.swift:208`（`.custom`）、`:289`（`keyStroke`）

**现象**：当前动作不是 `.keyStroke` 时，`makeAction(preserving:)` 返回

```swift
.keyStroke(KeyCombo(keyCode: 0, modifiers: 0))
```

键码 0 无修饰键在 ANSI 上就是打 `a` 的那个位置。`ActionRunner` 的 `.custom` 分支**不做任何有效性检查**，`keyStroke` 照样构造并投出去。

**用户路径**：在选择器里选了「自定义快捷键」，然后**没有录入就关掉了面板**（或者中途被打断）——这个鼠标键从此在每一次点击时往当前文档 / 邮件草稿 / 终端里插入一个字母。`SettingsStore` 自动保存，重启后依然如此。

项目里已经有「未绑定」哨兵（`65535`，见 `SystemHotkeys` 对它的处理），这里没有用。

**修复要建立的性质**：

> 尚未录入的自定义快捷键是一个可表示的、不会投出任何东西的状态，并且在界面上可见地标为「未设置」。

用 `65535` 复用现有哨兵是最省的做法，投递前 guard 掉。

**应补断言**：断言未录入的 `.keyStroke` 不产生任何按键投递。

### F6 —— 手势的死区与斜划（已确认）

**位置**：`Core/MouseGestureRecognizer.swift:106`（`recognized`）、`:126`（`shouldTreatAsClick`）、`Core/EventRouter.swift:351`

**两个判据之间有个洞**：

- 判定为方向：`max(|dx|,|dy|) >= 40` **且**某轴超过另一轴 1.2 倍
- 判定为原地单击：`maximumDistanceFromOrigin <= 10`

走了 25px 的按住**两个都不满足**。

**更严重的是斜划——与位移大小无关**：接近 45° 时 `horizontal >= vertical * 1.2` 和 `vertical >= horizontal * 1.2` **同时为假**。所以哪怕从屏幕一角划到另一角（300px），什么都不会触发，而 `maximumDistanceFromOrigin`（424）早已远超单击容差。

`EventRouter.swift:351` 对 `.gestureNavigation` 绑定的 `.otherMouseDown` 和 `.otherMouseUp` **都返回 `nil`**，所以上述每一种情况下，**下方应用什么都收不到**——这个侧键在用户看来就是坏的。

峰值 11px 又回到原点的手抖同样被搁在中间，因为 `maximumDistanceFromOrigin` 是个只增不减的游标。

**修复要建立的性质**：

> 每一次被吞掉的按住都必然以某个确定结果收尾——一个方向、一次单击、或者一次显式的「无操作」。不存在既不是方向也不是单击的输入。

最省的做法是让单击判据变成方向判据的补集（够远且有主轴 → 方向；否则 → 单击），而不是两个各自独立的阈值。这样斜划和死区都自然落到「单击」。是否要为斜划单独做四角方向是产品决定，但**不能什么都不做**。

**应补断言**：把 (25px, 0°)、(300px, 45°)、(11px 往返) 三种输入钉住，断言都产出非空结果。

### F12 —— 应用规则按最前应用取，事件按 `postToPid` 投（已确认）

**位置**：`Model/Settings.swift:381`（`ResolvedConfig.init(preferences:frontmostBundleID:)`）、`Core/ScrollEngine.swift:47`（`target(from:)`）、`:73`（`post()`）

**现象**：规则从 `frontmostBundleID` 选，而合成帧由 `postToPid` 投给 `.eventTargetUnixProcessID` —— 也就是**指针所在的那个窗口的进程**。

**这个不一致正是约束 1 存在的理由**。约束 1 说 tap 必须挂在 `.cgAnnotatedSessionEventTap` 而不是 HID 层，理由原文是 HID 层「给的是『最前面的窗口』，不是实际路由目标」。项目在**投递侧**吸取了这个教训，在**规则解析侧**没有。

**失效场景**：macOS 会滚动指针下方的窗口而不聚焦它。所以悬停在某个设了 `.bypass` 规则的应用的后台窗口上滚动，照样会被平滑和反向；同时最前面那个应用的规则被错误地施加到另一个进程的滚动上。

**`.bypass` 是用户对「某个应用在平滑下会坏」的唯一逃生舱，而它恰好在未聚焦窗口这一情形下静默失效。**

**修复要建立的性质**：

> 一次滚动所适用的规则，与这次滚动的帧最终投给的那个进程，是同一个身份。

也就是从事件的 target pid 反查 bundle id 来选规则。注意约束 13：**不要在 tap 回调里做 IPC 往返**——pid → bundle id 需要一层缓存（`NSRunningApplication` 的 pid→bundleID 映射，靠 `didLaunch`/`didTerminate` 通知失效）。

**应补断言**：断言规则解析的输入是 target pid 派生的身份，而不是 `frontmostBundleID`。

### F14 —— 「每 24 小时」实际是「每次启动一次」（已确认）

**位置**：`Core/UpdateCoordinator.swift:29`（`startAutomaticCheckIfDue()`）、`:23`（`pendingRelease`）、唯一调用点 `App/AppDelegate.swift:14`

**现象**：`startAutomaticCheckIfDue()` 只在 `applicationDidFinishLaunching` 里被调一次。没有重复定时器，没有 `NSWorkspace.didWake` 重新触发，打开设置窗口时也不重查。

于是 `automaticInterval` **只在启动那一刻被咨询一次**——这意味着那套 24 小时逻辑只会**抑制**检查，永远不会**安排**一次检查。

**为什么这对这个 App 尤其要紧**：登录时启动、常驻不退出，正是菜单栏工具的正常生命周期，也正是 `make install` 想要的形态。这样的用户**一辈子只检查一次更新**，却以为自动检查是开着的（通用设置页把它标为默认开启）。

**同一处的第二个问题**：`pendingRelease`（`:23`）是 `skippedVersion` 的**唯一读者**，而它**零调用**。所以「跳过此版本」按钮写进了一个没人读的偏好项——横幅无法被跳过，每次启动都会从持久化的 `lastKnownRelease` 里重新出现。

**修复要建立的性质**：

> 自动检查的周期以真实时间流逝为准，而不是以进程启动为准；`跳过此版本` 写入的字段必须被展示逻辑读取。

**应补断言**：断言 `skippedVersion` 有实际读者（这条是可以静态检查的——`pendingRelease` 零调用本身就是信号）。

### F13 —— 解析不出的版本号被报成「已是最新版本」（待确认）

**位置**：`Core/UpdateChecker.swift:38`（`isNewer`）、`:95`（映射到 `.upToDate`）

**现象**：`parts` 在去掉前导 `v` 之后取 `prefix { isNumber || "." }`，所以任何不以数字开头的 tag 都得到空数组。`release-1.2.0`、`OpenMouse-1.2.0`、`stable`、`latest` 都会让 `lhs` 为空 → `:38` 的 guard 返回 `false` → `:95` 报 `.upToDate(current:)`。

`UpdateCoordinator` 随后写入 `lastCheckedAt` 并清掉 `lastKnownRelease`，把重查压制 24 小时——**用户被明确告知自己是最新的**。

同一个 guard 在 `CFBundleShortVersionString` 变成非纯数字时会**永久**杀死更新器（`rhs` 为空）。另外 `compactMap { Int($0) }` 会**丢掉**解析不出的分量并把余下的左移，所以超出 `Int64` 的分量会让 `1e20.99.0` 被当成 `[99, 0]` 比较。

**为什么是「待确认」**：所有触发字符串都在维护者控制之下，当前 tag 都是纯数字的。陷阱确定存在，用户撞上它不确定。

**修复要建立的性质**：

> 版本比较有三种结果：更新、不更新、**无法判断**。第三种绝不能呈现为「已是最新版本」，也不应该压制下一次重查。

**应补断言**：把 `stable`、`release-1.2.0`、空串喂给 `isNewer`，断言结果不是「不更新」。

### F15 —— `make dist` 可能用开发证书签名（已确认）

**位置**：`Scripts/bundle.sh:41`

**现象**：

```bash
grep -E '"(Apple Development|Developer ID Application)' | head -1
```

取的是 `security find-identity -v` 恰好先打印的那一行，而**顺序是未定义的**，开发证书排在 Developer ID 前面很常见。`make dist` 依赖 app target，所以打进 zip 的就是那一份签名。

**为什么产出物是坏的**：hardened runtime（`--options runtime`）+ 仅供开发的叶证书 + 没有安全时间戳（`--timestamp=none`，而公证**要求**它）= **既不能公证也不能装订**。从发布页（就是应用内更新器链过去的那个页面）下载的人得到的是「无法打开，因为无法验证开发者」。

`dist` 里没有任何东西断言用的是 Developer ID、没有公证步骤、也不记录到底用了哪份身份。而且因为这个选择随钥匙串状态**静默变化**，它同时会踩到 CLAUDE.md 警告过的「按签名身份记录 TCC 授权」问题——发出去的构建可能让用户丢掉辅助功能授权。

**修复要建立的性质**：

> `make dist` 要么用一份显式指定的 Developer ID 身份并带安全时间戳，要么直接失败；无论如何，实际使用的身份要打印到构建输出里。

日常 `make app` / `make run` 用开发证书是完全合理的——**只有 `dist` 这条路需要收紧**。

**应补断言**：这条在 shell 层，`--self-check` 覆盖不到。让 `dist` 自己在打包前校验签名（`codesign -dv` 读回 Authority 并检查是不是 Developer ID）。

---

## 4. 自检与文档的准确性问题

这一节是**根因**，不是附注。F1–F5 能出厂，是因为文档声明了一张代码里并不存在的安全网。

### 4.1 CLAUDE.md 里有两句是假的

两句都是 2026-08-30 那次会话里写进去的（作者：Claude），需要改。

**第 83 行** 声称：

> `Settings.swift`（`Preferences` / `MouseAction` / `KeyCombo`，全部手写 `init(from:)`）

`KeyCombo` 和 `MouseAction` 都没有。见 F3。修文档的同时也要修代码——不要只把这句话改成描述现状，因为约束 11 要求的就是它原本声称的那件事。

**第 166 行** 声称：

> **上面每条硬性约束都对应一条断言——修 bug 之后要补一条，别让同一个 bug 回来第二次。**

实际覆盖情况：

| 约束 | 内容 | 断言 |
|---|---|---|
| 1 | tap 挂 `.cgAnnotatedSessionEventTap` | 有 |
| 2 | 投不出去就不要吞 | 有 |
| 3 | 窗口管理快捷键带 `maskSecondaryFn` | 有 |
| 4 | 读 `com.apple.symbolichotkeys` | 有 |
| 5 | 不硬编码字符键码 | 有，但**同义反复**（见 4.2） |
| 6 | 合成事件打魔数 | **无** |
| 7 | 合成滚动设 `IsContinuous = 1` | **无** |
| 8 | 反向翻三个字段 | **无** |
| 9 | 帧源不用 `NSScreen.main` | **无** |
| 10 | 处理 `tapDisabledByTimeout` | **无** |
| 11 | 手写 `init(from:)` | 部分（只覆盖 `Preferences` 层） |
| 12 | 动作不在 tap 回调里同步执行 | **无** |
| 13 | 不在 tap 回调里查最前应用 | 有 |
| 14 | 不用键盘 tap 探测键码 | **无**（这条本质上无法断言，是流程约束——文档应当把它标出来） |

七条零覆盖。约束 8 零覆盖 → F4；约束 5 只有同义反复的覆盖 → F2；约束 11 部分覆盖 → F3。**对应关系非常直接。**

### 4.2 两条现有断言是同义反复的

比「没有断言」更糟——它们让人以为已经被覆盖了。

**`hasFallbackForEveryCharacter`（`SelfCheck.swift:818`）** 钉的是 `ansiFallback` 里**已经有的那 9 个字符**。它在任何情况下都会通过，包括 `ActionRunner` 用到 24 个字符而表里只有 9 个的当下。它验证的是「这张表等于它自己」。

> 应改成：从 `ActionRunner.stroke(for:)` 反向枚举 `.character(_, _)` 实际用到的全部字符，逐个断言能解析出有效键码。**这条改完会立刻失败**——这正是它该做的事。

**`noTwoActionsSendTheSameKeys`（`SelfCheck.swift:858`）** 用 `"\(stroke)"` 给 stroke 签名，也就是在**布局解析之前**。所以它看不见 `viewAsIcons` / `viewAsList` / `viewAsColumns` / `viewAsGallery` 在缺失兜底时全部塌到同一个 `⌘ + 键码0` 上。

> 应改成：在解析出键码**之后**签名，即把 `.character` 先过 `KeyboardLayout.keyCode(for:)` 再比较。

### 4.3 另外三处调用点已经漂移，目前只是潜伏

和 F2 / F4 同一种成因（每个调用点各自遵守约束），但当前还没有造成可见后果。**修 F2 / F4 时一起处理**，否则它们就是下一批 F。

| 位置 | 约束 | 现状 | 为什么现在没事 |
|---|---|---|---|
| `Core/ActionRunner.swift:318`（`auxKeyStroke`） | 6（打魔数） | 媒体键事件**不打**魔数就投出去 | `.systemDefined` 不在事件掩码里，所以回调看不到它。掩码一旦扩大就会自反馈 |
| `UI/ShortcutRecorderView.swift:40` | 3（`maskSecondaryFn`） | 录入时把 `maskSecondaryFn` 掩掉了 | 录入的 Fn 组合会被 WindowServer 静默忽略——**这条其实已经在造成后果**，只是没人报 |
| `UI/KeyCodeNames.swift:7` | 5（不硬编码键码） | 标签路径里硬编码了一张 ANSI 键码→字符表 | 只影响界面显示的文字，不影响投出去的键。但在非 ANSI 布局上标签是错的 |

正确的 `KeyboardLayout.character(for:)` 存在，但目前**只有 `SelfCheck` 在调用它**。

---

## 5. 候选项（未逐条走完验证）

这些是被条数上限砍掉的。**C1–C4 我事后单独核实过，是真的**；C5–C9 只有扫描阶段的结论，动手前请自行确认。

### C1 —— `AppActivationPolicy` 引用计数泄漏（已核实）

`App/SettingsWindowController.swift:53` 的 `showWindow` **无条件**调 `AppActivationPolicy.enter()`（`count += 1`），而 `windowWillClose`（`:71`）只调一次 `leave()`。窗口已经开着时再点一次菜单栏「设置…」→ `count` 变 2，关闭只减到 1，`guard count == 0` 不成立 → **`.accessory` 永远不恢复**。一个菜单栏工具从此永久占着 Dock 图标，直到重启。

修复性质：`enter()` 只在实际发生 `.accessory → .regular` 转换时计数，或者干脆改成「窗口是否可见」的幂等查询而不是引用计数。

### C2 —— `SettingsView.swift:43` 硬编码版本号兜底（已核实）

```swift
static let short: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
```

CLAUDE.md 写明版本号的**唯一来源**是 `Info.plist`。这个兜底违背了它：读不到时应当显示「未知」而不是撒一个会随时间变得越来越假的谎（它会在 0.2.0 上显示 0.1.0）。

### C3 —— 跨线程变量没走 `Locked` 约定（已核实）

`Core/ScrollEngine.swift:105` 的 `private var ticker: DisplayLinkTicker?`：被 `startTicker()` / `stopTicker()`（主线程）和 `frameSource`（诊断读取）访问，无同步。

`Core/DisplayLinkTicker.swift:21` 的 `private var thread: Thread?`：类里有 `lock`，但 `thread` 的赋值（`start()` 里 `self.thread = thread`）和读取（`stop()` 里 `thread?.cancel()`）都在锁**外**。

CLAUDE.md 的约定是「跨线程共享状态统一走 `Locked`」。这两处是例外，而 F1 正好发生在这一带——修 F1 时会同时碰到它们。

### C4 —— `SystemHotkeys.swift:143` 无检查窄化转换（已核实）

```swift
return .stroke(Stroke(keyCode: UInt16(keyCode), flags: CGEventFlags(rawValue: UInt64(modifiers))))
```

`keyCode` / `modifiers` 来自 `com.apple.symbolichotkeys` —— 一个**用户可写**的 plist。`65535` 哨兵被 `:141` 的 guard 挡住了，但越界值（负数、大于 65535）会让 `UInt16(...)` **直接 trap**，进程崩溃。用 `UInt16(exactly:)` 并在失败时降级成 `.disabledBySystem`。

### C5–C9 —— 仅扫描阶段结论，动手前请确认

| # | 位置 | 扫描结论 |
|---|---|---|
| C5 | `Core/UpdateChecker.swift:80` | 仅在空闲时超时 + `isChecking` 守卫，可能把整个进程的更新检查卡死 |
| C6 | `Core/MouseEngine.swift:116` | 每次偏好变更都销毁并重建 tap（拖滑块时约 60 次/秒），期间有事件绕过 App 的窗口；`.failed` 是终态且无重试 |
| C7 | `Model/SettingsStore.swift:87` | 去抖保存在 tap 所在的 run loop 上**同步**编码并写盘 |
| C8 | `App/StatusItemController.swift:22` / `:159` | 状态变化时不调 `refreshIcon()`；已存在 `.custom` 规则时「停用当前应用」菜单项静默无效 |
| C9 | `UI/AppRulesPane.swift:76` | 自定义规则只暴露了 10 个滚动字段中的 5 个 |

**整理类（非缺陷）**：界面文案有散落在 `Strings.swift` 之外的；Status→标签的 switch 重复了两处且颜色已经不一致；`ConflictMonitor` 每次应用切换都做一遍全量进程扫描；tap 回调里有每事件分配（`Array(gestureSessions.keys)`、`"\(action)"` 插值）。

---

## 6. 建议的修复顺序

分批做，每批之后 `make test` 必须全过。

**第 1 批 —— 止血（P0）**
F1 + `cancel()` 漏重置 `running`、F5。顺带 C3（就在同一片代码里）。
这批之后滚轮不会再进入不可恢复状态。

**第 2 批 —— 数据丢失陷阱（P1）**
F3。它现在是已装填状态，下一个碰 `KeyCombo` / `MouseAction` 的人就会触发，越早越好。

**第 3 批 —— 已破的约束（P1）**
F4（连注释一起改）、F2（含 `:70` 的失败缓存）。同时处理 §4.3 那三处潜伏漂移，以及 §4.2 两条同义反复的断言——**改完那两条断言会立刻失败，那是正确的**，让它们指出真实缺口。

**第 4 批 —— 事件路由与生命周期（P2）**
F7、F9、F10、F11。这四条互相有关联（都围绕 tap 生命周期与手势会话），一起改比分开改省事。

**第 5 批 —— 其余（P2）**
F8、F6、F12、F14、F13、F15，以及 C1、C2、C4。

**贯穿全程**：每修一条补一条断言（§4.1 表里那七条零覆盖的约束是优先项），并同步修正 CLAUDE.md 第 83 行和第 166 行——**不要只是把话改软，要让代码真的成立**。

### 第 1 批修完之后的遗留

三条都不阻塞后续批次，但第 3 批收口时值得一起处理：

1. **`DisplayLinkTicker.start()` 永远返回 `true`**（两条路径都成功返回）。`ScrollAnimator.enqueue` 里 `guard ticker.start() else { ... }` 那条回滚分支在生产代码里因此是死路，只有自检的 fake ticker 走得到。不是错，但别当成已验证的路径。
2. **「必须先 `stop()` 再把 `ticker` 置 nil」这条新约束靠调用点自觉。** 帧源线程闭包持有 ticker 的**强引用**，`isRunning` 为 true 时 run loop 不退出 → `deinit` 永远不跑 → `stop()` 永远不会被调用 → ticker 与线程永久泄漏。目前 `cancel()` 和 finish 提交两处都对，但这正是 §4.3 的模式：加第三个调用点就会重新踩。把「stop + 置 nil」收成一个方法，让漏掉写不出来。
3. **`ScrollAxis.add` 溢出时把累积距离清成 0，而 `enqueue` 仍返回 `true`** —— 路由层已经吞掉了那一格，严格说违反约束 2。需要 `remaining` 到 1e308 量级才可能，实际不可达，记一笔即可。

真实帧源目前只有生命周期一致性被钉住（`realTickerLifecycleIsCoherent`）。**刻意没有断言「帧真的会来」**：那要依赖有显示器、依赖 run loop 被及时调度，一条会在 SSH 上变红的断言比没有这条更糟。同理约束 9（帧源选哪块屏幕）仍然没有覆盖。

