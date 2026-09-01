import Foundation

/// Timings shared by the two sides of the update handoff.
///
/// They live together because the only thing that matters about them is their *order*: the host
/// must admit that its own termination was refused while the helper is still waiting, so the user
/// sees the real reason ("Open Mouse 没有退出") instead of the helper's later, vaguer bailout — or
/// worse, nothing at all. `SelfCheck` pins that ordering.
public enum UpdateHandoff {
    /// How long the helper waits for the host process to exit before abandoning the install.
    public static let hostExitTimeout: TimeInterval = 30

    /// How long the host waits for its own `terminate` to take effect before reporting failure and
    /// releasing the busy state that would otherwise block every later update check.
    public static let terminationGrace: TimeInterval = 12
}
