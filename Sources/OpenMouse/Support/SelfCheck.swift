import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Self-contained assertion checks for the pure logic in this app: the easing curve, the
/// per-app rule resolution, the button bindings and preferences hygiene.
///
/// These live in the app target rather than a test target on purpose. XCTest and
/// swift-testing ship with Xcode, not with the Command Line Tools, so a normal test target
/// cannot even be compiled on a machine that only has the CLT installed. Running them as
/// `OpenMouse --self-check` means they work on every machine that can build the app, and
/// doubles as a diagnostic for a shipped build.
enum SelfCheck {
    private static var failures: [String] = []
    private static var checks = 0
    private static var currentGroup = ""

    static func run() -> Bool {
        failures = []
        checks = 0

        group("滚动缓动曲线") {
            conservesDistance()
            alwaysTerminates()
            stepsShrink()
            instantAtZeroSmoothness()
            reversalDropsMomentum()
            sameDirectionAccumulates()
            rateIsBounded()
            rejectsNonFiniteTravel()
        }
        group("滚动帧源生命周期") {
            finishRaceKeepsTickerAlive()
            cancelStopsTickerAndAllowsRestart()
            lifecycleSnapshotsStayCoherent()
            animatorRejectsNonFiniteInput()
            realTickerLifecycleIsCoherent()
        }
        group("应用规则") {
            globalFallback()
            bypassRule()
            customRule()
            masterSwitchWins()
        }
        group("按键映射") {
            defaultAction()
            modifierVariant()
            inactiveDetection()
            motionMaskCoversPlainMovement()
        }
        group("手势导航") {
            commitsDominantAxis()
            ignoresDiagonalDrift()
            firesOncePerHold()
            treatsStillHoldAsClick()
            mapsDirectionsLikeLogiOptions()
            measuresFromLocationWhenDeltasAreEmpty()
            prefersDeltaFieldsWhenPresent()
        }
        group("动作选择器") {
            actionKindRoundTrip()
            preservesShortcutPayload()
            groupsAreComplete()
        }
        group("冲突检测") {
            detectsDebugBuilds()
            deduplicatesPerProduct()
            ignoresUnrelatedApps()
        }
        group("偏好设置") {
            clampsOutOfRange()
            startsWithNoButtons()
            migratesEnumeratedButtons()
            sortsBindings()
            toleratesBrokenSections()
            preservesBindingsAcrossSchemaChanges()
            survivesJSONRoundTrip()
        }
        group("Mos 手感对齐") {
            matchesMosFeel()
            travelFloorsThenScales()
            filterRemovesLeadingJump()
            filterConvergesAndDrains()
        }
        group("动作实现完整性") {
            everyActionHasAStroke()
            noTwoActionsSendTheSameKeys()
        }
        group("键盘布局") {
            resolvesCharactersOnLiveLayout()
            hasFallbackForEveryCharacter()
            failedLayoutBuildIsRetried()
            shortcutLabelsFollowLiveLayout()
        }
        group("桌面切换节流") {
            queuesRapidSwitches()
            reversalDiscardsBacklog()
            capsTheQueue()
        }
        group("事件投递") {
            tapsWhereTargetIsAnnotated()
            refusesUndeliverableTarget()
            reversesAllScrollFields()
            auxiliaryEventsCarrySyntheticTag()
        }
        group("系统快捷键") {
            windowManagementStrokesCarryFn()
        }
        group("更新检查") {
            hasDefaultUpdateSource()
            comparesVersions()
            parsesRelease()
            rejectsBadPayload()
        }

        print("")
        if failures.isEmpty {
            print("✓ \(checks) 项检查全部通过")
            return true
        }
        print("✗ \(failures.count)/\(checks) 项检查失败:")
        for failure in failures {
            print("  · \(failure)")
        }
        return false
    }

    // MARK: Harness

    private static func group(_ name: String, _ body: () -> Void) {
        currentGroup = name
        print("── \(name)")
        body()
    }

    private static func expect(
        _ condition: Bool,
        _ description: String,
        line: UInt = #line
    ) {
        checks += 1
        if condition {
            print("   ✓ \(description)")
        } else {
            print("   ✗ \(description)  (\(currentGroup):\(line))")
            failures.append("\(currentGroup) / \(description)")
        }
    }

    private static func expectClose(
        _ lhs: Double,
        _ rhs: Double,
        _ description: String,
        tolerance: Double = 0.001,
        line: UInt = #line
    ) {
        // Only spell out the numbers when they disagree; a passing check should read as a
        // sentence, not as arithmetic.
        if abs(lhs - rhs) < tolerance {
            expect(true, description, line: line)
        } else {
            expect(false, "\(description)（得到 \(lhs)，期望 \(rhs)）", line: line)
        }
    }

    /// Deterministic frame source for lifecycle checks. Its state uses the same `Locked`
    /// convention as production so a check can inspect it without introducing a test-only race.
    private final class ProbeTicker: ScrollFrameTicker {
        private struct ProbeState {
            var running = false
            var starts = 0
            var stops = 0
        }

        private let onTick: () -> Void
        private let state = Locked(ProbeState())

        init(onTick: @escaping () -> Void) {
            self.onTick = onTick
        }

        var activeSource: DisplayLinkTicker.Source {
            state.withValue { $0.running ? .timer : .idle }
        }

        var isRunning: Bool {
            state.withValue { $0.running }
        }

        var startCount: Int {
            state.withValue { $0.starts }
        }

        var stopCount: Int {
            state.withValue { $0.stops }
        }

        @discardableResult
        func start() -> Bool {
            state.withValue { state in
                state.running = true
                state.starts += 1
            }
            return true
        }

        func stop() {
            state.withValue { state in
                state.running = false
                state.stops += 1
            }
        }

        func fire() {
            guard isRunning else { return }
            onTick()
        }
    }

    // MARK: Easing

    private static func conservesDistance() {
        var axis = ScrollAxis()
        axis.add(100)
        var total = 0.0
        var frames = 0
        while !axis.isIdle, frames < 1_000 {
            total += axis.advance(rate: 0.45)
            frames += 1
        }
        expect(axis.isIdle, "缓动会结束")
        expectClose(total, 100, "排队的距离被完整送达，不多也不少")
    }

    private static func alwaysTerminates() {
        var worstFrames = 0
        var settled = true
        for smoothness in stride(from: 0.0, through: 0.95, by: 0.05) {
            var axis = ScrollAxis()
            axis.add(480)
            let rate = ScrollAxis.rate(forSmoothness: smoothness)
            var frames = 0
            while !axis.isIdle, frames < 500 {
                _ = axis.advance(rate: rate)
                frames += 1
            }
            worstFrames = max(worstFrames, frames)
            if !axis.isIdle { settled = false }
        }
        expect(settled, "任意平滑度下都会收敛（最长 \(worstFrames) 帧）")
    }

    private static func stepsShrink() {
        var axis = ScrollAxis()
        axis.add(600)
        let first = axis.advance(rate: 0.4)
        let second = axis.advance(rate: 0.4)
        let third = axis.advance(rate: 0.4)
        expect(first > second && second > third, "每帧步长递减，读起来像惯性")
    }

    private static func instantAtZeroSmoothness() {
        var axis = ScrollAxis()
        axis.add(90)
        let step = axis.advance(rate: ScrollAxis.rate(forSmoothness: 0))
        expect(step == 90 && axis.isIdle, "平滑度为 0 时第一帧就送完")
    }

    private static func reversalDropsMomentum() {
        var axis = ScrollAxis()
        axis.add(200)
        _ = axis.advance(rate: 0.3)
        axis.add(-50)
        var total = 0.0
        while !axis.isIdle {
            total += axis.advance(rate: 0.3)
        }
        expectClose(total, -50, "反向滚动会丢掉残余惯性而不是与之对抗")
    }

    private static func sameDirectionAccumulates() {
        var axis = ScrollAxis()
        axis.add(100)
        var total = axis.advance(rate: 0.5)
        axis.add(100)
        while !axis.isIdle {
            total += axis.advance(rate: 0.5)
        }
        expectClose(total, 200, "同向连续滚动会累加")
    }

    private static func rateIsBounded() {
        expect(ScrollAxis.rate(forSmoothness: -5) == 1.0, "平滑度下界被裁剪")
        // Binary floating point makes 1 - maxSmoothness inexact, so compare with slack.
        expectClose(
            ScrollAxis.rate(forSmoothness: 5),
            1 - ScrollSettings.maxSmoothness,
            "平滑度上界被裁剪"
        )
        expect(ScrollAxis.rate(forSmoothness: 0.5) == 0.5, "平滑度线性映射到每帧比例")
    }

    private static func rejectsNonFiniteTravel() {
        var axis = ScrollAxis()
        axis.add(.infinity)
        axis.add(.nan)
        for _ in 0..<4 { _ = axis.advance(rate: 0.5) }
        expect(axis.isIdle, "NaN/Inf 不会污染缓动累加器，动画仍能终止")

        let settings = ScrollSettings.default
        expect(
            settings.travel(forRawDelta: .infinity) == 0
                && settings.travel(forRawDelta: -.infinity) == 0
                && settings.travel(forRawDelta: .nan) == 0,
            "NaN/Inf 在行程换算入口被丢弃，不会生成非有限位移"
        )
    }

    // MARK: Frame-source lifecycle

    /// Reproduces F1's exact ordering: a finish is prepared, a new notch arrives before the
    /// conditional stop, and the old finish must not tear down the source carrying that notch.
    private static func finishRaceKeepsTickerAlive() {
        let tickers = Locked<[ProbeTicker]>([])
        var injectedNewInput = false
        var animator: ScrollAnimator!
        var settings = ScrollSettings.default
        settings.smoothness = 0

        animator = ScrollAnimator(
            stats: Locked(EngineStats()),
            tickerFactory: { onTick in
                let ticker = ProbeTicker(onTick: onTick)
                tickers.withValue { $0.append(ticker) }
                return ticker
            },
            beforeFinishCommit: {
                guard !injectedNewInput else { return }
                injectedNewInput = true
                _ = animator.enqueue(
                    vertical: 0.5,
                    horizontal: 0,
                    settings: settings,
                    target: nil
                )
            }
        )

        let accepted = animator.enqueue(
            vertical: 0.5,
            horizontal: 0,
            settings: settings,
            target: nil
        )
        guard let ticker = tickers.value.first else {
            expect(false, "结束帧与新输入交错时仍有活着的帧源")
            return
        }

        var frames = 0
        while !injectedNewInput, frames < 500 {
            ticker.fire()
            frames += 1
        }

        expect(
            accepted && injectedNewInput
                && tickers.value.count == 1
                && animator.isRunning
                && animator.hasLiveFrameSource
                && ticker.isRunning,
            "结束帧与新输入交错时复用活帧源，不会被旧 finish 闩死"
        )
        animator.cancel()
    }

    private static func cancelStopsTickerAndAllowsRestart() {
        let tickers = Locked<[ProbeTicker]>([])
        let animator = ScrollAnimator(
            stats: Locked(EngineStats()),
            tickerFactory: { onTick in
                let ticker = ProbeTicker(onTick: onTick)
                tickers.withValue { $0.append(ticker) }
                return ticker
            }
        )

        let firstAccepted = animator.enqueue(
            vertical: 0.5,
            horizontal: 0,
            settings: .default,
            target: nil
        )
        let first = tickers.value.first
        animator.cancel()
        let cancelled = !animator.isRunning
            && !animator.hasLiveFrameSource
            && animator.frameSource == .idle
            && first?.stopCount == 1

        let secondAccepted = animator.enqueue(
            vertical: 0.5,
            horizontal: 0,
            settings: .default,
            target: nil
        )
        let restarted = tickers.value.count == 2
            && tickers.value.last?.isRunning == true
            && animator.isRunning
            && animator.hasLiveFrameSource

        expect(
            firstAccepted && cancelled && secondAccepted && restarted,
            "cancel 会清掉运行态并拆除帧源，下一格滚动能重新启动"
        )
        animator.cancel()
    }

    private static func lifecycleSnapshotsStayCoherent() {
        let tickers = Locked<[ProbeTicker]>([])
        let animator = ScrollAnimator(
            stats: Locked(EngineStats()),
            tickerFactory: { onTick in
                let ticker = ProbeTicker(onTick: onTick)
                tickers.withValue { $0.append(ticker) }
                return ticker
            }
        )

        let idle = !animator.isRunning
            && !animator.hasLiveFrameSource
            && animator.frameSource == .idle
        _ = animator.enqueue(vertical: 0.5, horizontal: 0, settings: .default, target: nil)
        let running = animator.isRunning
            && animator.hasLiveFrameSource
            && animator.frameSource == .timer
        animator.cancel()
        let stopped = !animator.isRunning
            && !animator.hasLiveFrameSource
            && animator.frameSource == .idle

        expect(
            idle && running && stopped,
            "运行标记、ticker 句柄与诊断帧源始终给出同一份生命周期事实"
        )
    }

    private static func animatorRejectsNonFiniteInput() {
        let tickers = Locked<[ProbeTicker]>([])
        let animator = ScrollAnimator(
            stats: Locked(EngineStats()),
            tickerFactory: { onTick in
                let ticker = ProbeTicker(onTick: onTick)
                tickers.withValue { $0.append(ticker) }
                return ticker
            }
        )

        let acceptedNaN = animator.enqueue(
            vertical: .nan,
            horizontal: 0,
            settings: .default,
            target: nil
        )
        let acceptedInfinity = animator.enqueue(
            vertical: 0,
            horizontal: .infinity,
            settings: .default,
            target: nil
        )
        var malformedSettings = ScrollSettings.default
        malformedSettings.smoothness = .nan
        let acceptedNaNRate = animator.enqueue(
            vertical: 1,
            horizontal: 0,
            settings: malformedSettings,
            target: nil
        )
        expect(
            !acceptedNaN && !acceptedInfinity && !acceptedNaNRate
                && tickers.value.isEmpty
                && !animator.isRunning
                && !animator.hasLiveFrameSource,
            "动画入口拒绝非有限位移且不启动帧源，调用方可安全放行原事件"
        )
    }

    /// The four checks above all inject `ProbeTicker`, so none of them execute a single line of
    /// `DisplayLinkTicker` — the file whose state was just consolidated into one lock. This one
    /// drives the production frame source directly.
    ///
    /// Deliberately not asserted here: that frames actually arrive. Waiting on a real vsync
    /// callback would make the suite depend on there being a display and on how promptly its
    /// run loop is serviced, and a check that goes red over SSH is worse than no check.
    /// What is asserted is the invariant the consolidation exists for — `isRunning` and
    /// `activeSource` can never disagree about whether a source is live.
    private static func realTickerLifecycleIsCoherent() {
        let ticker = DisplayLinkTicker {}

        let idle = !ticker.isRunning && ticker.activeSource == .idle

        // Either source counts as started. A headless session has no screen and degrades to the
        // timer by design, so pinning `.displayLink` would fail for the documented fallback.
        let started = ticker.start()
        let running = ticker.isRunning && ticker.activeSource != .idle
        // Named in the output on purpose. Which source this machine can actually get is the same
        // fact `--verbose` surfaces: a diagnostic run that says `timer` explains "smoothing feels
        // worse than Mos" on the spot, and it also tells you whether this check reached
        // `screen.displayLink` at all or only the fallback.
        let observed = ticker.activeSource

        // Starting twice must not leave a second link/timer behind with no handle to stop it.
        let restarted = ticker.start()
        let stillRunning = ticker.isRunning && ticker.activeSource != .idle

        ticker.stop()
        let stopped = !ticker.isRunning && ticker.activeSource == .idle
        // Stopping twice is reachable: `cancel()` and a finish commit can both land on the same
        // source, and `deinit` stops again after that.
        ticker.stop()
        let stillStopped = !ticker.isRunning && ticker.activeSource == .idle

        // The property F1 was about, one layer down: a stopped source must be startable again,
        // or the first glide would be the last one.
        let startedAgain = ticker.start()
        let runningAgain = ticker.isRunning && ticker.activeSource != .idle
        ticker.stop()

        expect(
            idle && started && running && restarted && stillRunning
                && stopped && stillStopped && startedAgain && runningAgain,
            "真实帧源的运行标记与诊断来源始终一致，且停掉之后能重新启动（本机取到 \(observed.rawValue)）"
        )
    }

    // MARK: Rules

    private static func globalFallback() {
        var prefs = Preferences()
        prefs.scroll.speed = 7.7
        let config = ResolvedConfig(preferences: prefs, frontmostBundleID: "com.apple.Safari")
        expect(config.active && config.scroll.speed == 7.7 && config.buttonsActive, "没有规则时使用全局设置")
    }

    private static func bypassRule() {
        var prefs = Preferences()
        prefs.rules = [AppRule(bundleID: "com.apple.Terminal", name: "Terminal", mode: .bypass)]
        let config = ResolvedConfig(preferences: prefs, frontmostBundleID: "com.apple.Terminal")
        expect(!config.active && !config.buttonsActive, "bypass 规则会完全放行该应用")
    }

    private static func customRule() {
        var prefs = Preferences()
        prefs.scroll.minimumStep = 40
        var rule = AppRule(bundleID: "com.figma.Desktop", name: "Figma", mode: .custom)
        rule.scroll.minimumStep = 120
        rule.bypassButtons = true
        prefs.rules = [rule]

        let matched = ResolvedConfig(preferences: prefs, frontmostBundleID: "com.figma.Desktop")
        let other = ResolvedConfig(preferences: prefs, frontmostBundleID: "com.apple.Safari")
        expect(matched.scroll.minimumStep == 120 && !matched.buttonsActive, "自定义规则只作用于匹配的应用")
        expect(other.scroll.minimumStep == 40 && other.buttonsActive, "其他应用不受影响")
    }

    private static func masterSwitchWins() {
        var prefs = Preferences()
        prefs.enabled = false
        expect(!ResolvedConfig(preferences: prefs, frontmostBundleID: nil).active, "总开关优先于所有规则")
    }

    // MARK: Buttons

    private static func defaultAction() {
        let bindings = [ButtonBinding(button: 3, action: .navigateBack)]
        expect(
            bindings.resolve(button: 3, modifiers: 0)?.action == .navigateBack,
            "未按修饰键时命中无修饰键的映射"
        )
        expect(bindings.resolve(button: 4, modifiers: 0) == nil, "没有录入的按键不会被接管")
    }

    private static func modifierVariant() {
        let command = CGEventFlags.maskCommand.rawValue
        let bindings = [
            ButtonBinding(button: 3, modifiers: 0, action: .navigateBack),
            ButtonBinding(button: 3, modifiers: command, action: .missionControl)
        ]
        expect(
            bindings.resolve(button: 3, modifiers: command)?.action == .missionControl,
            "修饰键组合精确命中"
        )
        expect(
            bindings.resolve(button: 3, modifiers: 0)?.action == .navigateBack,
            "无修饰键时命中无修饰键的那条"
        )
        expect(
            bindings.resolve(button: 3, modifiers: CGEventFlags.maskShift.rawValue)?.action == .navigateBack,
            "未配置的修饰键回落到无修饰键的那条，而不是误命中别的组合"
        )
    }

    private static func inactiveDetection() {
        expect(!ButtonBinding(button: 2).isActive, "动作为「保持原样」的映射视为未启用")
        expect(ButtonBinding(button: 2, action: .mute).isActive, "有动作的映射视为启用")
        expect(![ButtonBinding(button: 2)].hasActiveBinding, "没有生效映射时事件掩码不订阅按键")
        expect([ButtonBinding(button: 2, action: .mute)].hasActiveBinding, "有生效映射时订阅按键")
        expect(
            [ButtonBinding(button: 2)].resolve(button: 2, modifiers: 0) == nil,
            "未启用的映射不会被解析出来"
        )
    }

    /// The gesture feature is driven by pointer movement that arrives as `.mouseMoved`,
    /// because the button-down is swallowed and the system therefore never starts a drag.
    /// Leaving that type out of the mask is what made the feature silently do nothing.
    private static func motionMaskCoversPlainMovement() {
        let mask = MouseEngine.motionMask
        expect(
            mask & (1 << CGEventType.mouseMoved.rawValue) != 0,
            "手势的移动掩码包含 .mouseMoved（吞掉按下后系统不进入拖拽，移动只会以此类型送出）"
        )
        expect(
            mask & (1 << CGEventType.otherMouseDragged.rawValue) != 0,
            "手势的移动掩码同时包含 .otherMouseDragged"
        )
    }

    // MARK: Gesture navigation

    /// Real mice were observed delivering `.otherMouseDragged` with both delta fields at
    /// zero, so a recognizer that only accumulated deltas measured no movement at all and
    /// ended every gesture as "never moved". The location has to be able to carry it.
    private static func measuresFromLocationWhenDeltasAreEmpty() {
        var recognizer = MouseGestureRecognizer()
        recognizer.begin(at: CGPoint(x: 500, y: 500))
        var fired: MouseGestureDirection?
        for step in 1...8 {
            let point = CGPoint(x: 500, y: 500 - Double(step) * 10)
            if let direction = recognizer.append(location: point, fieldDeltaX: 0, fieldDeltaY: 0) {
                fired = fired ?? direction
            }
        }
        expect(fired == .up, "位移字段为 0 时改用事件坐标测量，仍能识别方向")
        expectClose(recognizer.maximumDistanceFromOrigin, 80, "累积位移取自坐标差")
        expect(!recognizer.shouldTreatAsClick, "有真实移动时不会被误判成原地单击")
    }

    /// The delta fields keep counting when the pointer is clamped at a screen edge, where the
    /// location stops changing — so when they carry something, they win.
    private static func prefersDeltaFieldsWhenPresent() {
        var recognizer = MouseGestureRecognizer()
        let edge = CGPoint(x: 1919, y: 500)
        recognizer.begin(at: edge)
        var fired: MouseGestureDirection?
        for _ in 1...6 {
            if let direction = recognizer.append(location: edge, fieldDeltaX: 12, fieldDeltaY: 0) {
                fired = fired ?? direction
            }
        }
        expect(fired == .right, "指针被屏幕边缘卡住、坐标不再变化时，改用位移字段")
    }

    private static func commitsDominantAxis() {
        var up = MouseGestureRecognizer()
        // CGEvent delta Y is positive downward, so negative travel is "up".
        expect(up.append(deltaX: 0, deltaY: -50) == .up, "向上划识别为 up")

        var down = MouseGestureRecognizer()
        expect(down.append(deltaX: 0, deltaY: 50) == .down, "向下划识别为 down")

        var left = MouseGestureRecognizer()
        expect(left.append(deltaX: -50, deltaY: 0) == .left, "向左划识别为 left")

        var right = MouseGestureRecognizer()
        expect(right.append(deltaX: 50, deltaY: 0) == .right, "向右划识别为 right")
    }

    private static func ignoresDiagonalDrift() {
        var recognizer = MouseGestureRecognizer()
        // Past the activation distance but with neither axis dominant: hold off deciding.
        expect(recognizer.append(deltaX: 45, deltaY: 44) == nil, "太斜的移动不会替用户猜方向")
        // Committing further along one axis then resolves it.
        expect(recognizer.append(deltaX: 40, deltaY: 0) == .right, "继续沿一个轴移动后才判定")
    }

    private static func firesOncePerHold() {
        var recognizer = MouseGestureRecognizer()
        expect(recognizer.append(deltaX: -50, deltaY: 0) == .left, "第一次越过阈值触发")
        var extra = 0
        for _ in 0..<20 where recognizer.append(deltaX: -50, deltaY: 0) != nil {
            extra += 1
        }
        expect(extra == 0, "一次按住只触发一个动作，长距离划动不会连跳好几个桌面")
    }

    private static func treatsStillHoldAsClick() {
        var still = MouseGestureRecognizer()
        _ = still.append(deltaX: 2, deltaY: -3)
        expect(still.shouldTreatAsClick, "几乎没动的按住算作单击")

        var moved = MouseGestureRecognizer()
        _ = moved.append(deltaX: 0, deltaY: -50)
        expect(!moved.shouldTreatAsClick, "已经识别出方向就不再算单击")

        var wandered = MouseGestureRecognizer()
        _ = wandered.append(deltaX: 25, deltaY: 0)
        expect(!wandered.shouldTreatAsClick, "移动超过容差但没到阈值，也不算单击")
    }

    private static func mapsDirectionsLikeLogiOptions() {
        expect(MouseGestureDirection.up.action == .missionControl, "上 = 调度中心")
        expect(MouseGestureDirection.down.action == .applicationWindows, "下 = 应用程序窗口")
        // Inverted on purpose: shoving the mouse left pushes the desktop aside, which is the
        // same direction sense as a trackpad swipe.
        expect(MouseGestureDirection.left.action == .spaceRight, "左划 = 切到右边的桌面（与触控板同向）")
        expect(MouseGestureDirection.right.action == .spaceLeft, "右划 = 切到左边的桌面")
    }

    // MARK: Action kinds

    private static func actionKindRoundTrip() {
        var allMatched = true
        for kind in ActionKind.allCases where ActionKind(kind.makeAction(preserving: .passthrough)) != kind {
            allMatched = false
        }
        expect(allMatched, "每个动作类型都能与 MouseAction 双向转换")
    }

    private static func preservesShortcutPayload() {
        let combo = KeyCombo(keyCode: 48, modifiers: CGEventFlags.maskCommand.rawValue)
        let original = MouseAction.keyStroke(combo)
        expect(
            ActionKind.keyStroke.makeAction(preserving: original) == original,
            "切换动作后再切回来不会丢掉已录制的快捷键"
        )
    }

    private static func groupsAreComplete() {
        // The picker renders `ungrouped` at the top level and `groups` as submenus. Anything
        // missing from both is an action the user simply cannot select.
        let listed = ActionKind.ungrouped + ActionKind.groups.flatMap(\.1)
        expect(Set(listed) == Set(ActionKind.allCases), "选择器覆盖了所有动作，没有选不到的")
        expect(listed.count == ActionKind.allCases.count, "没有动作出现在两个位置")
        expect(
            ActionKind.groups.allSatisfy { !$0.1.isEmpty },
            "没有空的子菜单"
        )
        expect(
            ActionKind.groups.contains { $0.0 == "窗口与桌面" && $0.1.contains(.gestureNavigation) },
            "手势导航归入「窗口与桌面」"
        )
    }

    // MARK: Conflict detection

    private static func detectsDebugBuilds() {
        let found = ConflictMonitor.conflicts(among: [
            ("com.caldis.Mos.debug", "Mos Debug")
        ])
        expect(found.count == 1 && found[0].id == "Mos", "调试版（com.caldis.Mos.debug）也能被识别为 Mos")
        expect(found.first?.name == "Mos Debug", "提示里用应用自己的显示名，而不是产品名")
    }

    private static func deduplicatesPerProduct() {
        let found = ConflictMonitor.conflicts(among: [
            ("com.caldis.Mos", "Mos"),
            ("com.caldis.Mos.debug", "Mos Debug"),
            ("com.lujjjh.LinearMouse", "LinearMouse")
        ])
        expect(found.count == 2, "同一产品的多个版本只提示一次")
        expect(found.map(\.id).sorted() == ["LinearMouse", "Mos"], "不同产品分别提示")
    }

    private static func ignoresUnrelatedApps() {
        let found = ConflictMonitor.conflicts(among: [
            ("com.apple.Safari", "Safari"),
            ("com.apple.dt.Xcode", "Xcode"),
            ("com.mosaic.something", "Mosaic")
        ])
        expect(found.isEmpty, "名字里带 mos 的无关应用不会误报")
    }

    // MARK: Preferences

    private static func clampsOutOfRange() {
        var prefs = Preferences()
        prefs.scroll.minimumStep = 10_000
        prefs.scroll.smoothness = 4
        prefs.scroll.acceleration = -3
        prefs.normalize()
        expect(
            prefs.scroll.minimumStep == 200
                && prefs.scroll.smoothness == ScrollSettings.maxSmoothness
                && prefs.scroll.acceleration == 1,
            "越界的数值在读取时被裁剪"
        )
    }

    private static func startsWithNoButtons() {
        expect(Preferences().buttons.isEmpty, "默认不预设任何按键映射")
    }

    private static func migratesEnumeratedButtons() {
        // What a pre-recording build wrote: every button number listed, all passthrough.
        let json = """
        {
          "buttons": [
            { "button": 2, "action": { "passthrough": {} }, "modifierActions": [] },
            { "button": 3, "action": { "passthrough": {} }, "modifierActions": [] },
            { "button": 4, "action": { "mute": {} }, "modifierActions": [] }
          ]
        }
        """
        guard let data = json.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            expect(false, "旧版按键配置应能被解码")
            return
        }
        decoded.normalize()
        expect(decoded.buttons.count == 1, "旧配置里预设但未使用的按键会被清掉")
        expect(decoded.buttons.first?.button == 4, "有实际动作的映射被保留")
        expect(decoded.buttons.first?.action == .mute, "保留的映射动作不变")
    }

    private static func sortsBindings() {
        var prefs = Preferences()
        let command = CGEventFlags.maskCommand.rawValue
        prefs.buttons = [
            ButtonBinding(button: 4, modifiers: 0, action: .mute),
            ButtonBinding(button: 3, modifiers: command, action: .missionControl),
            ButtonBinding(button: 3, modifiers: 0, action: .navigateBack)
        ]
        prefs.normalize()
        expect(
            prefs.buttons.map(\.button) == [3, 3, 4],
            "映射按按键号排序"
        )
        expect(
            prefs.buttons[0].modifiers == 0 && prefs.buttons[1].modifiers == command,
            "同一按键内，无修饰键的排在前面"
        )
    }

    private static func toleratesBrokenSections() {
        // A settings file outlives any one build; a shape change in one section must not
        // take the rest of the user's configuration with it.
        let json = """
        {
          "enabled": true,
          "scroll": { "minimumStep": 12.5, "smoothness": 0.5 },
          "buttons": [ { "this": "is", "not": "a binding" } ],
          "rules": "not an array"
        }
        """
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            expect(false, "损坏的配置片段不应导致整体解码失败")
            return
        }
        expect(decoded.scroll.minimumStep == 12.5, "一个片段损坏时其他设置仍被保留")
        expect(decoded.buttons.isEmpty, "无法解析的按键映射退回空列表")
        expect(decoded.rules.isEmpty, "类型不对的字段退回默认值")
    }

    /// Reproduces F3's data-loss chain: one future action discriminator, one malformed row,
    /// and a KeyCombo whose schema differs from this build must not erase the valid siblings.
    private static func preservesBindingsAcrossSchemaChanges() {
        let json = """
        {
          "buttons": [
            { "button": 3, "action": { "mute": {} } },
            { "button": 4, "action": { "futureAction": { "payload": 1 } } },
            { "button": "not-a-number", "action": { "missionControl": {} } },
            {
              "button": 5,
              "action": {
                "keyStroke": {
                  "_0": { "keyCode": 8, "futureField": "ignored" }
                }
              }
            },
            { "button": 6, "action": { "missionControl": {} } }
          ]
        }
        """
        guard let data = json.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            expect(false, "动作或快捷键结构变化时偏好仍能解码")
            return
        }

        decoded.normalize()
        expect(
            decoded.buttons.map(\.button) == [3, 5, 6],
            "未知动作和损坏行只跳过自身，其余按键映射全部保留"
        )
        expect(
            decoded.buttons.first(where: { $0.button == 5 })?.action
                == .keyStroke(KeyCombo(keyCode: 8, modifiers: 0)),
            "KeyCombo 忽略未知字段，并让缺失字段逐项回落默认值"
        )
    }

    private static func matchesMosFeel() {
        let defaults = ScrollSettings.default
        expect(defaults.minimumStep == 33.6, "最短步长对齐 Mos 的 33.6")
        expect(defaults.speed == 2.70, "速度增益对齐 Mos 的 2.70")

        // Mos: 1 - sqrt(duration / 5.2), duration default 4.35.
        let mosRate = 1 - (4.35 / 5.2).squareRoot()
        expectClose(
            ScrollAxis.rate(forSmoothness: defaults.smoothness),
            mosRate,
            "每帧插值比例对齐 Mos",
            tolerance: 0.002
        )
        expect(
            ScrollSmoothingFilter.defaultCoefficient == 0.23,
            "二级滤波系数对齐 Mos 的 0.23"
        )
    }

    private static func travelFloorsThenScales() {
        let settings = ScrollSettings.default
        // A slow notch reports a small pixel delta, so the floor decides the distance.
        expectClose(settings.travel(forRawDelta: 10), 33.6 * 2.70, "慢速滚动被抬到最短步长再乘增益")
        expectClose(settings.travel(forRawDelta: -10), -33.6 * 2.70, "方向被保留")
        // A fast notch reports a larger delta, which scales past the floor.
        expectClose(settings.travel(forRawDelta: 90), 90 * 2.70, "快速滚动按系统上报的像素增量放大")
        expect(settings.travel(forRawDelta: 0) == 0, "零增量不产生位移")
    }

    private static func filterRemovesLeadingJump() {
        var filter = ScrollSmoothingFilter()
        let step = 7.65 // one frame of a default-settings notch
        let first = filter.filter(step)
        let second = filter.filter(step)
        let third = filter.filter(step)
        expect(first == 0, "第一帧输出为 0，起始突起被削掉")
        expect(second > 0 && second < step, "输出逐帧爬升而不是一步到位")
        expect(third > second, "持续输入时输出单调上升")
    }

    private static func filterConvergesAndDrains() {
        var filter = ScrollSmoothingFilter()
        // Hold a constant input: the filter must converge to it, i.e. unity steady-state gain.
        var out = 0.0
        for _ in 0..<200 { out = filter.filter(10) }
        expectClose(out, 10, "常量输入下滤波收敛到输入值（稳态增益为 1）")

        // Then let it drain: it must eventually report that it is done.
        var frames = 0
        while filter.isDraining, frames < 500 {
            _ = filter.filter(0)
            frames += 1
        }
        expect(!filter.isDraining, "输入停止后滤波会排空（用了 \(frames) 帧）")
    }

    /// The tap layer is a correctness requirement, not a preference.
    ///
    /// At `.cghidEventTap` the event's target-process field reports whichever window is
    /// frontmost rather than the one being scrolled, so every synthesised frame is delivered
    /// to the wrong process and the wheel appears dead. This shipped once; it is pinned now.
    private static func tapsWhereTargetIsAnnotated() {
        expect(
            EventTapController.tapLocation == .cgAnnotatedSessionEventTap,
            "事件监听在 annotated session 层（只有这一层带目标进程标注，与 Mos 一致）"
        )
        expect(
            EventTapController.tapPlacement == .tailAppendEventTap,
            "事件监听挂在链尾（tailAppend，与 Mos 一致）"
        )
    }

    /// A notch we cannot re-deliver must be passed through, never swallowed.
    private static func refusesUndeliverableTarget() {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0
        ) else {
            expect(false, "能构造滚轮事件用于投递检查")
            return
        }

        event.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
        expect(
            ScrollEventPoster.target(from: event) == nil,
            "目标进程为 0 时拒绝生成投递目标（调用方据此放行事件，最坏退化为不平滑而非滚轮失效）"
        )

        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
        let target = ScrollEventPoster.target(from: event)
        expect(target != nil, "目标进程有效时生成投递目标")
        expect(target?.pid == getpid(), "投递目标带上事件标注的目标进程 pid")
    }

    /// The review called PointDelta fractional, but Apple documents it as an integer and a
    /// real CGEvent quantises 0.5 to zero. FixedPtDelta is the representation that must retain
    /// fractions. This pins the actual field contract while still covering all three axes.
    private static func reversesAllScrollFields() {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 1, wheel2: -1, wheel3: 0
        ) else {
            expect(false, "能构造滚轮事件用于方向翻转检查")
            return
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 5)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.25)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -3)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -7)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -0.75)

        EventRouter.flipAxes(of: event, vertical: true, horizontal: true)
        let vertical = ScrollEventFields.vertical.read(from: event)
        let horizontal = ScrollEventFields.horizontal.read(from: event)
        expect(
            vertical.line == -2 && vertical.point == -5 && vertical.fixedPoint == -0.25
                && horizontal.line == 3 && horizontal.point == 7 && horizontal.fixedPoint == 0.75,
            "方向翻转按真实字段类型同时处理 DeltaAxis / PointDelta / FixedPtDelta"
        )

        ScrollEventFields.vertical.setPixelDelta(0.5, on: event)
        let synthetic = ScrollEventFields.vertical.read(from: event)
        expect(
            synthetic.point == 0 && synthetic.fixedPoint == 0.5,
            "合成亚像素滚动写入整数 PointDelta，并由 FixedPtDelta 保留小数"
        )
    }

    private static func auxiliaryEventsCarrySyntheticTag() {
        let down = ActionRunner.auxiliaryEvent(.mute, isDown: true)
        let up = ActionRunner.auxiliaryEvent(.mute, isDown: false)
        expect(
            down.map(SyntheticEventTag.isMarked) == true
                && up.map(SyntheticEventTag.isMarked) == true,
            "媒体键的按下和松开都带合成事件魔数"
        )
    }

    /// The window-management defaults, pinned against what macOS records in
    /// `com.apple.symbolichotkeys` on an untouched system.
    ///
    /// These were invented once instead of read, and every one of them silently did nothing:
    /// the gesture was recognised and the keystroke posted, but without the Fn bit the
    /// WindowServer never treats it as a system shortcut. Nothing errors, so nothing is
    /// noticed — hence the assertion.
    private static func windowManagementStrokesCarryFn() {
        let expected: [(SystemHotkeys.Symbolic, MouseAction, UInt16, CGEventFlags)] = [
            (.missionControl, .missionControl, 126, [.maskControl, .maskSecondaryFn]),
            (.applicationWindows, .applicationWindows, 125, [.maskControl, .maskSecondaryFn]),
            (.showDesktop, .showDesktop, 103, .maskSecondaryFn),
            (.spaceLeft, .spaceLeft, 123, [.maskControl, .maskSecondaryFn]),
            (.spaceRight, .spaceRight, 124, [.maskControl, .maskSecondaryFn])
        ]
        for (hotkey, action, code, flags) in expected {
            expect(
                SystemHotkeys.defaults[hotkey] == SystemHotkeys.Stroke(keyCode: code, flags: flags),
                "\(ActionKind(action).title) 默认键码 \(code) 且带 Fn 位（对齐系统配置）"
            )
            expect(
                ActionRunner.symbolicHotkey(for: action) == hotkey,
                "\(ActionKind(action).title) 映射到系统热键 \(hotkey.rawValue)"
            )
        }
        expect(
            SystemHotkeys.Symbolic.windowManagement.allSatisfy {
                SystemHotkeys.defaults[$0]?.flags.contains(.maskSecondaryFn) == true
            },
            "所有窗口管理动作都带 Fn 位，否则系统不会当成系统快捷键"
        )
        // Every ID we can ask about must have a shipped default, or `resolve` force-unwraps nil
        // on a machine whose plist has no entry for it.
        expect(
            SystemHotkeys.Symbolic.allCases.allSatisfy { SystemHotkeys.defaults[$0] != nil },
            "每个系统热键都有内置默认值，在系统未记录该条目时可回落"
        )
        // Anything routed to the system must resolve to an ID; a case that falls through would
        // be a picker entry that does nothing at all.
        let systemBacked: [MouseAction] = [
            .missionControl, .applicationWindows, .showDesktop, .spaceLeft, .spaceRight,
            .cycleWindows, .spotlight, .screenshotSelection, .screenshotOptions,
            .toggleDock, .nextInputSource, .quickNote
        ]
        expect(
            systemBacked.allSatisfy { ActionRunner.symbolicHotkey(for: $0) != nil },
            "所有交给系统快捷键执行的动作都能解析到热键 ID（\(systemBacked.count) 个）"
        )
        expect(
            ActionRunner.fallbackHotkey(for: .spotlight) == .spotlightWindow,
            "聚焦被停用时回落到聚焦窗口（第三方启动器常只接管其中一个）"
        )
        // The function-row keys, each confirmed against the system log on macOS 26.6 rather
        // than copied from a table. 131 is the one worth pinning: Mos calls it `appExpose`,
        // its own UI labels it 启动台, and what it actually does is open Spotlight's app
        // browser — the thing that replaced Launchpad.
        expect(
            SystemHotkeys.FunctionKey.appBrowser.stroke
                == SystemHotkeys.Stroke(keyCode: 131, flags: .maskSecondaryFn),
            "启动台（浏览所有应用）= 键码 131 + Fn（已用系统日志 .launchAppsBrowsing 证实）"
        )
        expect(
            SystemHotkeys.FunctionKey.missionControl.stroke
                == SystemHotkeys.Stroke(keyCode: 160, flags: .maskSecondaryFn),
            "调度中心功能键 = 键码 160 + Fn"
        )
        expect(
            SystemHotkeys.FunctionKey.controlCenter.stroke
                == SystemHotkeys.Stroke(keyCode: 178, flags: .maskSecondaryFn),
            "控制中心 = 键码 178 + Fn"
        )
        expect(
            SystemHotkeys.FunctionKey.allCases.allSatisfy { $0.stroke.flags.contains(.maskSecondaryFn) },
            "功能行按键全部带 Fn 位"
        )
        expect(
            ActionRunner.functionKey(for: .appBrowser) == .appBrowser
                && ActionRunner.functionKey(for: .controlCenter) == .controlCenter,
            "启动台与控制中心走功能键路径，不走符号热键"
        )
        expect(
            KeyCombo.modifierMask & CGEventFlags.maskSecondaryFn.rawValue != 0,
            "快捷键录制保留 Fn 位，窗口管理组合不会被静默改坏"
        )
        expect(
            KeyCodeNames.modifierGlyphs(CGEventFlags.maskSecondaryFn.rawValue).contains("fn"),
            "录入的 Fn 修饰键在快捷键标签中可见"
        )
        // Old configs may still hold the removed `launchpad` action; it must decode to
        // passthrough rather than throwing away the whole binding list.
        let legacy = Data(#"{"button":3,"action":{"launchpad":{}}}"#.utf8)
        let decoded = try? JSONDecoder().decode(ButtonBinding.self, from: legacy)
        expect(decoded?.action == .passthrough, "旧配置里已移除的动作退回「不改变」，不会丢掉整条映射")
        // A shortcut the user switched off must be reported, not posted as key 65535.
        expect(
            SystemHotkeys.Resolution.disabledBySystem != .stroke(SystemHotkeys.defaults[.missionControl]!),
            "被系统关闭的快捷键与可用快捷键是两种不同结果，不会静默当成可用"
        )
    }

    /// Six flicks in two seconds must move six desktops, not two. The system discards a
    /// switch requested during a transition, so the extra steps have to be held.
    private static func queuesRapidSwitches() {
        MainActor.assumeIsolated {
        var fired: [MouseAction] = []
        let pacer = SpaceSwitchPacer { fired.append($0) }
        for _ in 0..<2 { pacer.request(.spaceRight) }
        // The first fires immediately; the rest are owed.
        expect(fired.count + pacer.pendingSteps == 2, "连续请求不会被丢弃，未发出的记在队列里")
        expect(pacer.pendingSteps > 0 || fired.count == 2, "有请求被排队或已全部发出")
        }
    }

    private static func reversalDiscardsBacklog() {
        MainActor.assumeIsolated {
        var fired: [MouseAction] = []
        let pacer = SpaceSwitchPacer { fired.append($0) }
        pacer.request(.spaceRight)
        pacer.request(.spaceRight)
        let backlog = pacer.pendingSteps
        pacer.request(.spaceLeft)
        expect(backlog >= 0, "向右的请求累积为正数步数")
        expect(
            pacer.pendingSteps <= 0,
            "反向请求会丢弃旧队列而不是逐步回退（回拨时用户要的是立刻回去）"
        )
        }
    }

    private static func capsTheQueue() {
        MainActor.assumeIsolated {
        var fired: [MouseAction] = []
        let pacer = SpaceSwitchPacer { fired.append($0) }
        for _ in 0..<20 { pacer.request(.spaceRight) }
        expect(
            pacer.pendingSteps <= SpaceSwitchPacer.maximumPending,
            "队列有上限（\(SpaceSwitchPacer.maximumPending) 步），慌乱连甩不会把人送到八个桌面外"
        )
        expectClose(SpaceSwitchPacer.interval, 0.12, "切换间隔对齐 Mos 的 0.12 秒")
        }
    }

    private static func charactersUsedByActions() -> [Character] {
        Array(Set(ActionKind.allCases.compactMap { kind in
            let action = kind.makeAction(preserving: .passthrough)
            guard case let .character(character, _) = ActionRunner.stroke(for: action) else {
                return nil
            }
            return character
        })).sorted { String($0) < String($1) }
    }

    /// A key code is a physical position, not a letter. The check that matters is the round
    /// trip: whatever code we resolve for "w" must be a position that actually types "w" on
    /// the layout in use — otherwise "close tab" sends ⌘Z on French or ⌘, on Dvorak.
    private static func resolvesCharactersOnLiveLayout() {
        let needed = charactersUsedByActions()
        var roundTripped = 0
        var mismatched: [String] = []
        for character in needed {
            guard let code = KeyboardLayout.keyCode(for: character) else {
                mismatched.append("\(character)→nil")
                continue
            }
            guard KeyboardLayout.isResolvedFromLiveLayout(character) else { continue }
            if KeyboardLayout.character(for: code) == character {
                roundTripped += 1
            } else {
                mismatched.append("\(character)→\(code)")
            }
        }
        expect(
            mismatched.isEmpty,
            "从当前布局解析出的键码能反向还原为同一字符"
                + (mismatched.isEmpty
                    ? "（\(roundTripped)/\(needed.count) 项来自实时布局）"
                    : "，不符: \(mismatched.joined(separator: " "))")
        )
    }

    /// Derive the required set from the production action table. A hand-written list copied
    /// from the fallback table would be a tautology and cannot catch a newly added shortcut.
    private static func hasFallbackForEveryCharacter() {
        let needed = charactersUsedByActions()
        let unresolved = needed.filter { KeyboardLayout.keyCode(for: $0) == nil }
        let missingFallbacks = needed.filter { KeyboardLayout.ansiFallback[$0] == nil }
        expect(
            unresolved.isEmpty && missingFallbacks.isEmpty,
            unresolved.isEmpty && missingFallbacks.isEmpty
                ? "全部 \(needed.count) 个动作字符都能解析，且有 ANSI 兜底"
                : "无法解析: \(unresolved)，缺少兜底: \(missingFallbacks)"
        )
        expect(
            KeyboardLayout.ansiFallback["c"] == UInt16(kVK_ANSI_C)
                && KeyboardLayout.ansiFallback["1"] == UInt16(kVK_ANSI_1),
            "ANSI 兜底使用系统的 kVK_ANSI_* 物理位置常量"
        )
        expect(
            KeyboardLayout.keyCode(for: "🙂") == nil,
            "无法解析的字符返回 nil，不会退化成某个真实按键"
        )
    }

    private static func failedLayoutBuildIsRetried() {
        let cache = Locked<[Character: UInt16]?>(nil)
        var attempts = 0
        let first = KeyboardLayout.resolveTable(cache: cache) {
            attempts += 1
            return nil
        }
        let second = KeyboardLayout.resolveTable(cache: cache) {
            attempts += 1
            return ["x": UInt16(kVK_ANSI_X)]
        }
        expect(
            first.isEmpty && second["x"] == UInt16(kVK_ANSI_X) && attempts == 2,
            "键盘布局读取失败不会缓存为空成功结果，下一次解析会重试"
        )
    }

    private static func shortcutLabelsFollowLiveLayout() {
        expect(
            KeyCodeNames.name(for: UInt16(kVK_ANSI_A), resolveCharacter: { _ in "q" }) == "Q",
            "可打印键的标签来自当前布局，不来自 ANSI 键码硬编码表"
        )
    }

    /// Every action in the picker must actually do something. `handledElsewhere` is only
    /// legitimate for the two that are handled by the event router rather than by posting.
    private static func everyActionHasAStroke() {
        let handledByRouter: Set<ActionKind> = [.passthrough, .gestureNavigation]
        var unimplemented: [String] = []
        for kind in ActionKind.allCases where !handledByRouter.contains(kind) {
            let action = kind.makeAction(preserving: .passthrough)
            if ActionRunner.stroke(for: action) == .handledElsewhere {
                unimplemented.append(kind.title)
            }
        }
        expect(
            unimplemented.isEmpty,
            unimplemented.isEmpty
                ? "全部 \(ActionKind.allCases.count) 个动作都有实现，没有「选得到但没反应」的选项"
                : "有动作没有实现: \(unimplemented.joined(separator: "、"))"
        )
    }

    /// Two picker entries that post the identical keystroke are two names for one thing, which
    /// is a UI bug and usually a sign one of them was meant to be something else.
    private static func noTwoActionsSendTheSameKeys() {
        var seen: [String: String] = [:]
        var duplicates: [String] = []
        for kind in ActionKind.allCases {
            let action = kind.makeAction(preserving: .passthrough)
            let stroke = ActionRunner.stroke(for: action)
            let signature: String
            switch stroke {
            case let .character(character, flags):
                guard let code = KeyboardLayout.keyCode(for: character) else {
                    duplicates.append("\(kind.title) / 字符 \(character) 无法解析")
                    continue
                }
                signature = "key:\(code):\(flags.rawValue)"
            case let .key(code, flags):
                signature = "key:\(code):\(flags.rawValue)"
            case let .held(code, flags):
                signature = "held:\(code):\(flags.rawValue)"
            case .systemHotkey, .functionKey, .aux:
                signature = "\(stroke)"
            default:
                continue
            }
            if let existing = seen[signature] {
                duplicates.append("\(existing) / \(kind.title)")
            } else {
                seen[signature] = kind.title
            }
        }
        expect(
            duplicates.isEmpty,
            duplicates.isEmpty
                ? "没有两个动作发出完全相同的按键"
                : "重复的动作: \(duplicates.joined(separator: "，"))"
        )
    }

    private static func survivesJSONRoundTrip() {
        var prefs = Preferences()
        prefs.scroll.minimumStep = 64
        prefs.buttons = [
            ButtonBinding(button: 3, action: .keyStroke(KeyCombo(keyCode: 8, modifiers: 1_048_576)))
        ]
        prefs.rules = [AppRule(bundleID: "com.apple.dt.Xcode", name: "Xcode", mode: .custom)]
        do {
            let data = try JSONEncoder().encode(prefs)
            let decoded = try JSONDecoder().decode(Preferences.self, from: data)
            expect(decoded == prefs, "配置经过 JSON 往返后保持一致")
        } catch {
            expect(false, "配置 JSON 编解码抛出异常: \(error)")
        }
    }

    // MARK: Updates

    private static func hasDefaultUpdateSource() {
        let settings = UpdateSettings()
        expect(UpdateSettings.repository.contains("/"), "更新源已内置，开箱即可检查更新")
        expect(settings.checkAutomatically, "默认开启自动检查")
    }

    private static func comparesVersions() {
        expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0"), "补丁号更大算新版本")
        expect(UpdateChecker.isNewer("v1.2.0", than: "1.1.9"), "标签前的 v 会被忽略")
        expect(UpdateChecker.isNewer("1.10.0", than: "1.9.9"), "按数值而不是字符串比较（1.10 > 1.9）")
        expect(UpdateChecker.isNewer("1.1", than: "1.0.9"), "位数不同也能正确比较")
        expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"), "相同版本不算新")
        expect(!UpdateChecker.isNewer("0.9.9", than: "1.0.0"), "更旧的版本不算新")
        expect(!UpdateChecker.isNewer("乱码", than: "1.0.0"), "无法解析的版本号不会误报有更新")
        expect(UpdateChecker.isNewer("1.2.0-beta.1", than: "1.1.0"), "预发布后缀被截断后仍可比较")
    }

    private static func parsesRelease() {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "0.2.0 更快的滚动",
          "body": "修了几个问题",
          "html_url": "https://github.com/owner/repo/releases/tag/v0.2.0",
          "published_at": "2026-08-01T10:00:00Z",
          "prerelease": false
        }
        """
        guard let data = json.data(using: .utf8), let release = UpdateChecker.parseRelease(data) else {
            expect(false, "能解析 GitHub 的发布信息")
            return
        }
        expect(release.version == "v0.2.0", "解析出版本标签")
        expect(release.name == "0.2.0 更快的滚动", "解析出发布名称")
        expect(release.url.host == "github.com", "解析出发布页地址")
        expect(release.publishedAt != nil, "解析出发布时间")
        expect(!release.isPrerelease, "解析出是否为预发布")
    }

    private static func rejectsBadPayload() {
        expect(UpdateChecker.parseRelease(Data("not json".utf8)) == nil, "非 JSON 返回 nil 而不是崩溃")
        expect(
            UpdateChecker.parseRelease(Data("{\"tag_name\":\"v1\"}".utf8)) == nil,
            "缺少必要字段时返回 nil"
        )
    }
}
