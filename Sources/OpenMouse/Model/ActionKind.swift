import Foundation

/// The picker-friendly face of `MouseAction`: a flat, `CaseIterable` list without the
/// associated values, plus the conversions back and forth.
enum ActionKind: String, CaseIterable, Identifiable {
    case passthrough
    case dragScroll
    case gestureNavigation
    case missionControl
    case applicationWindows
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
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
    case keyStroke
    case launchApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passthrough: "不改变（保持原样）"
        case .dragScroll: "按住拖动以滚动"
        case .gestureNavigation: "手势导航"
        case .missionControl: "调度中心"
        case .applicationWindows: "应用程序窗口"
        case .showDesktop: "显示桌面"
        case .launchpad: "启动台"
        case .spaceLeft: "切换到左边的桌面"
        case .spaceRight: "切换到右边的桌面"
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
        case .keyStroke: "自定义快捷键"
        case .launchApp: "打开应用"
        }
    }

    /// Ordered groups for the menu picker.
    static let groups: [(String, [ActionKind])] = [
        ("基本", [.passthrough, .gestureNavigation, .dragScroll]),
        ("窗口与桌面", [.missionControl, .applicationWindows, .showDesktop, .launchpad, .spaceLeft, .spaceRight]),
        ("浏览与编辑", [.navigateBack, .navigateForward, .newTab, .closeTab, .copy, .paste, .zoomIn, .zoomOut]),
        ("媒体", [.playPause, .previousTrack, .nextTrack, .volumeDown, .volumeUp, .mute]),
        ("系统", [.lockScreen]),
        ("自定义", [.keyStroke, .launchApp])
    ]

    init(_ action: MouseAction) {
        switch action {
        case .passthrough: self = .passthrough
        case .dragScroll: self = .dragScroll
        case .gestureNavigation: self = .gestureNavigation
        case .missionControl: self = .missionControl
        case .applicationWindows: self = .applicationWindows
        case .showDesktop: self = .showDesktop
        case .launchpad: self = .launchpad
        case .spaceLeft: self = .spaceLeft
        case .spaceRight: self = .spaceRight
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
        case .keyStroke: self = .keyStroke
        case .launchApp: self = .launchApp
        }
    }

    /// Build the concrete action, keeping any payload the user already configured so
    /// switching away and back does not lose a recorded shortcut.
    func makeAction(preserving current: MouseAction) -> MouseAction {
        switch self {
        case .passthrough: .passthrough
        case .dragScroll: .dragScroll
        case .gestureNavigation: .gestureNavigation
        case .missionControl: .missionControl
        case .applicationWindows: .applicationWindows
        case .showDesktop: .showDesktop
        case .launchpad: .launchpad
        case .spaceLeft: .spaceLeft
        case .spaceRight: .spaceRight
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
        case .keyStroke:
            if case .keyStroke = current { current } else { .keyStroke(KeyCombo(keyCode: 0, modifiers: 0)) }
        case .launchApp:
            if case .launchApp = current { current } else { .launchApp(path: "") }
        }
    }
}
