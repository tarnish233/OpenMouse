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

/// Four-direction recognizer for the gesture-navigation binding.
///
/// One button hold is one gesture transaction: as soon as a direction commits, the rest of
/// the movement is ignored until the button is released. Without that, a single long swipe
/// keeps crossing the activation threshold and fires the action several times, which sends
/// you three desktops over when you meant one.
struct MouseGestureRecognizer {
    /// How far the pointer must travel before a direction is committed.
    static let defaultActivationDistance: Double = 40
    /// Movement below this counts as "did not move", so the hold is treated as a click.
    static let defaultClickTolerance: Double = 10
    /// One axis must beat the other by this factor, so diagonal drift does not pick for you.
    static let defaultDominanceRatio: Double = 1.2

    private let activationDistance: Double
    private let clickTolerance: Double
    private let dominanceRatio: Double

    private(set) var displacement = CGPoint.zero
    private(set) var maximumDistanceFromOrigin: Double = 0
    private(set) var recognized: MouseGestureDirection?

    init(
        activationDistance: Double = defaultActivationDistance,
        clickTolerance: Double = defaultClickTolerance,
        dominanceRatio: Double = defaultDominanceRatio
    ) {
        self.activationDistance = activationDistance
        self.clickTolerance = clickTolerance
        self.dominanceRatio = dominanceRatio
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

    /// A hold that never really moved is a plain click. Logi Options+ maps that to Mission
    /// Control, so the gesture button is useful without moving the mouse at all.
    var shouldTreatAsClick: Bool {
        recognized == nil && maximumDistanceFromOrigin <= clickTolerance
    }
}
