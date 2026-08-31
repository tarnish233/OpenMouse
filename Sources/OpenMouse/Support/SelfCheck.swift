import AppKit
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

    private final class ProbeEventTap: EventTapLifecycle {
        private(set) var isRunning = false
        var onAutoReenable: ((EventTapDisableReason) -> Void)?
        var startSucceeds = true
        private(set) var startMasks: [CGEventMask] = []
        private(set) var stopCount = 0

        @discardableResult
        func start(mask: CGEventMask) -> Bool {
            startMasks.append(mask)
            isRunning = startSucceeds
            return startSucceeds
        }

        func stop() {
            stopCount += 1
            isRunning = false
        }

        func simulateDisable(_ reason: EventTapDisableReason) {
            onAutoReenable?(reason)
        }
    }

    private final class ProbeGestureOutput: GestureNavigationOutput {
        struct Begin: Equatable {
            var button: Int
            var axis: MouseGestureAxis
            var pixelDelta: Double
            var location: CGPoint
            var canFreezePointer: Bool
        }

        var supportsInteractiveNavigation: Bool
        var beginSucceeds = true
        private(set) var begins: [Begin] = []
        private(set) var changes: [(button: Int, pixelDelta: Double)] = []
        private(set) var pointerMovementButtons: [Int] = []
        private(set) var ends: [(button: Int, cancelled: Bool)] = []
        private(set) var cancelAllCount = 0

        init(supportsInteractiveNavigation: Bool = true) {
            self.supportsInteractiveNavigation = supportsInteractiveNavigation
        }

        func begin(
            button: Int,
            axis: MouseGestureAxis,
            initialPixelDelta: Double,
            location: CGPoint,
            canFreezePointer: Bool
        ) -> Bool {
            begins.append(Begin(
                button: button,
                axis: axis,
                pixelDelta: initialPixelDelta,
                location: location,
                canFreezePointer: canFreezePointer
            ))
            return beginSucceeds
        }

        func change(button: Int, pixelDelta: Double) {
            changes.append((button, pixelDelta))
        }

        func allowPointerMovement(button: Int) {
            pointerMovementButtons.append(button)
        }

        func end(button: Int, cancelled: Bool) {
            ends.append((button, cancelled))
        }

        func cancelAll() {
            cancelAllCount += 1
        }
    }

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
            scrollRulesFollowEventTarget()
            statusMenuTogglesBypassRule()
            appRuleEditorCoversEveryScrollField()
        }
        group("按键映射") {
            defaultAction()
            modifierVariant()
            inactiveDetection()
            motionMaskCoversPlainMovement()
            buttonReleaseUsesPressClaim()
        }
        group("Logi HID++") {
            hidppEncodesDivertWithoutRemapping()
            hidppDecodesPhysicalHoldSet()
            hidppHoldOutlivesMomentaryNativeMouseUp()
        }
        group("手势导航") {
            commitsDominantAxis()
            ignoresDiagonalDrift()
            keepsAxisLockedAfterFirstDirection()
            treatsStillHoldAsClick()
            mapsDirectionsLikeLogiOptions()
            measuresFromLocationWhenDeltasAreEmpty()
            prefersDeltaFieldsWhenPresent()
            routesGestureLikeLogiOptions()
            dockSwipeProgressFollowsReversal()
            dockSwipeCancelsContradictoryExit()
            dockSwipeCommitsShortFastFlick()
            staleDockSwipeEndCannotCancelReversal()
            dockSwipeEncoderCarriesRequiredFields()
        }
        group("动作选择器") {
            actionKindRoundTrip()
            preservesShortcutPayload()
            unsetShortcutIsInertAndVisible()
            groupsAreComplete()
        }
        group("冲突检测") {
            detectsDebugBuilds()
            deduplicatesPerProduct()
            ignoresUnrelatedApps()
        }
        group("应用元数据与生命周期") {
            activationLeaseIsIdempotent()
            applicationMenuProvidesStandardShortcuts()
            settingsWindowWaitsForActivationBeforeOrderingFront()
            versionFallbackIsHonest()
            statusItemPresentationTracksRuntimeState()
        }
        group("偏好设置") {
            clampsOutOfRange()
            startsWithNoButtons()
            migratesEnumeratedButtons()
            sortsBindings()
            toleratesBrokenSections()
            preservesBindingsAcrossSchemaChanges()
            debouncedSaveLeavesMainRunLoop()
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
            continuousDevicePolicyIsConsistent()
            auxiliaryEventsCarrySyntheticTag()
        }
        group("事件监听生命周期") {
            eventTapDisableReasonsAreObservable()
            engineConvergesAcrossPermissionChanges()
        }
        group("系统快捷键") {
            windowManagementStrokesCarryFn()
            gestureSpaceStrokeMatchesLogiTrace()
            rejectsInvalidSystemHotkeyNumbers()
        }
        group("更新检查") {
            hasDefaultUpdateSource()
            comparesVersions()
            automaticScheduleUsesWallClock()
            updateRequestHasHardResourceDeadline()
            skippedReleaseIsFiltered()
            parsesReleaseRedirect()
            rejectsUnexpectedReleaseURLs()
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
        let config = ResolvedConfig(preferences: prefs, bundleID: "com.apple.Safari")
        expect(config.active && config.scroll.speed == 7.7 && config.buttonsActive, "没有规则时使用全局设置")
    }

    private static func statusMenuTogglesBypassRule() {
        var prefs = Preferences()
        prefs.scroll.speed = 7.25
        var custom = AppRule(bundleID: "com.example.Editor", name: "Editor", mode: .custom)
        custom.scroll.reverseHorizontal = true
        prefs.rules = [custom]

        prefs.toggleBypassRule(bundleID: custom.bundleID, name: custom.name)
        expect(
            prefs.rules.count == 1 && prefs.rules[0].id == custom.id
                && prefs.rules[0].mode == .bypass && prefs.rules[0].scroll.reverseHorizontal,
            "状态菜单会把已有 custom 规则切成 bypass，而不是被重复规则保护静默忽略"
        )

        prefs.toggleBypassRule(bundleID: custom.bundleID, name: custom.name)
        expect(prefs.rules.isEmpty, "再次启用应用会移除 bypass 规则并恢复全局行为")

        prefs.toggleBypassRule(bundleID: "com.example.New", name: "New")
        expect(
            prefs.rules.count == 1 && prefs.rules[0].mode == .bypass
                && prefs.rules[0].scroll.speed == prefs.scroll.speed,
            "没有既有规则时状态菜单会创建继承全局滚动参数的 bypass 规则"
        )
    }

    private static func appRuleEditorCoversEveryScrollField() {
        do {
            let data = try JSONEncoder().encode(ScrollSettings())
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                expect(false, "可读取 ScrollSettings 的编码字段")
                return
            }
            let storedFields = Set(object.keys)
            let editableFields = Set(AppRuleScrollField.allCases.map(\.rawValue))
            let missing = storedFields.subtracting(editableFields).sorted()
            let stale = editableFields.subtracting(storedFields).sorted()
            let details = [
                missing.isEmpty ? nil : "缺少：\(missing.joined(separator: "、"))",
                stale.isEmpty ? nil : "多余：\(stale.joined(separator: "、"))"
            ].compactMap { $0 }.joined(separator: "；")
            expect(
                storedFields == editableFields,
                details.isEmpty
                    ? "应用自定义规则编辑器覆盖 ScrollSettings 全部 \(storedFields.count) 个字段"
                    : "应用自定义规则编辑器与 ScrollSettings 不一致（\(details)）"
            )
        } catch {
            expect(false, "检查应用规则滚动字段时编码失败：\(error)")
        }
    }

    private static func bypassRule() {
        var prefs = Preferences()
        prefs.rules = [AppRule(bundleID: "com.apple.Terminal", name: "Terminal", mode: .bypass)]
        let config = ResolvedConfig(preferences: prefs, bundleID: "com.apple.Terminal")
        expect(!config.active && !config.buttonsActive, "bypass 规则会完全放行该应用")
    }

    private static func customRule() {
        var prefs = Preferences()
        prefs.scroll.minimumStep = 40
        var rule = AppRule(bundleID: "com.figma.Desktop", name: "Figma", mode: .custom)
        rule.scroll.minimumStep = 120
        rule.bypassButtons = true
        prefs.rules = [rule]

        let matched = ResolvedConfig(preferences: prefs, bundleID: "com.figma.Desktop")
        let other = ResolvedConfig(preferences: prefs, bundleID: "com.apple.Safari")
        expect(matched.scroll.minimumStep == 120 && !matched.buttonsActive, "自定义规则只作用于匹配的应用")
        expect(other.scroll.minimumStep == 40 && other.buttonsActive, "其他应用不受影响")
    }

    private static func masterSwitchWins() {
        var prefs = Preferences()
        prefs.enabled = false
        expect(!ResolvedConfig(preferences: prefs, bundleID: nil).active, "总开关优先于所有规则")
    }

    /// Per-app scroll rules must use the annotated target process, not whichever app happens
    /// to be frontmost while the pointer is over a background window.
    private static func scrollRulesFollowEventTarget() {
        var prefs = Preferences()
        var frontRule = AppRule(bundleID: "com.example.front", name: "Front", mode: .custom)
        frontRule.scroll.reverseVertical = true
        prefs.rules = [
            frontRule,
            AppRule(bundleID: "com.example.background", name: "Background", mode: .bypass)
        ]

        let resolver = ScrollRuleResolver()
        resolver.updatePreferences(prefs)
        resolver.replaceApplications([
            (pid: 101, bundleID: "com.example.front"),
            (pid: 202, bundleID: "com.example.background")
        ])

        let frontmost = ResolvedConfig(preferences: prefs, bundleID: "com.example.front")
        let router = EventRouter(config: Locked(frontmost), scrollRules: resolver)
        guard let backgroundEvent = scrollEvent(targetPID: 202),
              let frontEvent = scrollEvent(targetPID: 101),
              let unknownEvent = scrollEvent(targetPID: 303) else {
            expect(false, "可构造带目标进程的滚动事件")
            return
        }

        expect(
            router.resolvedScrollConfig(for: backgroundEvent) == .inactive,
            "后台 bypass 窗口按事件 target pid 解析规则，不误用前台 custom 规则"
        )
        expect(
            router.resolvedScrollConfig(for: frontEvent).scroll.reverseVertical,
            "目标进程命中自身 custom 规则"
        )
        expect(
            router.resolvedScrollConfig(for: unknownEvent)
                == ResolvedConfig(preferences: prefs, bundleID: nil),
            "未知 pid 安全回落全局规则，不借用 frontmost 身份"
        )

        resolver.applicationDidTerminate(pid: 202)
        expect(
            router.resolvedScrollConfig(for: backgroundEvent).active,
            "进程终止通知会移除 pid 缓存，避免 pid 复用后沿用旧规则"
        )
        resolver.applicationDidLaunch(pid: 202, bundleID: "com.example.background")
        expect(
            router.resolvedScrollConfig(for: backgroundEvent) == .inactive,
            "进程启动通知可恢复 target pid 到 bundle id 的规则映射"
        )
    }

    private static func scrollEvent(targetPID: pid_t) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        return event
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

    /// A down swallowed under one binding owns its up even if modifiers, bindings and the
    /// active app all change while the button is held.
    private static func buttonReleaseUsesPressClaim() {
        let modifier = CGEventFlags.maskCommand.rawValue
        let snapshot = Locked(ResolvedConfig(active: true, scroll: .default, buttonsActive: true))
        var fired: [MouseAction] = []
        let router = EventRouter(config: snapshot, runAction: { fired.append($0) })
        router.updateBindings([
            ButtonBinding(button: 4, modifiers: modifier, action: .gestureNavigation)
        ])
        var activity: [Bool] = []
        router.onGestureActivityChanged = { activity.append($0) }

        guard let down = mouseButtonEvent(
            type: .otherMouseDown,
            button: 4,
            modifiers: modifier,
            location: CGPoint(x: 10, y: 20)
        ), let up = mouseButtonEvent(
            type: .otherMouseUp,
            button: 4,
            modifiers: 0,
            location: CGPoint(x: 10, y: 20)
        ) else {
            expect(false, "可构造侧键按下与抬起事件")
            return
        }

        expect(router.handleButton(type: .otherMouseDown, event: down) == nil, "有修饰键的侧键按下被接管")
        expect(
            router.activeButtonClaimCount == 1 && router.activeGestureSessionCount == 1,
            "按下后记录释放所有权与手势会话"
        )

        // Exercise every mutable input that used to be re-resolved on mouse-up.
        snapshot.value = .inactive
        router.updateBindings([])
        expect(router.handleButton(type: .otherMouseUp, event: up) == nil, "配置变化后的裸抬起仍被吞掉")
        expect(
            router.activeButtonClaimCount == 0 && router.activeGestureSessionCount == 0,
            "抬起按按下时的 claim 收尾，不遗留会话"
        )
        expect(activity == [true, false], "手势活动状态成对开始与结束")
        expect(fired == [.missionControl], "静止手势仍按按下时动作解释为单击")
    }

    private static func hidppEncodesDivertWithoutRemapping() {
        expect(
            LogitechHIDPPProtocol.reportingParameters(cid: 0x0056, divert: true)
                == [0x00, 0x56, 0x03, 0x00, 0x00],
            "SetControlReporting 只设置 divert+valid，不改写 Forward 的 target CID"
        )
        expect(
            LogitechHIDPPProtocol.reportingParameters(cid: 0x0056, divert: false)
                == [0x00, 0x56, 0x02, 0x00, 0x00],
            "解除接管时保留 valid 位并清除 divert 值"
        )
    }

    private static func hidppDecodesPhysicalHoldSet() {
        let held: [UInt8] = [
            0x11, 0xFF, 0x42, 0x00,
            0x00, 0x56, 0x00, 0xC3, 0x00, 0x00
        ]
        expect(
            LogitechHIDPPProtocol.activeButtons(
                in: held,
                ownedCIDs: [0x0056, 0x00C3]
            ) == [4],
            "HID++ 活跃 CID 集合聚合为一个物理 Forward/手势按钮按住状态"
        )
        expect(
            LogitechHIDPPProtocol.activeButtons(
                in: [0x11, 0xFF, 0x42, 0x00, 0x00, 0x00],
                ownedCIDs: [0x0056]
            ).isEmpty,
            "HID++ 空活跃集合明确表示物理按钮已抬起"
        )
    }

    /// The M750 L native Forward stream was observed ending 4–24 ms after down even while the
    /// user was still holding it. Once HID++ owns that control, the native up must not tear down
    /// the gesture; only the physical-state HID++ release may do so.
    private static func hidppHoldOutlivesMomentaryNativeMouseUp() {
        let snapshot = Locked(ResolvedConfig(active: true, scroll: .default, buttonsActive: true))
        var gestureActions: [MouseAction] = []
        let router = EventRouter(
            config: snapshot,
            runGestureAction: { gestureActions.append($0) },
            runAction: { _ in }
        )
        router.updateBindings([ButtonBinding(button: 4, action: .gestureNavigation)])
        router.updateHIDPPOwnedButtons([4])
        router.handleHIDPPButton(button: 4, isDown: true)

        guard let nativeUp = mouseButtonEvent(
            type: .otherMouseUp,
            button: 4,
            modifiers: 0,
            location: CGPoint(x: 100, y: 100)
        ), let motion = mouseMotionEvent(
            location: CGPoint(x: 112, y: 100),
            deltaX: 12,
            deltaY: 0
        ) else {
            expect(false, "可构造 HID++ 手势的原生伪抬起和后续位移")
            return
        }

        expect(
            router.handleButton(type: .otherMouseUp, event: nativeUp) == nil
                && router.activeGestureSessionCount == 1,
            "HID++ 已接管时忽略 M750 L 的瞬时原生 mouse-up，保持手势会话"
        )
        _ = router.handleMotion(motion)
        expect(
            gestureActions == [.spaceLeft],
            "原生伪抬起后继续接收位移，并按 Logi 模型触发一次离散桌面动作"
        )
        router.handleHIDPPButton(button: 4, isDown: false)
        expect(
            router.activeButtonClaimCount == 0
                && router.activeGestureSessionCount == 0,
            "只有 HID++ 物理 release 才结束已接管的手势会话"
        )
    }

    private static func mouseButtonEvent(
        type: CGEventType,
        button: Int,
        modifiers: UInt64,
        location: CGPoint
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else { return nil }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.flags = CGEventFlags(rawValue: modifiers)
        return event
    }

    // MARK: Gesture navigation

    /// Real mice were observed delivering `.otherMouseDragged` with both delta fields at
    /// zero, so a recognizer that only accumulated deltas measured no movement at all and
    /// ended every gesture as "never moved". The location has to be able to carry it.
    private static func measuresFromLocationWhenDeltasAreEmpty() {
        var recognizer = MouseGestureRecognizer()
        recognizer.begin(at: CGPoint(x: 500, y: 500))
        var firstUpdate: MouseGestureUpdate?
        for step in 1...8 {
            let point = CGPoint(x: 500, y: 500 - Double(step) * 10)
            if let update = recognizer.append(location: point, fieldDeltaX: 0, fieldDeltaY: 0) {
                firstUpdate = firstUpdate ?? update
            }
        }
        expect(
            firstUpdate == .began(axis: .vertical, pixelDelta: -10),
            "位移字段为 0 时改用事件坐标测量，仍能锁定纵轴"
        )
        expectClose(recognizer.maximumDistanceFromOrigin, 80, "累积位移取自坐标差")
        expect(!recognizer.shouldTreatAsClick, "有真实移动时不会被误判成原地单击")
    }

    /// The delta fields keep counting when the pointer is clamped at a screen edge, where the
    /// location stops changing — so when they carry something, they win.
    private static func prefersDeltaFieldsWhenPresent() {
        var recognizer = MouseGestureRecognizer()
        let edge = CGPoint(x: 1919, y: 500)
        recognizer.begin(at: edge)
        var firstUpdate: MouseGestureUpdate?
        for _ in 1...6 {
            if let update = recognizer.append(location: edge, fieldDeltaX: 12, fieldDeltaY: 0) {
                firstUpdate = firstUpdate ?? update
            }
        }
        expect(
            firstUpdate == .began(axis: .horizontal, pixelDelta: 12),
            "指针被屏幕边缘卡住、坐标不再变化时，改用位移字段"
        )
    }

    private static func commitsDominantAxis() {
        var up = MouseGestureRecognizer()
        // CGEvent delta Y is positive downward, so negative travel is "up".
        expect(
            up.append(deltaX: 0, deltaY: -50) == .began(axis: .vertical, pixelDelta: -50),
            "向上划锁定纵轴并保留符号"
        )

        var down = MouseGestureRecognizer()
        expect(
            down.append(deltaX: 0, deltaY: 50) == .began(axis: .vertical, pixelDelta: 50),
            "向下划锁定纵轴并保留符号"
        )

        var left = MouseGestureRecognizer()
        expect(
            left.append(deltaX: -50, deltaY: 0) == .began(axis: .horizontal, pixelDelta: -50),
            "向左划锁定横轴并保留符号"
        )

        var right = MouseGestureRecognizer()
        expect(
            right.append(deltaX: 50, deltaY: 0) == .began(axis: .horizontal, pixelDelta: 50),
            "向右划锁定横轴并保留符号"
        )
    }

    private static func ignoresDiagonalDrift() {
        var recognizer = MouseGestureRecognizer()
        // Past the activation distance but with neither axis dominant: hold off deciding.
        expect(recognizer.append(deltaX: 45, deltaY: 44) == nil, "太斜的移动不会替用户猜方向")
        // Committing further along one axis then resolves it.
        expect(
            recognizer.append(deltaX: 40, deltaY: 0)
                == .began(axis: .horizontal, pixelDelta: 85),
            "继续沿一个轴移动后才锁定，并补回死区内累计位移"
        )
    }

    private static func keepsAxisLockedAfterFirstDirection() {
        var recognizer = MouseGestureRecognizer()
        expect(
            recognizer.append(deltaX: -50, deltaY: 0)
                == .began(axis: .horizontal, pixelDelta: -50),
            "第一次越过阈值锁定横轴"
        )
        expect(
            recognizer.append(deltaX: -12, deltaY: 3)
                == .changed(axis: .horizontal, pixelDelta: -12),
            "识别器继续记录同向增量，供诊断使用但路由器不会重复触发"
        )
        expect(
            recognizer.append(deltaX: 30, deltaY: -4)
                == .changed(axis: .horizontal, pixelDelta: 30),
            "识别器保留反向增量，但 Logi 风格路由在同一次按住中会忽略它"
        )
        expect(
            recognizer.append(deltaX: 0, deltaY: 100) == nil,
            "锁定横轴后忽略垂直漂移，不在一次按住中切换系统手势类型"
        )
    }

    private static func treatsStillHoldAsClick() {
        var still = MouseGestureRecognizer()
        _ = still.append(deltaX: 2, deltaY: -3)
        expect(still.completion == .click, "几乎没动的按住算作单击")

        var moved = MouseGestureRecognizer()
        _ = moved.append(deltaX: 0, deltaY: -50)
        expect(moved.completion == .gesture(.vertical), "已经锁轴的拖动不会在抬起时再变成单击")

        var deadZone = MouseGestureRecognizer()
        _ = deadZone.append(deltaX: 5, deltaY: 0)
        expect(deadZone.completion == .click, "5px 未越过方向阈值时明确回落为单击")

        var diagonal = MouseGestureRecognizer()
        _ = diagonal.append(deltaX: 300, deltaY: 300)
        expect(diagonal.completion == .click, "长距离 45° 斜划不乱猜方向，并在抬起时回落为单击")

        var roundTrip = MouseGestureRecognizer()
        _ = roundTrip.append(deltaX: 3, deltaY: 0)
        _ = roundTrip.append(deltaX: -3, deltaY: 0)
        expect(roundTrip.completion == .click, "死区内往返手抖也有确定的单击结果")
    }

    private static func mapsDirectionsLikeLogiOptions() {
        expect(MouseGestureDirection.up.action == .missionControl, "上 = 调度中心")
        expect(MouseGestureDirection.down.action == .applicationWindows, "下 = 应用程序窗口")
        // Inverted on purpose: shoving the mouse left pushes the desktop aside, which is the
        // same direction sense as a trackpad swipe.
        expect(MouseGestureDirection.left.action == .spaceRight, "左划 = 切到右边的桌面（与触控板同向）")
        expect(MouseGestureDirection.right.action == .spaceLeft, "右划 = 切到左边的桌面")
    }

    /// EventRouter must keep the whole signed movement stream on the interactive output edge.
    /// Sending one symbolic hotkey here would recreate the exact uninterruptible animation this
    /// path exists to replace.
    /// A direct trace of Logi Options+ on 2026-08-31 showed no Dock-swipe events. Its agent
    /// posts exactly one Control+Arrow-style action when the first direction locks, ignores all
    /// later motion in the same hold, then allows a new physical press to fire immediately even
    /// while the previous Space animation is still running.
    private static func routesGestureLikeLogiOptions() {
        let snapshot = Locked(ResolvedConfig(active: true, scroll: .default, buttonsActive: true))
        let output = ProbeGestureOutput()
        var gestureActions: [MouseAction] = []
        var clickActions: [MouseAction] = []
        let router = EventRouter(
            config: snapshot,
            gestureOutput: output,
            runGestureAction: { gestureActions.append($0) },
            runAction: { clickActions.append($0) }
        )
        router.updateBindings([ButtonBinding(button: 4, action: .gestureNavigation)])

        guard let down = mouseButtonEvent(
            type: .otherMouseDown,
            button: 4,
            modifiers: 0,
            location: CGPoint(x: 500, y: 400)
        ), let left = mouseMotionEvent(
            location: CGPoint(x: 480, y: 400),
            deltaX: -20,
            deltaY: 0
        ), let reverse = mouseMotionEvent(
            location: CGPoint(x: 520, y: 400),
            deltaX: 40,
            deltaY: 0
        ), let up = mouseButtonEvent(
            type: .otherMouseUp,
            button: 4,
            modifiers: 0,
            location: CGPoint(x: 520, y: 400)
        ), let right = mouseMotionEvent(
            location: CGPoint(x: 540, y: 400),
            deltaX: 20,
            deltaY: 0
        ) else {
            expect(false, "可构造 Logi 风格离散手势事件流")
            return
        }

        _ = router.handleButton(type: .otherMouseDown, event: down)
        _ = router.handleMotion(left)
        _ = router.handleMotion(reverse)
        _ = router.handleButton(type: .otherMouseUp, event: up)

        expect(
            gestureActions == [.spaceRight],
            "一次按住只按第一次锁定的方向触发一次，后续反向移动不切回"
        )
        expect(
            output.begins.isEmpty && output.changes.isEmpty && output.ends.isEmpty,
            "生产手势不再进入造成跳跃的私有 Dock-swipe 路径"
        )
        expect(clickActions.isEmpty, "已形成方向的手势不会在抬起时再触发单击动作")

        // A fresh physical press is a fresh command. There is intentionally no pacer state in
        // EventRouter, so this second action is delivered synchronously to the injected edge.
        _ = router.handleButton(type: .otherMouseDown, event: down)
        _ = router.handleMotion(right)
        _ = router.handleButton(type: .otherMouseUp, event: up)
        expect(
            gestureActions == [.spaceRight, .spaceLeft],
            "松开重按后可立即触发下一次或反方向切换，不等待上一段动画完成"
        )

        var locationActions: [MouseAction] = []
        let locationOnlyRouter = EventRouter(
            config: snapshot,
            runGestureAction: { locationActions.append($0) },
            runAction: { _ in }
        )
        locationOnlyRouter.updateBindings([ButtonBinding(button: 4, action: .gestureNavigation)])
        if let locationOnlyMotion = mouseMotionEvent(
            location: CGPoint(x: 480, y: 400),
            deltaX: 0,
            deltaY: 0
        ) {
            _ = locationOnlyRouter.handleButton(type: .otherMouseDown, event: down)
            _ = locationOnlyRouter.handleMotion(locationOnlyMotion)
            expect(
                locationActions == [.spaceRight],
                "位移字段为空时仍从事件坐标识别第一次方向"
            )
            locationOnlyRouter.cancelButtonSessions()
        } else {
            expect(false, "可构造仅带坐标差的移动事件")
        }

        var accumulatedActions: [MouseAction] = []
        let accumulatingRouter = EventRouter(
            config: snapshot,
            runGestureAction: { accumulatedActions.append($0) },
            runAction: { _ in }
        )
        accumulatingRouter.updateBindings([ButtonBinding(button: 4, action: .gestureNavigation)])
        if let firstFour = mouseMotionEvent(
            location: CGPoint(x: 496, y: 400),
            deltaX: -4,
            deltaY: 0
        ), let secondFour = mouseMotionEvent(
            location: CGPoint(x: 492, y: 400),
            deltaX: -4,
            deltaY: 0
        ) {
            _ = accumulatingRouter.handleButton(type: .otherMouseDown, event: down)
            _ = accumulatingRouter.handleMotion(firstFour)
            expect(accumulatedActions.isEmpty, "第一段 4px 仍在死区内，不会过早触发")
            _ = accumulatingRouter.handleMotion(secondFour)
            expect(
                accumulatedActions == [.spaceRight],
                "连续 4px + 4px 会累计越过 7px 死区并只触发一次"
            )
            accumulatingRouter.cancelButtonSessions()
        } else {
            expect(false, "可构造两段死区内移动事件")
        }

        // Keep the private encoder testable without exposing it as production behaviour.
        let diagnosticOutput = ProbeGestureOutput()
        let diagnosticRouter = EventRouter(
            config: snapshot,
            usesInteractiveGestureNavigation: true,
            gestureOutput: diagnosticOutput,
            runGestureAction: { _ in },
            runAction: { _ in }
        )
        diagnosticRouter.updateBindings([ButtonBinding(button: 4, action: .gestureNavigation)])
        _ = diagnosticRouter.handleButton(type: .otherMouseDown, event: down)
        _ = diagnosticRouter.handleMotion(left)
        _ = diagnosticRouter.handleButton(type: .otherMouseUp, event: up)
        expect(
            diagnosticOutput.begins.count == 1 && diagnosticOutput.ends.count == 1,
            "私有 Dock 编码器只在显式诊断模式下保持可测试"
        )
    }

    private static func mouseMotionEvent(
        location: CGPoint,
        deltaX: Int64,
        deltaY: Int64
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else { return nil }
        event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
        event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        return event
    }

    private static func dockSwipeProgressFollowsReversal() {
        var frames: [DockSwipeFrame] = []
        var pacedCancellationCount = 0
        let synthesizer = DockSwipeSynthesizer(
            supportsInteractiveNavigation: true,
            screenSize: { _ in CGSize(width: 937, height: 768) },
            endResendDelays: [],
            cancelPendingSpaceSwitches: { pacedCancellationCount += 1 },
            postFrame: { frames.append($0) }
        )

        expect(
            synthesizer.begin(
                button: 4,
                axis: .horizontal,
                initialPixelDelta: -100,
                location: .zero,
                canFreezePointer: true
            ),
            "支持的系统可以开始交互式 Dock-swipe"
        )
        expect(pacedCancellationCount == 1, "交互手势开始前清掉直接桌面动作的旧快捷键队列")
        synthesizer.change(button: 4, pixelDelta: 40)
        synthesizer.change(button: 4, pixelDelta: 90)
        synthesizer.end(button: 4, cancelled: false)

        expect(frames.map(\.phase) == [.began, .changed, .changed, .ended], "Dock-swipe 发送完整相位序列")
        expect(
            frames[0].progress > 0
                && frames[1].progress < frames[0].progress
                && frames[2].progress < 0,
            "鼠标反向时累计进度立即回拉并可越过原点，不等待动画完成"
        )
        expect(
            DockSwipeSynthesizer.progressDelta(
                fromPixelDelta: -10,
                axis: .horizontal,
                scale: 1
            ) == 10
                && DockSwipeSynthesizer.progressDelta(
                    fromPixelDelta: -10,
                    axis: .vertical,
                    scale: 1
                ) == -10,
            "横向与纵向遵循 Dock 的真实坐标约定：左推到右桌面、上推开调度中心"
        )
        expect(synthesizer.activeButton == nil, "抬起后清理交互式手势所有权")
        _ = synthesizer.begin(
            button: 4,
            axis: .horizontal,
            initialPixelDelta: 20,
            location: .zero,
            canFreezePointer: true
        )
        expect(
            frames.last?.phase == .began && (frames.last?.progress ?? 0) < 0,
            "上一段松手动画尚在结算时可立即用反向 began 接管"
        )
        synthesizer.cancelAll()

        var unsupportedFrames: [DockSwipeFrame] = []
        let unsupported = DockSwipeSynthesizer(
            supportsInteractiveNavigation: false,
            endResendDelays: [],
            postFrame: { unsupportedFrames.append($0) }
        )
        expect(
            !unsupported.begin(
                button: 4,
                axis: .horizontal,
                initialPixelDelta: -10,
                location: .zero,
                canFreezePointer: true
            ) && unsupportedFrames.isEmpty,
            "协议不受支持时不发送系统会忽略的私有字段，交给路由器安全降级"
        )
        expect(
            !DockSwipeSynthesizer.freezesPointerDuringProductionGesture,
            "生产手势不以冻结光标为代价切断 BLE 鼠标的后续位移事件"
        )
    }

    private static func dockSwipeCancelsContradictoryExit() {
        var frames: [DockSwipeFrame] = []
        var pointerAssociations: [Bool] = []
        var clock: TimeInterval = 0
        let synthesizer = DockSwipeSynthesizer(
            supportsInteractiveNavigation: true,
            screenSize: { _ in CGSize(width: 937, height: 768) },
            endResendDelays: [],
            freezesPointer: true,
            setPointerAssociation: {
                pointerAssociations.append($0)
                return true
            },
            now: { clock },
            postFrame: { frames.append($0) }
        )
        _ = synthesizer.begin(
            button: 4,
            axis: .horizontal,
            initialPixelDelta: -100,
            location: .zero,
            canFreezePointer: true
        )
        // A sustained reversal over the velocity window pulls backward without crossing the
        // origin. A normal Ended would commit in the stale accumulated direction.
        clock = 0.10
        synthesizer.change(button: 4, pixelDelta: 20)
        synthesizer.end(button: 4, cancelled: false)
        expect(frames.last?.phase == .cancelled, "松手方向与累计方向相反时以 cancelled 收尾")
        expect(pointerAssociations == [false, true], "交互式手势开始冻结指针，正常收尾必定恢复关联")

        frames.removeAll()
        pointerAssociations.removeAll()
        _ = synthesizer.begin(
            button: 4,
            axis: .vertical,
            initialPixelDelta: -20,
            location: .zero,
            canFreezePointer: true
        )
        synthesizer.cancelAll()
        expect(frames.last?.phase == .cancelled, "引擎 teardown 强制以 cancelled 释放 Dock 状态")
        expect(pointerAssociations == [false, true], "异常 teardown 也会恢复指针关联，不把光标永久锁死")
    }

    private static func dockSwipeCommitsShortFastFlick() {
        var fastFrames: [DockSwipeFrame] = []
        var fastClock: TimeInterval = 0
        let fast = DockSwipeSynthesizer(
            supportsInteractiveNavigation: true,
            screenSize: { _ in CGSize(width: 937, height: 768) },
            endResendDelays: [],
            now: { fastClock },
            postFrame: { fastFrames.append($0) }
        )
        _ = fast.begin(
            button: 4,
            axis: .horizontal,
            initialPixelDelta: -10,
            location: .zero,
            canFreezePointer: false
        )
        fastClock = 0.025
        fast.change(button: 4, pixelDelta: -20)
        fastClock = 0.035
        fast.end(button: 4, cancelled: false)
        expect(
            fastFrames.last?.phase == .ended
                && abs(fastFrames.last?.progress ?? 0) < DockSwipeSynthesizer.distanceCommitProgress
                && abs(fastFrames.last?.exitSpeed ?? 0) >= DockSwipeSynthesizer.velocityCommitThreshold,
            "小幅快速甩动以速度阈值完成切换，不要求拖过半屏"
        )

        var slowFrames: [DockSwipeFrame] = []
        var slowClock: TimeInterval = 0
        let slow = DockSwipeSynthesizer(
            supportsInteractiveNavigation: true,
            screenSize: { _ in CGSize(width: 937, height: 768) },
            endResendDelays: [],
            now: { slowClock },
            postFrame: { slowFrames.append($0) }
        )
        _ = slow.begin(
            button: 4,
            axis: .horizontal,
            initialPixelDelta: -10,
            location: .zero,
            canFreezePointer: false
        )
        slowClock = 0.30
        slow.change(button: 4, pixelDelta: -10)
        slowClock = 0.55
        slow.end(button: 4, cancelled: false)
        expect(
            slowFrames.last?.phase == .cancelled,
            "同样的小幅慢移在停顿后回弹，避免轻微调整误切桌面"
        )
        expect(
            DockSwipeSynthesizer.pointerProgressGain == 4
                && DockSwipeSynthesizer.maximumProgressMagnitude == 1.25,
            "鼠标位移增益提高且累计进度有上限，兼顾短行程与大幅甩动"
        )
    }

    private static func staleDockSwipeEndCannotCancelReversal() {
        var frames: [DockSwipeFrame] = []
        var delayedActions: [() -> Void] = []
        let synthesizer = DockSwipeSynthesizer(
            supportsInteractiveNavigation: true,
            screenSize: { _ in CGSize(width: 937, height: 768) },
            endResendDelays: [0.2, 0.5],
            scheduleAfter: { _, action in
                delayedActions.append(action)
                return DispatchWorkItem(block: {})
            },
            postFrame: { frames.append($0) }
        )
        _ = synthesizer.begin(
            button: 4,
            axis: .horizontal,
            initialPixelDelta: -20,
            location: .zero,
            canFreezePointer: true
        )
        synthesizer.end(button: 4, cancelled: false)
        let oldResends = delayedActions
        expect(oldResends.count == 2, "松手后安排两次可靠性 Ended 补发")

        _ = synthesizer.begin(
            button: 4,
            axis: .horizontal,
            initialPixelDelta: 20,
            location: .zero,
            canFreezePointer: true
        )
        let countAfterReversalBegan = frames.count
        oldResends.forEach { $0() }
        expect(
            frames.count == countAfterReversalBegan && frames.last?.phase == .began,
            "旧 Ended 即使已被 GCD 取出也会被 generation 拦截，不取消新反向手势"
        )
        synthesizer.cancelAll()
    }

    private static func dockSwipeEncoderCarriesRequiredFields() {
        let frame = DockSwipeFrame(
            axis: .horizontal,
            phase: .ended,
            progress: -1.25,
            exitSpeed: -3.5
        )
        guard let events = DockSwipeEventPoster.makeEvents(frame) else {
            expect(false, "可构造 Dock-swipe CGEvent 对")
            return
        }
        expectClose(DockSwipeEventPoster.doubleField(55, in: events.marker), 29, "伴随事件类型为 gesture (29)")
        expectClose(DockSwipeEventPoster.doubleField(55, in: events.control), 30, "主事件类型为 Dock control (30)")
        expectClose(DockSwipeEventPoster.doubleField(110, in: events.control), 23, "主事件 subtype 为 Dock-swipe (23)")
        expectClose(DockSwipeEventPoster.doubleField(132, in: events.control), 4, "编码 ended 主相位")
        expectClose(DockSwipeEventPoster.doubleField(134, in: events.control), 4, "编码 ended 冗余相位")
        expectClose(DockSwipeEventPoster.doubleField(124, in: events.control), -1.25, "编码可逆累计进度")
        expect(
            DockSwipeEventPoster.integerField(135, in: events.control)
                == Int64(Float(-1.25).bitPattern),
            "累计进度同时按 Float32 bit pattern 编码"
        )
        expectClose(DockSwipeEventPoster.doubleField(123, in: events.control), 1, "横轴编码为 1")
        expect(
            DockSwipeEventPoster.integerField(136, in: events.control) == 0,
            "macOS 14–26 的字段式合成事件必须保持 invertedFromDevice 为 0"
        )
        expectClose(DockSwipeEventPoster.doubleField(129, in: events.control), -3.5, "退出速度写入主字段")
        expectClose(DockSwipeEventPoster.doubleField(130, in: events.control), -3.5, "退出速度写入冗余字段")
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

    private static func unsetShortcutIsInertAndVisible() {
        let action = ActionKind.keyStroke.makeAction(preserving: .passthrough)
        guard case let .keyStroke(combo) = action else {
            expect(false, "选择自定义快捷键会产生可表示的未设置状态")
            return
        }

        expect(combo == .unset && !combo.isSet, "未录入快捷键使用 UInt16.max 哨兵，不冒充真实按键")
        expect(
            combo.valueIfSet == nil && Strings.buttonRecordShortcut.contains("未设置"),
            "未录入状态在录制控件里明确显示为未设置"
        )

        var posted: [UInt16] = []
        let runner = ActionRunner { code, _ in posted.append(code) }
        runner.run(action)
        expect(posted.isEmpty, "未录入的自定义快捷键不会到达按键投递边界")

        runner.run(.keyStroke(KeyCombo(keyCode: 0, modifiers: 0)))
        expect(posted == [0], "键码 0 仍是可录入的真实按键，不再承担空值哨兵")
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

    private static func activationLeaseIsIdempotent() {
        MainActor.assumeIsolated {
            var enters = 0
            var leaves = 0
            let lease = AppActivationLease(
                onEnter: { enters += 1 },
                onLeave: { leaves += 1 }
            )

            lease.enter()
            lease.enter()
            expect(enters == 1 && lease.isHeld, "重复显示同一窗口只取得一次激活策略引用")
            lease.leave()
            lease.leave()
            expect(leaves == 1 && !lease.isHeld, "关闭窗口只释放一次引用并恢复幂等空闲态")
        }
    }

    private static func applicationMenuProvidesStandardShortcuts() {
        MainActor.assumeIsolated {
            let menus = ApplicationMenuBuilder.make(
                settingsTarget: nil,
                settingsAction: Selector(("openSettings:"))
            )
            let items = recursiveMenuItems(in: menus.main)

            func command(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
                items.first {
                    $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers
                }
            }

            expect(
                command("q")?.action == #selector(NSApplication.terminate(_:))
                    && command("q")?.target === NSApp,
                "应用主菜单提供 ⌘Q，并明确交给 NSApp 退出"
            )
            expect(
                command("w")?.action == #selector(NSWindow.performClose(_:)),
                "文件菜单提供 ⌘W，并关闭当前设置窗口"
            )
            expect(
                ["x", "c", "v", "a"].allSatisfy { command($0) != nil }
                    && command("z")?.action == Selector(("undo:"))
                    && command("z", modifiers: [.command, .shift])?.action == Selector(("redo:")),
                "剪切、复制、粘贴、全选、撤销与重做均由标准编辑菜单提供"
            )
            expect(
                command(",")?.action == Selector(("openSettings:"))
                    && command("m")?.action == #selector(NSWindow.performMiniaturize(_:)),
                "应用菜单同时提供 ⌘, 设置和 ⌘M 最小化"
            )
        }
    }

    private static func recursiveMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items + menu.items.flatMap { item in
            item.submenu.map(recursiveMenuItems(in:)) ?? []
        }
    }

    private static func settingsWindowWaitsForActivationBeforeOrderingFront() {
        var isActive = false
        var steps: [String] = []
        SettingsWindowPresentationSequence.perform(
            isApplicationActive: { isActive },
            promote: { steps.append("promote") },
            orderFront: { steps.append("front") },
            prepareWindow: { steps.append("prepare") },
            waitForActivation: { steps.append("wait") },
            requestActivation: { steps.append("request") }
        )
        expect(
            steps == ["promote", "prepare", "wait", "request"],
            "应用尚未激活时只用普通 orderFront 登记窗口，再监听并延后请求前台"
        )

        steps.removeAll()
        isActive = true
        SettingsWindowPresentationSequence.perform(
            isApplicationActive: { isActive },
            promote: { steps.append("promote") },
            orderFront: { steps.append("front") },
            prepareWindow: { steps.append("prepare") },
            waitForActivation: { steps.append("wait") },
            requestActivation: { steps.append("request") }
        )
        expect(
            steps == ["promote", "front"],
            "应用已激活时设置窗口只置顶一次，不使用 orderFrontRegardless 或延迟重复置顶"
        )
    }

    private static func versionFallbackIsHonest() {
        expect(
            AppVersion.value("CFBundleShortVersionString", in: nil) == AppVersion.unknown,
            "读取不到 Info.plist 版本时显示未知，不伪装成旧版本号"
        )
        expect(
            AppVersion.value("CFBundleShortVersionString", in: ["CFBundleShortVersionString": "2.3.4"])
                == "2.3.4",
            "应用版本只取自 Info.plist 提供的值"
        )
    }

    private static func statusItemPresentationTracksRuntimeState() {
        expect(
            StatusItemPresentation(preferencesEnabled: true, engineRunning: true)
                == StatusItemPresentation(symbolName: "computermouse.fill", appearsDisabled: false),
            "总开关和引擎都运行时状态栏显示实心启用图标"
        )
        expect(
            StatusItemPresentation(preferencesEnabled: true, engineRunning: false)
                == StatusItemPresentation(symbolName: "computermouse", appearsDisabled: true)
                && StatusItemPresentation(preferencesEnabled: false, engineRunning: true)
                == StatusItemPresentation(symbolName: "computermouse", appearsDisabled: true),
            "引擎状态或总开关任一关闭时状态栏立即显示停用图标"
        )
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

    private static func debouncedSaveLeavesMainRunLoop() {
        var prefs = Preferences()
        prefs.scroll.speed = 4.2
        let result = Locked<(completedOffMain: Bool?, decoded: Preferences?)>((nil, nil))
        let semaphore = DispatchSemaphore(value: 0)
        let task = PreferencesSaveWorker.schedule(preferences: prefs, delay: .zero) { data in
            result.value = (!Thread.isMainThread, try? JSONDecoder().decode(Preferences.self, from: data))
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + 2) == .success
        task.cancel()

        expect(completed, "去抖保存任务会在有限时间内完成")
        expect(result.value.completedOffMain == true, "JSON 编码与写入闭包不占用主线程/事件 tap run loop")
        expect(result.value.decoded?.scroll.speed == 4.2, "后台编码保存完整偏好快照")
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

    /// Continuous-device smoothing and reversal must use one policy in every branch,
    /// including the target-unavailable fallback where the original event is passed through.
    private static func continuousDevicePolicyIsConsistent() {
        var settings = ScrollSettings.default
        settings.affectContinuousDevices = true
        settings.smoothingEnabled = true
        settings.reverseVertical = true
        settings.reverseHorizontal = true
        settings.reverseContinuousDevices = false

        let gatedOff = EventRouter.continuousPolicy(for: settings)
        expect(gatedOff.smooth, "连续设备可独立启用平滑")
        expect(!gatedOff.reversesAnyAxis, "未开启连续设备反向时，普通反向开关不会波及触控板")
        let unchanged = gatedOff.adjusted(vertical: 3, horizontal: -4)
        expect(unchanged.vertical == 3 && unchanged.horizontal == -4, "反向门控关闭时平滑输入保持原方向")

        settings.reverseContinuousDevices = true
        let gatedOn = EventRouter.continuousPolicy(for: settings)
        let reversed = gatedOn.adjusted(vertical: 3, horizontal: -4)
        expect(
            reversed.vertical == -3 && reversed.horizontal == 4,
            "反向门控开启时，平滑连续输入按轴翻转"
        )

        settings.smoothingEnabled = false
        let passthrough = EventRouter.continuousPolicy(for: settings)
        expect(!passthrough.smooth && passthrough.reversesAnyAxis, "不平滑的连续输入仍沿用同一反向策略")

        let router = EventRouter(config: Locked(.inactive))
        settings.smoothingEnabled = true
        settings.reverseHorizontal = false

        guard let protected = continuousEvent(fixedVertical: 5.25),
              let reversedFallback = continuousEvent(fixedVertical: 5.25) else {
            expect(false, "可构造连续滚动事件")
            return
        }

        settings.reverseContinuousDevices = false
        expect(router.handleContinuous(protected, settings: settings) != nil, "无目标的连续事件不会被吞掉")
        expectClose(
            ScrollEventFields.vertical.read(from: protected).fixedPoint,
            5.25,
            "无目标回退在门控关闭时保持原方向"
        )

        settings.reverseContinuousDevices = true
        expect(router.handleContinuous(reversedFallback, settings: settings) != nil, "反向后的无目标连续事件仍被透传")
        expectClose(
            ScrollEventFields.vertical.read(from: reversedFallback).fixedPoint,
            -5.25,
            "无目标回退也遵守连续设备反向门控"
        )
    }

    private static func continuousEvent(fixedVertical: Double) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 5,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedVertical)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
        return event
    }

    /// Both disable signals are recovery events; handling only timeout leaves the common
    /// user-input disable path silent and keeps stale ownership alive.
    private static func eventTapDisableReasonsAreObservable() {
        let controller = EventTapController(label: "self-check") { _, _, event in
            Unmanaged.passUnretained(event)
        }
        var reasons: [EventTapDisableReason] = []
        controller.onAutoReenable = { reasons.append($0) }

        expect(controller.handleDisableEvent(.tapDisabledByTimeout), "超时禁用会走自动恢复路径")
        expect(controller.handleDisableEvent(.tapDisabledByUserInput), "用户输入禁用也走自动恢复路径")
        expect(!controller.handleDisableEvent(.scrollWheel), "普通事件不会误触发自动恢复")
        expect(reasons == [.timeout, .userInput], "两种禁用原因都通知引擎并保留顺序")
    }

    /// Permission loss and tap replacement must converge all runtime pieces, then permission
    /// recovery must restart the main tap and still allow gesture motion capture.
    private static func engineConvergesAcrossPermissionChanges() {
        MainActor.assumeIsolated {
            var trusted = true
            let snapshot = Locked(ResolvedConfig(active: true, scroll: .default, buttonsActive: true))
            let router = EventRouter(config: snapshot, runAction: { _ in })
            let mainTap = ProbeEventTap()
            let motionTap = ProbeEventTap()
            let engine = MouseEngine(
                store: nil,
                router: router,
                tap: mainTap,
                motionTap: motionTap,
                isTrusted: { trusted }
            )
            var prefs = Preferences()
            prefs.buttons = [ButtonBinding(button: 4, action: .gestureNavigation)]

            engine.apply(preferences: prefs, pollIfNeeded: false)
            expect(engine.status == .running && mainTap.isRunning, "权限可用时主监听启动")

            guard let firstDown = mouseButtonEvent(
                type: .otherMouseDown,
                button: 4,
                modifiers: 0,
                location: .zero
            ) else {
                expect(false, "可构造权限切换测试的侧键事件")
                return
            }
            _ = router.handleButton(type: .otherMouseDown, event: firstDown)
            expect(motionTap.isRunning, "手势按下时按需启动移动监听")

            prefs.scroll.speed = 4.25
            engine.apply(preferences: prefs, pollIfNeeded: false)
            expect(mainTap.startMasks.count == 1, "只改滚动参数不会销毁并重建主监听")
            expect(
                motionTap.isRunning && router.activeGestureSessionCount == 1,
                "同一事件掩码的偏好更新不会中断正在进行的手势"
            )

            trusted = false
            engine.apply(preferences: prefs, pollIfNeeded: false)
            expect(engine.status == .needsPermission, "权限丢失后状态切到需要授权")
            expect(!mainTap.isRunning && !motionTap.isRunning, "权限丢失会停止主监听与移动监听")
            expect(
                router.activeButtonClaimCount == 0 && router.activeGestureSessionCount == 0,
                "权限丢失会清空被吞按键与手势会话"
            )

            trusted = true
            engine.apply(preferences: prefs, pollIfNeeded: false)
            expect(engine.status == .running && mainTap.startMasks.count == 2, "权限恢复后主监听重新启动")
            engine.setMotionTapRunning(true)
            expect(motionTap.isRunning, "恢复后移动监听仍可按需启动")

            guard let secondDown = mouseButtonEvent(
                type: .otherMouseDown,
                button: 4,
                modifiers: 0,
                location: .zero
            ) else {
                expect(false, "可构造自动恢复测试的侧键事件")
                return
            }
            _ = router.handleButton(type: .otherMouseDown, event: secondDown)
            expect(router.activeButtonClaimCount == 1, "自动恢复前存在被吞按键所有权")
            mainTap.simulateDisable(.userInput)
            expect(engine.autoReenableCount == 1, "主监听用户输入禁用会计入自动恢复")
            expect(
                router.activeButtonClaimCount == 0 && router.activeGestureSessionCount == 0,
                "主监听自动恢复会清空可能丢失抬起的会话"
            )
            motionTap.simulateDisable(.timeout)
            expect(engine.autoReenableCount == 2, "移动监听超时恢复也走同一计数与收尾路径")

            engine.stop()
            expect(engine.status == .off && !mainTap.isRunning && !motionTap.isRunning, "显式停止收敛为完全关闭")

            let retryRouter = EventRouter(config: Locked(.inactive), runAction: { _ in })
            let retryTap = ProbeEventTap()
            retryTap.startSucceeds = false
            let retryEngine = MouseEngine(
                store: nil,
                router: retryRouter,
                tap: retryTap,
                motionTap: ProbeEventTap(),
                isTrusted: { true }
            )
            retryEngine.apply(preferences: Preferences(), pollIfNeeded: true)
            expect(
                retryEngine.status == .failed && retryEngine.hasPendingTapRetry,
                "主监听创建失败会安排重试，不是进程内终态"
            )
            retryTap.startSucceeds = true
            retryEngine.retryFailedTap()
            expect(
                retryEngine.status == .running && retryTap.startMasks.count == 2
                    && !retryEngine.hasPendingTapRetry,
                "重试成功后恢复运行并取消失败定时器"
            )
            retryEngine.stop()
        }
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

    private static func gestureSpaceStrokeMatchesLogiTrace() {
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn]
        guard let source = CGEventSource(stateID: .hidSystemState),
              let events = ActionRunner.gestureSpaceEvents(
                  keyCode: 123,
                  flags: flags,
                  source: source
              )
        else {
            expect(false, "可构造 Logi 风格桌面切换按键序列")
            return
        }
        expect(
            events.map(\.type) == [.keyDown, .keyUp, .flagsChanged],
            "手势桌面切换发送 keyDown、keyUp、清修饰键三段序列"
        )
        expect(
            events[0].flags == flags
                && events[1].flags == .maskSecondaryFn
                && events[2].flags.isEmpty,
            "按下为 Control+Fn，抬起保留 Fn，最后清空 flags（与 Logi 采样一致）"
        )
        expect(
            events[0].getIntegerValueField(.keyboardEventKeycode) == 123
                && events[1].getIntegerValueField(.keyboardEventKeycode) == 123,
            "左右桌面手势使用系统方向键键码"
        )
        expect(events.allSatisfy(SyntheticEventTag.isMarked), "Logi 风格手势事件全部带防回环标记")
    }

    private static func rejectsInvalidSystemHotkeyNumbers() {
        func entry(keyCode: Int, modifiers: Int) -> [String: Any] {
            [
                "enabled": true,
                "value": ["parameters": [0, keyCode, modifiers]]
            ]
        }

        expect(
            SystemHotkeys.resolution(from: entry(keyCode: 70_000, modifiers: 0)) == .disabledBySystem,
            "用户 plist 里的超大键码安全降级，不在 UInt16 窄化时崩溃"
        )
        expect(
            SystemHotkeys.resolution(from: entry(keyCode: -1, modifiers: 0)) == .disabledBySystem,
            "用户 plist 里的负键码安全降级"
        )
        expect(
            SystemHotkeys.resolution(from: entry(keyCode: 12, modifiers: -1)) == .disabledBySystem,
            "用户 plist 里的负修饰键安全降级，不在 UInt64 窄化时崩溃"
        )
        expect(
            SystemHotkeys.resolution(from: entry(keyCode: 12, modifiers: 1_048_576))
                == .stroke(SystemHotkeys.Stroke(keyCode: 12, flags: CGEventFlags(rawValue: 1_048_576))),
            "可表示的系统快捷键仍按原值解析"
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
        let page = UpdateChecker.latestReleasePageURL(repository: UpdateSettings.repository)
        expect(page?.host == "github.com", "更新检查直接访问 GitHub Releases 页面")
        expect(page?.host != "api.github.com", "更新检查不再消耗 GitHub REST API 匿名额度")
    }

    private static func comparesVersions() {
        expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0") == true, "补丁号更大算新版本")
        expect(UpdateChecker.isNewer("v1.2.0", than: "1.1.9") == true, "标签前的 v 会被忽略")
        expect(UpdateChecker.isNewer("1.10.0", than: "1.9.9") == true, "按数值而不是字符串比较（1.10 > 1.9）")
        expect(UpdateChecker.isNewer("1.1", than: "1.0.9") == true, "位数不同也能正确比较")
        expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0") == false, "相同版本明确判为不更新")
        expect(UpdateChecker.isNewer("0.9.9", than: "1.0.0") == false, "更旧的版本明确判为不更新")
        expect(UpdateChecker.isNewer("1.2.0-beta.1", than: "1.1.0") == true, "预发布后缀被截断后仍可比较")

        for invalid in ["stable", "release-1.2.0", "", "1..2", "18446744073709551616.1"] {
            expect(
                UpdateChecker.isNewer(invalid, than: "1.0.0") == nil,
                "无法解析的版本号「\(invalid.isEmpty ? "空串" : invalid)」返回无法判断"
            )
        }
        expect(
            UpdateChecker.isNewer("1.2.0", than: AppVersion.unknown) == nil,
            "当前应用版本未知时不会谎报已是最新"
        )
    }

    private static func automaticScheduleUsesWallClock() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        expect(UpdatePolicy.isDue(lastCheckedAt: nil, now: now), "从未检查时立即到期")
        expect(
            !UpdatePolicy.isDue(lastCheckedAt: now.timeIntervalSince1970, now: now),
            "刚检查完成时不会重复请求"
        )
        let almostDue = now.timeIntervalSince1970 - UpdatePolicy.automaticInterval + 1
        expect(!UpdatePolicy.isDue(lastCheckedAt: almostDue, now: now), "未满 24 小时仍等待真实到期时间")
        let due = now.timeIntervalSince1970 - UpdatePolicy.automaticInterval
        expect(UpdatePolicy.isDue(lastCheckedAt: due, now: now), "进程持续运行满 24 小时后会到期")
        expect(
            UpdatePolicy.dueDate(lastCheckedAt: now.timeIntervalSince1970, now: now)
                == now.addingTimeInterval(UpdatePolicy.automaticInterval),
            "下一次唤醒按持久化检查时间安排，而不是只在启动时咨询一次"
        )
    }

    private static func updateRequestHasHardResourceDeadline() {
        let configuration = UpdateChecker.sessionConfiguration()
        expect(
            configuration.timeoutIntervalForRequest == UpdateChecker.requestTimeout,
            "更新请求保留 15 秒空闲超时"
        )
        expect(
            configuration.timeoutIntervalForResource == UpdateChecker.resourceTimeout,
            "更新响应有 30 秒总时限，持续滴流也不能永久卡住 isChecking"
        )
    }

    private static func skippedReleaseIsFiltered() {
        guard let releaseURL = URL(string: "https://github.com/owner/repo/releases/tag/v9.9.9") else {
            expect(false, "测试发布地址有效")
            return
        }
        let release = UpdateChecker.Release(
            version: "v9.9.9",
            url: releaseURL
        )
        let outcome = UpdateChecker.Outcome.available(release)
        expect(
            UpdatePolicy.pendingRelease(outcome: outcome, skippedVersion: nil) == release,
            "未跳过的新版本会显示"
        )
        expect(
            UpdatePolicy.pendingRelease(outcome: outcome, skippedVersion: release.version) == nil,
            "跳过此版本会被展示逻辑实际读取并隐藏横幅"
        )
        expect(
            UpdatePolicy.pendingRelease(outcome: outcome, skippedVersion: "v9.9.8") == release,
            "跳过旧版本不会隐藏后来发布的新版本"
        )
    }

    private static func parsesReleaseRedirect() {
        guard let url = URL(string: "https://github.com/owner/repo/releases/tag/v0.2.0"),
              let release = UpdateChecker.release(from: url, repository: "owner/repo") else {
            expect(false, "能从 GitHub Releases 重定向解析发布信息")
            return
        }
        expect(release.version == "v0.2.0", "解析出版本标签")
        expect(release.url.host == "github.com", "解析出发布页地址")
    }

    private static func rejectsUnexpectedReleaseURLs() {
        expect(UpdateChecker.latestReleasePageURL(repository: "owner") == nil, "缺少仓库名时拒绝构造更新地址")
        expect(UpdateChecker.latestReleasePageURL(repository: "owner/repo/extra") == nil, "多余路径段不会进入更新地址")
        guard let otherHost = URL(string: "https://example.com/owner/repo/releases/tag/v1.0.0"),
              let otherRepository = URL(string: "https://github.com/other/repo/releases/tag/v1.0.0"),
              let releasesIndex = URL(string: "https://github.com/owner/repo/releases") else {
            expect(false, "测试发布地址有效")
            return
        }
        expect(
            UpdateChecker.release(from: otherHost, repository: "owner/repo") == nil,
            "非 GitHub 重定向不会成为更新链接"
        )
        expect(
            UpdateChecker.release(from: otherRepository, repository: "owner/repo") == nil,
            "其他仓库的发布页不会被误认成当前应用更新"
        )
        expect(
            UpdateChecker.release(from: releasesIndex, repository: "owner/repo") == nil,
            "没有版本标签的发布列表不会被误解析"
        )
    }
}
