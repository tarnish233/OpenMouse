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
        }
        group("应用例外规则") {
            globalFallback()
            bypassRule()
            customRule()
            masterSwitchWins()
        }
        group("按键映射") {
            defaultAction()
            modifierVariant()
            inactiveDetection()
            dragDetection()
        }
        group("手势导航") {
            commitsDominantAxis()
            ignoresDiagonalDrift()
            firesOncePerHold()
            treatsStillHoldAsClick()
            mapsDirectionsLikeLogiOptions()
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
            survivesJSONRoundTrip()
        }
        group("Mos 手感对齐") {
            matchesMosFeel()
            travelFloorsThenScales()
            filterRemovesLeadingJump()
            filterConvergesAndDrains()
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

    private static func dragDetection() {
        expect(!EventRouter.needsDragEvents([]), "空配置不监听拖动事件")
        expect(
            !EventRouter.needsDragEvents([ButtonBinding(button: 2, action: .mute)]),
            "普通动作不需要拖动事件"
        )
        expect(
            EventRouter.needsDragEvents([ButtonBinding(button: 2, action: .dragScroll)]),
            "拖动滚动会让事件掩码加上拖动事件"
        )
    }

    // MARK: Gesture navigation

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
        let grouped = ActionKind.groups.flatMap(\.1)
        expect(Set(grouped) == Set(ActionKind.allCases), "选择器分组覆盖了所有动作")
        expect(grouped.count == ActionKind.allCases.count, "没有动作被分到两个组")
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
        expect(settings.repository.contains("/"), "默认更新源已配置，开箱即可检查更新")
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
