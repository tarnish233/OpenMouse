import Foundation

/// The picker-friendly face of `MouseAction`: a flat, `CaseIterable` list without the
/// associated values, plus the conversions back and forth.
enum ActionKind: String, CaseIterable, Identifiable {
    case passthrough
    case gestureNavigation
    case missionControl
    case applicationWindows
    case showDesktop
    case spaceLeft
    case spaceRight
    case cycleWindows
    case appBrowser
    case controlCenter
    case spotlight
    case screenshotSelection
    case screenshotOptions
    case toggleDock
    case nextInputSource
    case quickNote
    case navigateBack
    case navigateForward
    case newTab
    case closeTab
    case copy
    case paste
    case zoomIn
    case zoomOut
    case playPause
    case previousTrack
    case nextTrack
    case volumeDown
    case volumeUp
    case mute
    case lockScreen
    case escapeKey
    case switchApp
    case switchAppReverse
    case minimizeWindow
    case hideApplication
    case hideOthers
    case closeAllWindows
    case quitApp
    case cut
    case undo
    case redo
    case selectAll
    case find
    case nextTab
    case previousTab
    case newFinderWindow
    case newFolder
    case moveToTrash
    case emptyTrash
    case duplicateFile
    case getInfo
    case goToFolder
    case viewAsIcons
    case viewAsList
    case viewAsColumns
    case viewAsGallery
    case screenshotToFile
    case characterViewer
    case forceQuit
    case logout
    case invertColors
    case keyStroke
    case launchApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passthrough: "不改变（保持原样）"
        case .gestureNavigation: "手势导航"
        case .missionControl: "调度中心"
        case .applicationWindows: "应用程序窗口"
        case .showDesktop: "显示桌面"
        case .spaceLeft: "切换到左边的桌面"
        case .spaceRight: "切换到右边的桌面"
        case .cycleWindows: "循环切换当前应用的窗口"
        case .appBrowser: "启动台"
        case .controlCenter: "控制中心"
        case .spotlight: "聚焦搜索"
        case .screenshotSelection: "截屏（选区）"
        case .screenshotOptions: "截屏与录屏"
        case .toggleDock: "显示 / 隐藏 Dock"
        case .nextInputSource: "切换输入法"
        case .quickNote: "快速备忘录"
        case .navigateBack: "后退"
        case .navigateForward: "前进"
        case .newTab: "新建标签页"
        case .closeTab: "关闭标签页"
        case .copy: "复制"
        case .paste: "粘贴"
        case .zoomIn: "放大"
        case .zoomOut: "缩小"
        case .playPause: "播放 / 暂停"
        case .previousTrack: "上一曲"
        case .nextTrack: "下一曲"
        case .volumeDown: "降低音量"
        case .volumeUp: "提高音量"
        case .mute: "静音"
        case .lockScreen: "锁定屏幕"
        case .escapeKey: "Esc"
        case .switchApp: "切换应用（⌘⇥）"
        case .switchAppReverse: "反向切换应用"
        case .minimizeWindow: "最小化窗口"
        case .hideApplication: "隐藏当前应用"
        case .hideOthers: "隐藏其他应用"
        case .closeAllWindows: "关闭全部窗口"
        case .quitApp: "退出当前应用"
        case .cut: "剪切"
        case .undo: "撤销"
        case .redo: "重做"
        case .selectAll: "全选"
        case .find: "查找"
        case .nextTab: "下一个标签页"
        case .previousTab: "上一个标签页"
        case .newFinderWindow: "新建 Finder 窗口"
        case .newFolder: "新建文件夹"
        case .moveToTrash: "移到废纸篓"
        case .emptyTrash: "清倒废纸篓"
        case .duplicateFile: "复制文件（⌘D）"
        case .getInfo: "显示简介"
        case .goToFolder: "前往文件夹"
        case .viewAsIcons: "以图标显示"
        case .viewAsList: "以列表显示"
        case .viewAsColumns: "以分栏显示"
        case .viewAsGallery: "以画廊显示"
        case .screenshotToFile: "截屏（全屏）"
        case .characterViewer: "表情与符号"
        case .forceQuit: "强制退出窗口"
        case .logout: "退出登录"
        case .invertColors: "反转颜色"
        case .keyStroke: "自定义快捷键"
        case .launchApp: "打开应用"
        }
    }

    /// Actions shown at the top level of the picker, above the submenus.
    ///
    /// "Leave it alone" is one click away rather than buried in a submenu, because it is both
    /// the default and the thing you reach for to undo a mapping.
    static let ungrouped: [ActionKind] = [.passthrough]

    /// Ordered groups for the menu picker.
    static let groups: [(String, [ActionKind])] = [
        ("窗口与桌面", [.gestureNavigation, .missionControl, .applicationWindows, .showDesktop,
                   .spaceLeft, .spaceRight, .cycleWindows, .appBrowser, .toggleDock,
                   .switchApp, .switchAppReverse, .minimizeWindow, .hideApplication, .hideOthers, .closeAllWindows, .quitApp]),
        ("浏览与编辑", [.navigateBack, .navigateForward, .newTab, .closeTab, .copy, .paste,
                   .zoomIn, .zoomOut, .cut, .undo, .redo, .selectAll, .find, .nextTab, .previousTab]),
        ("文件", [.newFinderWindow, .newFolder, .moveToTrash, .emptyTrash, .duplicateFile, .getInfo, .goToFolder, .viewAsIcons, .viewAsList, .viewAsColumns, .viewAsGallery]),
        ("媒体", [.playPause, .previousTrack, .nextTrack, .volumeDown, .volumeUp, .mute]),
        ("系统", [.spotlight, .controlCenter, .screenshotSelection, .screenshotOptions,
                .nextInputSource, .quickNote, .lockScreen,
                .escapeKey, .screenshotToFile, .characterViewer, .forceQuit, .logout, .invertColors]),
        ("自定义", [.keyStroke, .launchApp])
    ]

    init(_ action: MouseAction) {
        switch action {
        case .passthrough: self = .passthrough
        case .gestureNavigation: self = .gestureNavigation
        case .missionControl: self = .missionControl
        case .applicationWindows: self = .applicationWindows
        case .showDesktop: self = .showDesktop
        case .spaceLeft: self = .spaceLeft
        case .spaceRight: self = .spaceRight
        case .cycleWindows: self = .cycleWindows
        case .appBrowser: self = .appBrowser
        case .controlCenter: self = .controlCenter
        case .spotlight: self = .spotlight
        case .screenshotSelection: self = .screenshotSelection
        case .screenshotOptions: self = .screenshotOptions
        case .toggleDock: self = .toggleDock
        case .nextInputSource: self = .nextInputSource
        case .quickNote: self = .quickNote
        case .navigateBack: self = .navigateBack
        case .navigateForward: self = .navigateForward
        case .newTab: self = .newTab
        case .closeTab: self = .closeTab
        case .copy: self = .copy
        case .paste: self = .paste
        case .zoomIn: self = .zoomIn
        case .zoomOut: self = .zoomOut
        case .playPause: self = .playPause
        case .previousTrack: self = .previousTrack
        case .nextTrack: self = .nextTrack
        case .volumeDown: self = .volumeDown
        case .volumeUp: self = .volumeUp
        case .mute: self = .mute
        case .lockScreen: self = .lockScreen
        case .escapeKey: self = .escapeKey
        case .switchApp: self = .switchApp
        case .switchAppReverse: self = .switchAppReverse
        case .minimizeWindow: self = .minimizeWindow
        case .hideApplication: self = .hideApplication
        case .hideOthers: self = .hideOthers
        case .closeAllWindows: self = .closeAllWindows
        case .quitApp: self = .quitApp
        case .cut: self = .cut
        case .undo: self = .undo
        case .redo: self = .redo
        case .selectAll: self = .selectAll
        case .find: self = .find
        case .nextTab: self = .nextTab
        case .previousTab: self = .previousTab
        case .newFinderWindow: self = .newFinderWindow
        case .newFolder: self = .newFolder
        case .moveToTrash: self = .moveToTrash
        case .emptyTrash: self = .emptyTrash
        case .duplicateFile: self = .duplicateFile
        case .getInfo: self = .getInfo
        case .goToFolder: self = .goToFolder
        case .viewAsIcons: self = .viewAsIcons
        case .viewAsList: self = .viewAsList
        case .viewAsColumns: self = .viewAsColumns
        case .viewAsGallery: self = .viewAsGallery
        case .screenshotToFile: self = .screenshotToFile
        case .characterViewer: self = .characterViewer
        case .forceQuit: self = .forceQuit
        case .logout: self = .logout
        case .invertColors: self = .invertColors
        case .keyStroke: self = .keyStroke
        case .launchApp: self = .launchApp
        }
    }

    /// Build the concrete action, keeping any payload the user already configured so
    /// switching away and back does not lose a recorded shortcut.
    func makeAction(preserving current: MouseAction) -> MouseAction {
        switch self {
        case .passthrough: .passthrough
        case .gestureNavigation: .gestureNavigation
        case .missionControl: .missionControl
        case .applicationWindows: .applicationWindows
        case .showDesktop: .showDesktop
        case .spaceLeft: .spaceLeft
        case .spaceRight: .spaceRight
        case .cycleWindows: .cycleWindows
        case .appBrowser: .appBrowser
        case .controlCenter: .controlCenter
        case .spotlight: .spotlight
        case .screenshotSelection: .screenshotSelection
        case .screenshotOptions: .screenshotOptions
        case .toggleDock: .toggleDock
        case .nextInputSource: .nextInputSource
        case .quickNote: .quickNote
        case .navigateBack: .navigateBack
        case .navigateForward: .navigateForward
        case .newTab: .newTab
        case .closeTab: .closeTab
        case .copy: .copy
        case .paste: .paste
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .playPause: .playPause
        case .previousTrack: .previousTrack
        case .nextTrack: .nextTrack
        case .volumeDown: .volumeDown
        case .volumeUp: .volumeUp
        case .mute: .mute
        case .lockScreen: .lockScreen
        case .escapeKey: .escapeKey
        case .switchApp: .switchApp
        case .switchAppReverse: .switchAppReverse
        case .minimizeWindow: .minimizeWindow
        case .hideApplication: .hideApplication
        case .hideOthers: .hideOthers
        case .closeAllWindows: .closeAllWindows
        case .quitApp: .quitApp
        case .cut: .cut
        case .undo: .undo
        case .redo: .redo
        case .selectAll: .selectAll
        case .find: .find
        case .nextTab: .nextTab
        case .previousTab: .previousTab
        case .newFinderWindow: .newFinderWindow
        case .newFolder: .newFolder
        case .moveToTrash: .moveToTrash
        case .emptyTrash: .emptyTrash
        case .duplicateFile: .duplicateFile
        case .getInfo: .getInfo
        case .goToFolder: .goToFolder
        case .viewAsIcons: .viewAsIcons
        case .viewAsList: .viewAsList
        case .viewAsColumns: .viewAsColumns
        case .viewAsGallery: .viewAsGallery
        case .screenshotToFile: .screenshotToFile
        case .characterViewer: .characterViewer
        case .forceQuit: .forceQuit
        case .logout: .logout
        case .invertColors: .invertColors
        case .keyStroke:
            if case .keyStroke = current { current } else { .keyStroke(KeyCombo(keyCode: 0, modifiers: 0)) }
        case .launchApp:
            if case .launchApp = current { current } else { .launchApp(path: "") }
        }
    }
}
