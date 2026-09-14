import Foundation

/// Every user-visible string lives here so the app can be localised later by swapping one
/// file instead of hunting through views.
enum Strings {
    static let appName = "Open Mouse"

    // Menu bar
    static let menuEnabled = "启用 Open Mouse"
    static let menuSmoothing = "平滑滚动"
    static let menuReverse = "反转滚动方向"
    static let menuSettings = "设置…"
    static let menuQuit = "退出"
    static let menuAbout = "关于 Open Mouse"
    static let menuServices = "服务"
    static let menuHideApp = "隐藏 Open Mouse"
    static let menuHideOthers = "隐藏其他"
    static let menuShowAll = "全部显示"
    static let menuQuitApp = "退出 Open Mouse"
    static let menuFile = "文件"
    static let menuCloseWindow = "关闭窗口"
    static let menuEdit = "编辑"
    static let menuUndo = "撤销"
    static let menuRedo = "重做"
    static let menuCut = "剪切"
    static let menuCopy = "复制"
    static let menuPaste = "粘贴"
    static let menuSelectAll = "全选"
    static let menuWindow = "窗口"
    static let menuMinimize = "最小化"
    static let menuZoom = "缩放"
    static let menuBringAllToFront = "前置全部窗口"
    static func menuExcludeApp(_ name: String) -> String { "在「\(name)」中停用" }
    static func menuIncludeApp(_ name: String) -> String { "在「\(name)」中恢复启用" }

    static let statusRunning = "运行中"
    static let statusOff = "已停用"
    static let statusNeedsPermission = "需要「辅助功能」权限"
    static let statusFailed = "无法创建事件监听"

    // Window / tabs
    static let settingsTitle = "Open Mouse 设置"
    static let settingsSave = "保存"
    static let settingsUnsavedTitle = "要保存对设置的更改吗？"
    static let settingsUnsavedMessage = "当前有尚未保存的修改。选择“不保存”会恢复上次保存的配置；选择“取消”可继续编辑。"
    static let settingsDontSave = "不保存"
    static let settingsLeaveCancel = "取消"
    static let settingsSaved = "已保存"
    static let settingsSaveHelp = "改动已经在生效，可以先体验。点击保存才会写入配置；离开页面或关闭窗口时会提示保存。"
    static let settingsSavedHelp = "没有未保存的改动。"
    static let settingsRevert = "撤销"
    static let settingsRevertHelp = "放弃全部未保存的改动，立刻回到上次保存的状态。不是逐步撤销。"
    static let tabScroll = "滚动"
    static let tabPointer = "指针"
    static let tabButtons = "按键"
    static let tabApps = "应用"
    static let tabGeneral = "通用"

    // Permission banner
    static let permissionTitle = "需要「辅助功能」权限"
    static let permissionBody = "Open Mouse 需要在「系统设置 › 隐私与安全性 › 辅助功能」中被允许，才能拦截并改写滚轮与按键事件。"
    static let permissionOpen = "打开系统设置"
    static let permissionRecheck = "重新检查"

    // Conflict banner
    static let conflictTitle = "检测到其他鼠标增强软件"
    static func conflictBody(_ names: [String]) -> String {
        let list = names.joined(separator: "、")
        return "\(list) 也在拦截滚轮事件。两个平滑引擎会互相争抢：谁最后注册事件监听，谁就排在链条前面，"
            + "另一个会把它合成出来的事件当成触控板输入。表现出来就像是随机失灵。建议只保留一个。"
    }

    // Scroll pane
    static let scrollSectionBasics = "基础"
    static let scrollEnableSmoothing = "平滑滚动"
    static let scrollEnableSmoothingHelp = "把滚轮的一格一格跳动，插值成逐帧的像素级滚动。"
    static let scrollReverseVertical = "反转垂直方向"
    static let scrollReverseHorizontal = "反转水平方向"
    static let scrollSectionFeel = "手感"
    static let scrollMinimumStep = "最短步长"
    static let scrollSpeed = "速度增益"
    static let scrollSmoothness = "平滑度"
    static let scrollAcceleration = "加速度"
    static let scrollSectionTrackpad = "触控板与 Magic Mouse"
    static let scrollReverseTrackpad = "反转方向"
    static let scrollSmoothTrackpad = "平滑处理"
    static let scrollSectionAdvanced = "高级"
    static let scrollEmitPhases = "发送滚动阶段事件"
    static let scrollEmitPhasesHelp = "让部分应用能做出边界回弹效果；若出现滚动异常请关闭。"
    static let scrollPresets = "预设"
    static let presetDefault = "默认"
    static let presetSmooth = "顺滑"
    static let presetCrisp = "干脆"
    static let resetScroll = "恢复默认"
    static let scrollTryButton = "试一试"
    static let scrollTryButtonHelp = "对比系统原始与 Open Mouse 的滚动手感"
    static let scrollComparisonTitle = "滚动手感对比"
    static let scrollComparisonIntro = "把指针移到任意一侧，用鼠标滚轮上下滚动，直接比较两种手感。"
    static let scrollComparisonSystemTitle = "Open Mouse 未开启"
    static let scrollComparisonSystemSubtitle = "系统原始滚动"
    static let scrollComparisonOpenMouseTitle = "Open Mouse 已开启"
    static let scrollComparisonOpenMouseFormat = "当前参数：%.0f px · %.2f× · %.0f%%"
    static let scrollComparisonUnavailableTitle = "Open Mouse 暂不可用"
    static let scrollComparisonUnavailableSubtitle = "需要“辅助功能”权限"
    static let scrollComparisonUnavailableOverlay = "授权并重新检查后即可体验"
    static let scrollComparisonHover = "移入体验"
    static let scrollComparisonActive = "正在体验"
    static let scrollComparisonPermissionHelp = "左侧仍可使用；授权后右侧才能展示 Open Mouse 的平滑效果。"

    // Buttons pane
    static let buttonsSectionTitle = "鼠标按键"
    static let buttonsIntro = "按下鼠标上的按键来录入，再为它选择动作。左键与右键不会被接管。录入时可以同时按住修饰键，"
        + "为同一个按键配出不同组合，例如侧键 4 = 后退，⌘ + 侧键 4 = 调度中心。"
    static let buttonsEmptyTitle = "还没有录入任何按键"
    static let buttonsEmptyBody = "不预设按键列表——不同鼠标能报出的按键并不一样。按一下你想用的键，它就会出现在这里。"
    static let buttonsRecord = "录入按键"
    static let buttonsRemove = "删除这条映射"
    static let buttonNoAppChosen = "尚未选择应用"
    static func buttonName(_ number: Int) -> String {
        switch number {
        case 2: return "中键"
        case 3: return "侧键 4"
        case 4: return "侧键 5"
        case LogitechHIDPPProtocol.dpiSwitchButton: return "DPI 键"
        default: return "按键 \(number + 1)"
        }
    }
    static let buttonRecordShortcut = "未设置（点击录制）"
    static let buttonRecording = "请按下快捷键…"
    static let buttonChooseApp = "选择应用…"
    static func dpiValue(_ value: Int) -> String { "\(value) DPI" }
    static func dpiCurrentValue(_ value: Int) -> String { "当前 \(value) DPI" }
    static func dpiCurrentHelp(_ value: Int) -> String { "当前鼠标正在使用 \(value) DPI" }
    static let dpiChangeHelp = "点击修改 DPI"
    static let dpiCurrentAccessibilityValue = "当前使用"
    static let dpiInactiveAccessibilityValue = "未使用"

    // Pointer pane
    static let pointerSectionTitle = "指针速度"
    static let pointerIntro = "逐个设备调整指针速度，任何品牌的鼠标都适用，不依赖厂商驱动。"
        + "勾选要接管的设备——列表里也会出现键盘和虚拟设备，系统没有可靠的办法把它们区分开，所以由你来选。"
    static let pointerCurveNote = "这里调的是加速曲线，不是硬件 DPI：快速甩动被放大的比例比慢速微调更大。"
        + "在「系统设置 › 鼠标 › 跟踪速度」拖动后，系统会覆盖这里的值，重新插拔设备或改动本页会再次生效。"
    static let pointerMultiModeNote = "三模鼠标在有线和无线下会被系统报成两台不同的设备（名称与 ID 都不一样），因此会占两行。"
        + "想让它换连接方式后手感不变，把两行都勾上——勾一次就会一直记住。"
    static func pointerTransportLabel(_ transport: PointerTransport) -> String? {
        switch transport {
        case .usb: "有线"
        case .bluetooth: "蓝牙"
        case .other: nil
        }
    }
    static let pointerEmpty = "没有找到可调整的指针设备"
    static let pointerEmptyBody = "连接一只鼠标后它会出现在这里。触控板不在此列——它已经是像素级连续输入。"
    static let pointerRestoreDefaults = "全部恢复系统默认"
    static let pointerRestoreDefaultsHelp = "取消所有勾选，并把当前连接的每只鼠标都写回系统跟踪速度。"
        + "上次退出时如果没能正常恢复，用这个兜底。"
    static let pointerUnnamedDevice = "未命名设备"
    static let pointerValueTitle = "速度"
    static let pointerStateApplied = "已生效"
    static let pointerStateOffline = "设备未连接"
    static let pointerStateOfflineHelp = "这条设置仍然保留，设备接回来就会自动重新生效。"
    static let pointerStateUnsupported = "设备不支持"
    static let pointerStateUnsupportedHelp = "系统没有为它提供可读写的指针加速属性。macOS 正在逐步移除这套属性，"
        + "触控板和部分设备已经不再支持。"
    static let pointerStateRejected = "系统拒绝了设置"
    static let pointerStateRejectedHelp = "写入被系统拒绝，或者写入成功但读回的值不对。日志 category 为 pointer。"
    static func pointerDeviceIdentity(_ vendorID: Int, _ productID: Int) -> String {
        String(format: "0x%04X / 0x%04X", vendorID, productID)
    }
    static func pointerValue(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
    static func pointerSystemDefaultHint(_ value: Double) -> String {
        "系统默认 \(pointerValue(value))"
    }

    // Recorder sheet
    static let recorderTitle = "录入鼠标按键"
    static let recorderHint = "请在鼠标上按下要设置的按键。\n可以同时按住 ⌃⌥⇧⌘ 来录入组合。"
    static let recorderCaptured = "已录入"
    static let recorderConfirm = "使用这个按键"
    static let recorderCancel = "取消"

    // Apps pane
    static let appsIntro = "为特定应用停用 Open Mouse，或使用独立的滚动参数。"
    static let appsAdd = "添加应用…"
    static let appsRemove = "移除"
    static let appsEmpty = "还没有任何例外规则"
    static let appsModeBypass = "完全不干预"
    static let appsModeCustom = "使用独立参数"
    static let appsBypassButtons = "该应用内不改写按键"

    // General pane
    static let generalLaunchAtLogin = "登录时启动"
    static let generalMenuBarIcon = "在菜单栏显示图标"
    static let generalRevealConfig = "显示配置文件"
    static let generalResetAll = "恢复全部默认设置"
    static let generalQuit = "退出 Open Mouse"
    static let generalAbout = "关于"
    static func generalVersion(_ version: String) -> String { "版本 \(version)" }
    static let generalCredits = "参考 Mos 与 logiops 的思路实现，纯 CGEventTap，无内核扩展。默认手感对齐 Mos。"

    // Updates
    static let updateSection = "更新"
    static let updateAuto = "自动检查更新"
    static let updateAutoHelp = "每天最多检查一次，直接读取 GitHub Releases。下载的新版本必须由当前版本的同一签名身份签发才会安装。"
    static let updateCheckNow = "立即检查"
    static let updateChecking = "正在检查…"
    static let updateNotConfigured = "未配置更新源"
    static func updateUpToDate(_ version: String) -> String { "已是最新版本（\(version)）" }
    static func updateAvailable(_ version: String) -> String { "有新版本：\(version)" }
    static let updateInstall = "下载并安装"
    static func updateDownloading(_ version: String) -> String { "正在下载 \(version)…" }
    static func updateInstalling(_ version: String) -> String { "正在安装 \(version)，随后会自动重启…" }
    static func updateInstalled(_ version: String) -> String { "已更新到 \(version)" }
    static let updateInstallRetry = "重试安装"
    static let updateOpen = "查看发布页"
    static let updateDownloadManually = "手动下载"
    static let updateSkip = "跳过此版本"
    static func updateSkipped(_ version: String) -> String { "已跳过 \(version)" }
    static let updateUnskip = "取消跳过"
    static let updateQuitRefused = "Open Mouse 没有退出，更新未安装。请手动退出后重试。"
    static func updateLastChecked(_ text: String) -> String { "上次检查：\(text)" }
}
