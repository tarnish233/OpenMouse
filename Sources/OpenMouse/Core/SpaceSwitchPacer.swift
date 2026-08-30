import Foundation

/// Paces desktop-switch requests so a quick series of gestures does not get eaten.
///
/// macOS runs a space transition as an animation, and a switch requested while one is playing
/// is *discarded* — not queued. Six flicks in two seconds therefore move you two or three
/// desktops, not six, and it reads as "the button sometimes doesn't work" even though every
/// gesture was recognised. There is no cooldown in this app; the cooldown is the system's, and
/// the only fix is to hold the extra steps and feed them in at a rate it accepts.
///
/// Matches Mos's behaviour, including the two details that make it feel right rather than
/// merely correct:
/// - A cap on the queue, so a frantic series cannot send you eight desktops away.
/// - Reversing direction *discards* what is queued instead of unwinding it one step at a
///   time, because a user flicking back wants to go back now, not to cancel a backlog.
@MainActor
final class SpaceSwitchPacer {
    static let shared = SpaceSwitchPacer()

    /// Minimum spacing between two switches. Mos uses 0.12s, which is a little under the
    /// transition length — fast enough to feel immediate, slow enough to land.
    static let interval: TimeInterval = 0.12
    /// Most steps that may be waiting. Beyond this the user has lost track anyway.
    static let maximumPending = 2

    /// Signed step count still owed: negative = left, positive = right.
    private var pending = 0
    private var lastFired: TimeInterval?
    private var scheduled: DispatchWorkItem?
    private let post: (MouseAction) -> Void

    init(post: @escaping (MouseAction) -> Void = { ActionRunner().postWithoutPacing($0) }) {
        self.post = post
    }

    func request(_ action: MouseAction) {
        let step: Int
        switch action {
        case .spaceLeft: step = -1
        case .spaceRight: step = 1
        default: return
        }

        if pending != 0, (pending > 0) != (step > 0) {
            // Direction reversed: drop the stale backlog rather than making the user unwind it.
            pending = step
        } else {
            pending = min(Self.maximumPending, max(-Self.maximumPending, pending + step))
        }
        scheduleIfNeeded()
    }

    /// Abandon anything queued — used when the engine is disabled mid-series.
    func cancel() {
        pending = 0
        scheduled?.cancel()
        scheduled = nil
    }

    private func scheduleIfNeeded() {
        guard pending != 0, scheduled == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = lastFired.map { max(0, Self.interval - (now - $0)) } ?? 0

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.fireNext()
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func fireNext() {
        guard pending != 0 else { return }
        let action: MouseAction
        if pending < 0 {
            pending += 1
            action = .spaceLeft
        } else {
            pending -= 1
            action = .spaceRight
        }
        lastFired = ProcessInfo.processInfo.systemUptime
        post(action)
        scheduleIfNeeded()
    }

    // MARK: Testable surface

    /// Steps still owed. Exposed so the queueing rules can be checked without real desktops.
    var pendingSteps: Int { pending }
}
