import AppKit
import CoreGraphics

/// Carries out the action bound to a mouse button.
///
/// Almost everything is expressed as a synthetic keystroke rather than a private API:
/// Mission Control, Spaces and navigation all have standard shortcuts, and posting keys
/// keeps the app free of anything that breaks on the next macOS release.
struct ActionRunner {
    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = ScrollEventPoster.Tag.magic
    }

    /// Virtual key codes we need. Values are the stable `kVK_*` constants from Carbon.
    private enum Key {
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let f11: UInt16 = 103
        static let bracketLeft: UInt16 = 33
        static let bracketRight: UInt16 = 30
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let w: UInt16 = 13
        static let t: UInt16 = 17
        static let q: UInt16 = 12
        static let minus: UInt16 = 27
        static let equal: UInt16 = 24
    }

    /// `NX_KEYTYPE_*` identifiers for the media/volume keys.
    private enum AuxKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
    }

    /// Actions are dispatched off the event-tap callback rather than executed inside it.
    /// Posting a synthetic keystroke re-enters the event pipeline, and a tap callback that
    /// takes too long gets disabled by the system — the deferral keeps both problems away.
    func runAsync(_ action: MouseAction) {
        DispatchQueue.main.async { self.run(action) }
    }

    func run(_ action: MouseAction) {
        switch action {
        case .passthrough, .dragScroll, .gestureNavigation:
            break
        case .missionControl:
            keyStroke(Key.upArrow, flags: .maskControl)
        case .applicationWindows:
            keyStroke(Key.downArrow, flags: .maskControl)
        case .showDesktop:
            keyStroke(Key.f11, flags: [])
        case .launchpad:
            openApp(at: "/System/Applications/Launchpad.app")
        case .spaceLeft:
            keyStroke(Key.leftArrow, flags: .maskControl)
        case .spaceRight:
            keyStroke(Key.rightArrow, flags: .maskControl)
        case .navigateBack:
            keyStroke(Key.bracketLeft, flags: .maskCommand)
        case .navigateForward:
            keyStroke(Key.bracketRight, flags: .maskCommand)
        case .zoomIn:
            keyStroke(Key.equal, flags: .maskCommand)
        case .zoomOut:
            keyStroke(Key.minus, flags: .maskCommand)
        case .copy:
            keyStroke(Key.c, flags: .maskCommand)
        case .paste:
            keyStroke(Key.v, flags: .maskCommand)
        case .closeTab:
            keyStroke(Key.w, flags: .maskCommand)
        case .newTab:
            keyStroke(Key.t, flags: .maskCommand)
        case .lockScreen:
            keyStroke(Key.q, flags: [.maskControl, .maskCommand])
        case .playPause:
            auxKeyStroke(.play)
        case .nextTrack:
            auxKeyStroke(.next)
        case .previousTrack:
            auxKeyStroke(.previous)
        case .volumeUp:
            auxKeyStroke(.soundUp)
        case .volumeDown:
            auxKeyStroke(.soundDown)
        case .mute:
            auxKeyStroke(.mute)
        case let .keyStroke(combo):
            keyStroke(combo.keyCode, flags: CGEventFlags(rawValue: combo.modifiers))
        case let .launchApp(path):
            openApp(at: path)
        }
    }

    // MARK: Primitives

    private func keyStroke(_ keyCode: UInt16, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: ScrollEventPoster.Tag.magic)
        up.setIntegerValueField(.eventSourceUserData, value: ScrollEventPoster.Tag.magic)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Media keys are not virtual key codes; they travel as `NSSystemDefined` events with
    /// the key identifier and press state packed into `data1`.
    private func auxKeyStroke(_ key: AuxKey) {
        for isDown in [true, false] {
            let state = isDown ? 0x0A : 0x0B
            let data1 = (Int(key.rawValue) << 16) | (state << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func openApp(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
