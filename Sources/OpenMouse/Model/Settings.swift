import CoreGraphics
import Foundation

/// A dynamic key lets the decoder inspect an enum discriminator without rejecting names
/// written by a newer build. Unknown actions are deliberately handled as data, not errors.
private struct SettingsCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Keeps an invalid element from making `JSONDecoder` discard an otherwise valid array.
private struct LossyDecoded<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Scroll

/// Everything that shapes how a wheel notch turns into on-screen movement.
///
/// The defaults, the parameter split and the pipeline are all matched to Mos, because that
/// is the feel most users arrive with. Concretely, per scroll event Mos computes
/// `max(|rawDelta|, minimumStep) × speed` — where `rawDelta` prefers the OS-computed *pixel*
/// delta, so travel grows on its own when you spin the wheel fast — and then eases the
/// result out with a per-frame fraction of `1 − √(duration ÷ 5.2) ≈ 0.085`, which is this
/// app's `rate`, i.e. `1 − smoothness`.
struct ScrollSettings: Codable, Equatable, Sendable {
    /// Upper bound on smoothness. Above this the glide is longer than anyone wants and the
    /// tail takes hundreds of frames to settle.
    static let maxSmoothness: Double = 0.98

    /// Master switch for the interpolated (smooth) scrolling engine.
    var smoothingEnabled = true
    /// Flip the vertical axis. This is the "natural scrolling for mice only" knob.
    var reverseVertical = false
    /// Flip the horizontal axis (tilt wheel / thumb wheel).
    var reverseHorizontal = false
    /// Floor on the travel one scroll event contributes, in pixels. Anything the OS reports
    /// smaller than this is lifted up to it, which is what makes a single slow notch move a
    /// useful distance. Mos calls this 最短步长; its default is 33.6.
    var minimumStep: Double = 33.6
    /// Gain applied to the (floored) raw delta. Mos calls this 速度增益; default 2.70.
    /// Because the raw delta is the OS pixel delta, fast scrolling scales up by itself.
    var speed: Double = 2.70
    /// 0 = snap instantly, 0.98 = very floaty. Drives the per-frame easing rate.
    /// 0.915 is Mos's default interpolation fraction expressed on this scale.
    var smoothness: Double = 0.915
    /// >1 amplifies fast consecutive notches, like a physical flywheel. Mos has no
    /// time-based acceleration (it boosts on a held modifier instead), so this is off.
    var acceleration: Double = 1.0
    /// Treat continuous devices (trackpad, Magic Mouse) as if they were wheels.
    /// Off by default: they are already smooth, and touching them breaks gestures.
    var affectContinuousDevices = false
    /// Reverse continuous devices too. Independent of `affectContinuousDevices`
    /// because reversing a trackpad is cheap and safe, smoothing it is not.
    var reverseContinuousDevices = false
    /// Emit begin/changed/end scroll phases so apps can rubber-band.
    /// Some apps double-handle phases, so this stays opt-in.
    var emitScrollPhases = false

    /// Mos-matched feel. Also the app default.
    static let `default` = ScrollSettings()
    /// Longer, floatier glide.
    static let smooth = ScrollSettings(minimumStep: 40, speed: 3.2, smoothness: 0.95)
    /// Close to a raw wheel: short travel, quick settle.
    static let crisp = ScrollSettings(minimumStep: 28, speed: 2.0, smoothness: 0.8)

    /// Travel contributed by one scroll event whose raw pixel delta was `rawDelta`.
    /// Mirrors Mos: floor the magnitude at `minimumStep`, then apply the gain.
    func travel(forRawDelta rawDelta: Double) -> Double {
        guard rawDelta.isFinite, rawDelta != 0,
              minimumStep.isFinite, speed.isFinite else { return 0 }
        let floored = max(abs(rawDelta), minimumStep)
        let travel = (rawDelta < 0 ? -floored : floored) * speed
        return travel.isFinite ? travel : 0
    }

    var clamped: ScrollSettings {
        var copy = self
        copy.minimumStep = min(max(minimumStep, 1), 200)
        copy.speed = min(max(speed, 0.1), 10)
        copy.smoothness = min(max(smoothness, 0), Self.maxSmoothness)
        copy.acceleration = min(max(acceleration, 1), 6)
        return copy
    }

    init() {}

    /// Every field falls back to its default independently. The synthesised decoder is
    /// all-or-nothing: one missing key throws and the caller loses the whole section, which
    /// would mean a new field in a future version silently resets everyone's scroll feel.
    /// It also makes the file safe to hand-edit with only the keys you care about.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ScrollSettings()
        smoothingEnabled = (try? c.decode(Bool.self, forKey: .smoothingEnabled)) ?? fallback.smoothingEnabled
        reverseVertical = (try? c.decode(Bool.self, forKey: .reverseVertical)) ?? fallback.reverseVertical
        reverseHorizontal = (try? c.decode(Bool.self, forKey: .reverseHorizontal)) ?? fallback.reverseHorizontal
        minimumStep = (try? c.decode(Double.self, forKey: .minimumStep)) ?? fallback.minimumStep
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? fallback.speed
        smoothness = (try? c.decode(Double.self, forKey: .smoothness)) ?? fallback.smoothness
        acceleration = (try? c.decode(Double.self, forKey: .acceleration)) ?? fallback.acceleration
        affectContinuousDevices = (try? c.decode(Bool.self, forKey: .affectContinuousDevices))
            ?? fallback.affectContinuousDevices
        reverseContinuousDevices = (try? c.decode(Bool.self, forKey: .reverseContinuousDevices))
            ?? fallback.reverseContinuousDevices
        emitScrollPhases = (try? c.decode(Bool.self, forKey: .emitScrollPhases)) ?? fallback.emitScrollPhases
    }

    /// Memberwise-style initialiser, needed because declaring `init(from:)` suppresses the
    /// synthesised one. Only the fields the presets vary are exposed.
    init(minimumStep: Double, speed: Double, smoothness: Double) {
        self.minimumStep = minimumStep
        self.speed = speed
        self.smoothness = smoothness
    }
}

// MARK: - Buttons

/// A recorded keyboard shortcut: virtual key code plus modifier mask.
struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    /// Keyboard modifiers that can be recorded and replayed. Fn is essential for macOS window
    /// management shortcuts; dropping it produces a plausible-looking shortcut that the system
    /// silently ignores.
    static let modifierMask = CGEventFlags([
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn
    ]).rawValue

    var keyCode: UInt16
    /// Raw value of `CGEventFlags` restricted to the modifier bits.
    var modifiers: UInt64

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Decode each field independently so adding a field to a future shortcut does not turn
    /// every shortcut written by an older build into `.passthrough`.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(keyCode: 0, modifiers: 0)
            return
        }
        self.init(
            keyCode: (try? c.decode(UInt16.self, forKey: .keyCode)) ?? 0,
            modifiers: (try? c.decode(UInt64.self, forKey: .modifiers)) ?? 0
        )
    }
}

/// What a physical mouse button should do when pressed.
enum MouseAction: Codable, Equatable, Hashable, Sendable {
    /// Leave the event alone.
    case passthrough
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
    case zoomIn
    case zoomOut
    case copy
    case paste
    case closeTab
    case newTab
    case lockScreen
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute
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
    case keyStroke(KeyCombo)
    case launchApp(path: String)
    /// Hold this button and flick a direction to navigate: up = Mission Control,
    /// down = App Exposé, left/right = switch desktop. A click without moving opens
    /// Mission Control. Mirrors the Logi Options+ gesture button.
    case gestureNavigation

    private enum PayloadCodingKeys: String, CodingKey {
        case _0
        case path
    }

    /// Swift's synthesised enum decoder throws for an unknown discriminator or a changed
    /// associated-value payload. A settings file can outlive the build that wrote it, so an
    /// unsupported action becomes a no-op instead; `Preferences.normalize()` then removes only
    /// that binding while leaving every action this build still understands intact.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: SettingsCodingKey.self),
              container.allKeys.count == 1,
              let actionKey = container.allKeys.first,
              let kind = ActionKind(rawValue: actionKey.stringValue)
        else {
            self = .passthrough
            return
        }

        switch kind {
        case .keyStroke:
            guard let payload = try? container.nestedContainer(
                keyedBy: PayloadCodingKeys.self,
                forKey: actionKey
            ), let combo = try? payload.decode(KeyCombo.self, forKey: ._0) else {
                self = .passthrough
                return
            }
            self = .keyStroke(combo)

        case .launchApp:
            guard let payload = try? container.nestedContainer(
                keyedBy: PayloadCodingKeys.self,
                forKey: actionKey
            ), let path = try? payload.decode(String.self, forKey: .path) else {
                self = .passthrough
                return
            }
            self = .launchApp(path: path)

        default:
            // ActionKind is already the single exhaustive, payload-free representation used
            // by the picker. Reusing it here avoids a second 62-case decoder table drifting.
            self = kind.makeAction(preserving: .passthrough)
        }
    }

    var isPassthrough: Bool { self == .passthrough }
}

/// One mapping: a physical button (optionally with modifiers held) to an action.
///
/// Bindings are *recorded*, not enumerated. There is no fixed list of "middle button plus
/// four side buttons", because which buttons a mouse actually reports varies, and a row for
/// a button the hardware does not have is noise. The user presses the button they care
/// about, a row appears for it, and then they choose what it does.
struct ButtonBinding: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// `CGEvent` button number: 2 = middle, 3 = back, 4 = forward, 5+ = extra.
    var button: Int
    /// Modifier mask that must be held, or 0 for "no modifiers".
    var modifiers: UInt64 = 0
    var action: MouseAction = .passthrough

    var isActive: Bool { !action.isPassthrough }

    init(id: UUID = UUID(), button: Int, modifiers: UInt64 = 0, action: MouseAction = .passthrough) {
        self.id = id
        self.button = button
        self.modifiers = modifiers
        self.action = action
    }

    /// Only `button` is required. Swift's synthesised decoder ignores property defaults and
    /// fails on any missing key, which would make one absent field discard the whole list —
    /// including bindings written by an older version that had no `id` or `modifiers`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decode(Int.self, forKey: .button)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        modifiers = (try? c.decode(UInt64.self, forKey: .modifiers)) ?? 0
        action = (try? c.decode(MouseAction.self, forKey: .action)) ?? .passthrough
    }
}

extension Array where Element == ButtonBinding {
    /// Resolve which binding applies to a press. An exact modifier match wins; otherwise
    /// the plain (no-modifier) binding for that button is used, so `⌘ + side button` can
    /// differ from `side button` without duplicating the common case.
    func resolve(button: Int, modifiers: UInt64) -> ButtonBinding? {
        if modifiers != 0,
           let exact = first(where: { $0.button == button && $0.modifiers == modifiers && $0.isActive }) {
            return exact
        }
        return first { $0.button == button && $0.modifiers == 0 && $0.isActive }
    }

    /// Buttons that have at least one active binding — used to decide the event mask.
    var hasActiveBinding: Bool {
        contains { $0.isActive }
    }
}

// MARK: - Per-app rules

/// How Open Mouse should behave while a given app is frontmost.
struct AppRule: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Hands off completely: no smoothing, no reversing, no button remap.
        case bypass
        /// Use `scroll` instead of the global scroll settings.
        case custom
    }

    var id = UUID()
    var bundleID: String
    var name: String
    var mode: Mode = .bypass
    var scroll: ScrollSettings = .default
    /// Skip button remapping for this app even in `.custom` mode.
    var bypassButtons = false

    init(
        id: UUID = UUID(),
        bundleID: String,
        name: String,
        mode: Mode = .bypass,
        scroll: ScrollSettings = .default,
        bypassButtons: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.mode = mode
        self.scroll = scroll
        self.bypassButtons = bypassButtons
    }

    /// Only the identity fields are required; see `ButtonBinding.init(from:)` for why.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = (try? c.decode(String.self, forKey: .name)) ?? bundleID
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .bypass
        scroll = (try? c.decode(ScrollSettings.self, forKey: .scroll)) ?? .default
        bypassButtons = (try? c.decode(Bool.self, forKey: .bypassButtons)) ?? false
    }
}

// MARK: - Updates

struct UpdateSettings: Codable, Equatable, Sendable {
    /// Where releases are published. Fixed, not a setting: pointing the updater at an
    /// arbitrary repository is a way to get talked into installing someone else's build, and
    /// a fork that wants its own release feed can change this line.
    static let repository = "tarnish233/OpenMouse"

    var checkAutomatically = true
    /// Seconds since 1970 of the last completed check, so a launch does not re-check
    /// immediately after the previous one.
    var lastCheckedAt: Double?
    /// Version string the user chose to stop being reminded about.
    var skippedVersion: String?
    /// The newest release seen so far. Persisted so that "有新版本" survives a relaunch:
    /// the automatic check runs at most daily, so without this the notice would vanish
    /// on the next launch and only come back a day later.
    var lastKnownRelease: UpdateChecker.Release?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkAutomatically = (try? c.decode(Bool.self, forKey: .checkAutomatically)) ?? true
        lastCheckedAt = try? c.decode(Double.self, forKey: .lastCheckedAt)
        skippedVersion = try? c.decode(String.self, forKey: .skippedVersion)
        lastKnownRelease = try? c.decode(UpdateChecker.Release.self, forKey: .lastKnownRelease)
    }
}

// MARK: - Root document

struct Preferences: Codable, Equatable, Sendable {
    var enabled = true
    var scroll: ScrollSettings = .default
    /// Starts empty: the user records the buttons their mouse actually has.
    var buttons: [ButtonBinding] = []
    var rules: [AppRule] = []
    var update = UpdateSettings()

    /// Decoded field by field so that changing the shape of one section cannot discard the
    /// others. A settings file is long-lived; losing a user's whole configuration because
    /// one array gained a field is not an acceptable failure mode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        scroll = (try? container.decode(ScrollSettings.self, forKey: .scroll)) ?? .default
        let decodedButtons = try? container.decode(
            [LossyDecoded<ButtonBinding>].self,
            forKey: .buttons
        )
        buttons = decodedButtons?.compactMap(\.value) ?? []
        rules = (try? container.decode([AppRule].self, forKey: .rules)) ?? []
        update = (try? container.decode(UpdateSettings.self, forKey: .update)) ?? UpdateSettings()
    }

    init() {}

    mutating func normalize() {
        scroll = scroll.clamped
        for index in rules.indices {
            rules[index].scroll = rules[index].scroll.clamped
        }
        // A binding with no action does nothing, so it has no business surviving a relaunch.
        // This also migrates configurations written before bindings were recorded rather
        // than enumerated: those files list every button number with a passthrough action,
        // which in the new model would show up as a page of empty rows.
        buttons.removeAll { !$0.isActive }
        buttons.sort { ($0.button, $0.modifiers) < ($1.button, $1.modifiers) }
    }
}

// MARK: - Resolved snapshot

/// A flattened, lock-free-friendly view of the preferences for one frontmost app.
/// The event tap reads this on every scroll event, so it must stay a plain value.
struct ResolvedConfig: Equatable, Sendable {
    var active: Bool
    var scroll: ScrollSettings
    var buttonsActive: Bool

    static let inactive = ResolvedConfig(active: false, scroll: .default, buttonsActive: false)

    init(active: Bool, scroll: ScrollSettings, buttonsActive: Bool) {
        self.active = active
        self.scroll = scroll
        self.buttonsActive = buttonsActive
    }

    init(preferences: Preferences, frontmostBundleID: String?) {
        guard preferences.enabled else {
            self = .inactive
            return
        }
        let rule = frontmostBundleID.flatMap { id in
            preferences.rules.first { $0.bundleID == id }
        }
        switch rule?.mode {
        case .bypass:
            self = .inactive
        case .custom:
            self.active = true
            self.scroll = rule!.scroll
            self.buttonsActive = !rule!.bypassButtons
        case nil:
            self.active = true
            self.scroll = preferences.scroll
            self.buttonsActive = true
        }
    }
}
