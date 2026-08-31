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

enum MouseGestureCompletion: Equatable {
    case direction(MouseGestureDirection)
    case click
}

/// Four-direction recognizer for the gesture-navigation binding.
///
/// One button hold is one gesture transaction: as soon as a direction commits, the rest of
/// the movement is ignored until the button is released. Without that, a single long swipe
/// keeps crossing the activation threshold and fires the action several times, which sends
/// you three desktops over when you meant one.
struct MouseGestureRecognizer {
    /// How far the pointer must travel before a direction is committed.
    static let defaultActivationDistance: Double = 40
    /// One axis must beat the other by this factor, so diagonal drift does not pick for you.
    static let defaultDominanceRatio: Double = 1.2

    private let activationDistance: Double
    private let dominanceRatio: Double

    private(set) var displacement = CGPoint.zero
    private(set) var maximumDistanceFromOrigin: Double = 0
    private(set) var recognized: MouseGestureDirection?
    /// Where the pointer was at the previous sample, so movement can be measured from the
    /// event's own coordinates rather than trusting a delta field to be populated.
    private var lastLocation: CGPoint?

    init(
        activationDistance: Double = defaultActivationDistance,
        dominanceRatio: Double = defaultDominanceRatio
    ) {
        self.activationDistance = activationDistance
        self.dominanceRatio = dominanceRatio
    }

    /// Anchor the gesture at the location of the press that started it.
    mutating func begin(at location: CGPoint) {
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
    ) -> MouseGestureDirection? {
        let previous = lastLocation
        lastLocation = location

        var dx = fieldDeltaX
        var dy = fieldDeltaY
        if dx == 0, dy == 0, let previous {
            dx = location.x - previous.x
            dy = location.y - previous.y
        }
        guard dx != 0 || dy != 0 else { return nil }
        return append(deltaX: dx, deltaY: dy)
    }

    /// Feed one movement delta. Returns a direction exactly once per hold.
    mutating func append(deltaX: Double, deltaY: Double) -> MouseGestureDirection? {
        displacement.x += deltaX
        displacement.y += deltaY
        maximumDistanceFromOrigin = max(
            maximumDistanceFromOrigin,
            (displacement.x * displacement.x + displacement.y * displacement.y).squareRoot()
        )

        guard recognized == nil else { return nil }

        let horizontal = abs(displacement.x)
        let vertical = abs(displacement.y)
        guard max(horizontal, vertical) >= activationDistance else { return nil }

        if horizontal >= vertical * dominanceRatio {
            let direction: MouseGestureDirection = displacement.x < 0 ? .left : .right
            recognized = direction
            return direction
        }
        if vertical >= horizontal * dominanceRatio {
            // CGEvent mouse delta Y is positive downward.
            let direction: MouseGestureDirection = displacement.y < 0 ? .up : .down
            recognized = direction
            return direction
        }
        // Too diagonal to call yet; keep accumulating.
        return nil
    }

    /// Every swallowed hold has an exhaustive result. A clear dominant-axis swipe commits
    /// while moving; everything else becomes the button's click action on release. Keeping
    /// this as the exact complement avoids a dead zone where neither path owns the gesture.
    var completion: MouseGestureCompletion {
        recognized.map(MouseGestureCompletion.direction) ?? .click
    }

    var shouldTreatAsClick: Bool { completion == .click }
}
