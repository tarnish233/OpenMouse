import CoreGraphics
import Foundation

/// Which way a gesture went, and what that means.
///
/// The horizontal mapping is deliberately inverted: pushing the mouse *left* moves you to
/// the desktop on the *right*. It reads as shoving the current desktop out of the way, which
/// is the same direction sense as a trackpad swipe, and it is what Logi Options+ does.
enum MouseGestureDirection: String, Equatable, Sendable {
    case up
    case down
    case left
    case right

    var action: MouseAction {
        switch self {
        case .up: .missionControl
        case .down: .applicationWindows
        case .left: .spaceRight
        case .right: .spaceLeft
        }
    }
}

/// The axis selected after the small click-vs-drag dead zone has been crossed.
enum MouseGestureAxis: String, Equatable, Sendable {
    case horizontal
    case vertical

    /// Convert the first locked-axis mouse delta into the one-shot direction used by Logi-style
    /// gesture navigation. EventRouter ignores later movement until the physical button is
    /// released and pressed again.
    func direction(forPixelDelta delta: Double) -> MouseGestureDirection {
        switch self {
        case .horizontal: delta < 0 ? .left : .right
        case .vertical: delta < 0 ? .up : .down
        }
    }
}

enum MouseGestureUpdate: Equatable, Sendable {
    /// The axis has just locked. `pixelDelta` contains all motion accumulated through the
    /// activation dead zone, so the system animation catches up without losing the first few
    /// pixels.
    case began(axis: MouseGestureAxis, pixelDelta: Double)
    /// One subsequent raw movement sample on the locked axis. The recognizer retains this detail
    /// for diagnostics; production Logi-style delivery ignores it after the first direction.
    case changed(axis: MouseGestureAxis, pixelDelta: Double)
}

enum MouseGestureCompletion: Equatable, Sendable {
    case gesture(MouseGestureAxis)
    case click
}

/// Axis-lock recognizer for the gesture-navigation binding.
///
/// This recognizer decides whether the hold is a click and which axis owns the drag. EventRouter
/// converts the first locked-axis delta to one action, matching the observed Logi Options+
/// contract: one command per physical hold, independent of movement speed or later reversal.
///
/// The two axes are deliberately not symmetric. Horizontal switches desktops and is the gesture
/// used all day, so it engages early. Vertical opens Mission Control or Application Windows,
/// and both are modal: while either is on screen, Control-Arrow does nothing — ours and the
/// keyboard's alike — so a false vertical lock reads as "desktop switching is broken" until the
/// user notices and dismisses it.
struct MouseGestureRecognizer {
    /// A small dead zone keeps a stationary side-button click usable while making the animation
    /// engage much earlier than the old 40-point one-shot recognizer. Mac Mouse Fix uses a
    /// similarly small modified-drag threshold.
    static let defaultActivationDistance: Double = 7
    /// Horizontal must beat vertical by this factor, so diagonal drift does not pick for you.
    static let defaultDominanceRatio: Double = 1.2
    /// Vertical needs twice the horizontal distance, to absorb the wobble of pressing the button.
    ///
    /// Field trace, 2026-10-19 18:28:04, M750 over Bluetooth: the press drifted (−2, 1), (0, 3),
    /// (1, 2), (5, 3) — 9 px down against 4 px across within 22 ms — and only then turned into a
    /// 248 px swipe. The symmetric 7 px / 1.2× rule locked "down", Application Windows opened,
    /// and the next three swipes plus two Control-Arrow presses on the keyboard all did nothing
    /// until a click dismissed it. Replaying the logged motion of all 310 holds from that session
    /// through this rule changes exactly one decision — that one; every horizontal lock lands on
    /// the same sample as before and every click stays a click.
    static let defaultVerticalActivationDistance: Double = 14
    /// Vertical must be at least twice horizontal. 2:1 is Logi Options+'s own axis rule: its
    /// `GestureTriggerBaseState::AngleSnapping` only credits a motion sample to an axis when it is
    /// at least twice the other ("30 degrees angle snapping range").
    static let defaultVerticalDominanceRatio: Double = 2

    private let activationDistance: Double
    private let dominanceRatio: Double
    private let verticalActivationDistance: Double
    private let verticalDominanceRatio: Double

    private(set) var displacement = CGPoint.zero
    private(set) var maximumDistanceFromOrigin: Double = 0
    private(set) var axis: MouseGestureAxis?
    /// Where the pointer was at the previous sample, so movement can be measured from the
    /// event's own coordinates rather than trusting a delta field to be populated.
    private var lastLocation: CGPoint?

    init(
        activationDistance: Double = defaultActivationDistance,
        dominanceRatio: Double = defaultDominanceRatio,
        verticalActivationDistance: Double = defaultVerticalActivationDistance,
        verticalDominanceRatio: Double = defaultVerticalDominanceRatio
    ) {
        self.activationDistance = activationDistance
        self.dominanceRatio = dominanceRatio
        self.verticalActivationDistance = verticalActivationDistance
        self.verticalDominanceRatio = verticalDominanceRatio
    }

    /// Anchor the gesture at the location of the press that started it.
    mutating func begin(at location: CGPoint) {
        guard location.x.isFinite, location.y.isFinite else { return }
        lastLocation = location
    }

    /// Feed one movement sample, measured however the event can actually be measured.
    ///
    /// Two sources, because neither is reliable alone:
    /// - The delta fields are the hardware's own report and keep counting when the pointer is
    ///   clamped at a screen edge — a swipe right along the right edge moves no coordinates.
    /// - They also come through as zero on some devices, which is what made this feature look
    ///   broken: the recognizer accumulated nothing and every gesture ended as "never moved".
    ///
    /// So prefer the delta when it carries something, and otherwise difference the event's own
    /// location, which is always populated.
    mutating func append(
        location: CGPoint,
        fieldDeltaX: Double,
        fieldDeltaY: Double
    ) -> MouseGestureUpdate? {
        let previous = lastLocation
        if location.x.isFinite, location.y.isFinite {
            lastLocation = location
        }

        var dx = fieldDeltaX
        var dy = fieldDeltaY
        guard dx.isFinite, dy.isFinite else { return nil }
        if dx == 0, dy == 0,
           let previous,
           location.x.isFinite, location.y.isFinite {
            dx = location.x - previous.x
            dy = location.y - previous.y
        }
        guard dx != 0 || dy != 0 else { return nil }
        return append(deltaX: dx, deltaY: dy)
    }

    /// Feed one movement delta. Once an axis locks, returns every non-zero sample on that axis.
    mutating func append(deltaX: Double, deltaY: Double) -> MouseGestureUpdate? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }

        displacement.x += deltaX
        displacement.y += deltaY
        let distance = hypot(displacement.x, displacement.y)
        guard distance.isFinite else {
            displacement = .zero
            return nil
        }
        maximumDistanceFromOrigin = max(maximumDistanceFromOrigin, distance)

        if let axis {
            let delta = axis == .horizontal ? deltaX : deltaY
            guard delta != 0 else { return nil }
            return .changed(axis: axis, pixelDelta: delta)
        }

        let horizontal = abs(displacement.x)
        let vertical = abs(displacement.y)
        guard max(horizontal, vertical) >= activationDistance else { return nil }

        if horizontal >= vertical * dominanceRatio {
            axis = .horizontal
            return .began(axis: .horizontal, pixelDelta: displacement.x)
        }
        if vertical >= verticalActivationDistance,
           vertical >= horizontal * verticalDominanceRatio {
            axis = .vertical
            return .began(axis: .vertical, pixelDelta: displacement.y)
        }
        // Too diagonal to call yet, or vertical but still within the press-wobble zone; keep
        // accumulating. A real swipe either keeps going and resolves, or the release is a click.
        return nil
    }

    /// Every swallowed hold has an exhaustive result. Axis-locked input owns an interactive
    /// gesture; everything else becomes the button's click action on release.
    var completion: MouseGestureCompletion {
        axis.map(MouseGestureCompletion.gesture) ?? .click
    }

    var shouldTreatAsClick: Bool { completion == .click }
}
