import AppKit
import QuartzCore

/// Injectable seam for the animator's frame source. Production uses `DisplayLinkTicker`;
/// self-checks use a deterministic ticker so lifecycle interleavings can be reproduced.
protocol ScrollFrameTicker: AnyObject {
    var activeSource: DisplayLinkTicker.Source { get }
    var isRunning: Bool { get }

    /// Starting must not invoke `onTick` synchronously. A real display link/timer always
    /// schedules its first callback later, and the animator relies on that while publishing
    /// the new ticker inside its lifecycle lock.
    @discardableResult
    func start() -> Bool

    func stop()
}

/// Vsync-locked frame source for the scroll animator.
///
/// Three reasons this is not a plain timer:
/// - A `DispatchSourceTimer` at "about 120 Hz" drifts against the display's actual scanout,
///   so a frame occasionally lands twice in one refresh and skips the next. That reads as
///   micro-judder, which is exactly what smooth scrolling is supposed to remove.
/// - `NSScreen.displayLink(target:selector:)` (macOS 14+) is the supported replacement for
///   `CVDisplayLink`, and unlike `CVDisplayLink` it does not need the refresh-rate
///   re-verification dance that display wake/reconnect otherwise forces on you.
/// - It runs on a dedicated thread's run loop rather than the main one. The event tap and
///   SwiftUI both live on the main run loop; a settings window mid-relayout must not be able
///   to stall scroll frames — that would make the app feel worst precisely while the user is
///   adjusting the sliders.
final class DisplayLinkTicker: ScrollFrameTicker {
    private let onTick: () -> Void
    private let fallbackQueue = DispatchQueue(label: "com.openmouse.frame-fallback", qos: .userInteractive)

    /// Which frame source actually got used. Surfaced in `--verbose` because silently
    /// degrading to a timer would look exactly like "the smoothing is worse than Mos".
    enum Source: String {
        case displayLink
        case timer
        case idle
    }

    /// All fields are read or mutated from more than one thread. Keeping them in one box also
    /// makes start/stop an atomic transition: diagnostics cannot observe a source without its
    /// matching thread/timer, and `stop()` cannot miss a thread that `start()` just published.
    private struct Runtime {
        var link: CADisplayLink?
        var thread: Thread?
        var fallbackTimer: DispatchSourceTimer?
        var source: Source = .idle

        var isRunning: Bool {
            link != nil || fallbackTimer != nil
        }
    }

    private let runtime = Locked(Runtime())

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    var activeSource: Source {
        runtime.withValue { $0.source }
    }

    /// The display to lock onto: the one the pointer is on, because that is the one whose
    /// content is about to scroll and whose refresh rate should drive the frames.
    ///
    /// `NSScreen.main` is *not* the right call here and is the trap: it means "the screen
    /// with the key window", so for a menu-bar app with no window open it is nil, and the
    /// ticker would quietly fall back to a timer — losing vsync exactly in the normal case.
    private static func preferredScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        if let under = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) {
            return under
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    deinit { stop() }

    var isRunning: Bool {
        runtime.withValue { $0.isRunning }
    }

    /// Must be called from the main thread: `NSScreen` is main-actor state.
    @discardableResult
    func start() -> Bool {
        runtime.withValue { runtime in
            guard !runtime.isRunning else { return true }

            guard let screen = Self.preferredScreen() else {
                let fps = 120.0
                let timer = DispatchSource.makeTimerSource(queue: fallbackQueue)
                timer.schedule(
                    deadline: .now(),
                    repeating: .nanoseconds(Int(1_000_000_000.0 / fps)),
                    leeway: .nanoseconds(0)
                )
                timer.setEventHandler { [weak self] in self?.onTick() }
                runtime.fallbackTimer = timer
                runtime.source = .timer
                // Publish the timer before resuming it. If its first callback wins the race,
                // it waits for this lock and then observes a fully running source.
                timer.resume()
                return true
            }

            let link = screen.displayLink(target: self, selector: #selector(handleTick))
            // Park the link on its own run loop so main-thread work cannot delay frames.
            let thread = Thread { [weak self] in
                guard let self else { return }
                link.add(to: .current, forMode: .common)
                // `run(mode:before:)` in a loop lets the thread exit once the link is torn down.
                while !Thread.current.isCancelled, self.isRunning {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
                }
                link.invalidate()
            }
            thread.name = "com.openmouse.display-link"
            thread.qualityOfService = .userInteractive

            runtime.link = link
            runtime.thread = thread
            runtime.source = .displayLink
            // As with the fallback timer, start only after the complete runtime has been
            // published. `stop()` is serialized by this same lock and cannot miss the thread.
            thread.start()
            return true
        }
    }

    func stop() {
        runtime.withValue { runtime in
            runtime.link?.isPaused = true
            runtime.fallbackTimer?.cancel()
            runtime.thread?.cancel()
            runtime.link = nil
            runtime.thread = nil
            runtime.fallbackTimer = nil
            runtime.source = .idle
        }
    }

    @objc private func handleTick() {
        onTick()
    }
}
