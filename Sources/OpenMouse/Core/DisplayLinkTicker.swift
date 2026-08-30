import AppKit
import QuartzCore

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
final class DisplayLinkTicker {
    private let onTick: () -> Void

    private var link: CADisplayLink?
    private var thread: Thread?
    private var fallbackTimer: DispatchSourceTimer?
    private let fallbackQueue = DispatchQueue(label: "com.openmouse.frame-fallback", qos: .userInteractive)
    private let lock = NSLock()

    /// Which frame source actually got used. Surfaced in `--verbose` because silently
    /// degrading to a timer would look exactly like "the smoothing is worse than Mos".
    enum Source: String {
        case displayLink
        case timer
        case idle
    }

    private var source: Source = .idle

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    var activeSource: Source {
        lock.lock()
        defer { lock.unlock() }
        return source
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
        lock.lock()
        defer { lock.unlock() }
        return link != nil || fallbackTimer != nil
    }

    /// Must be called from the main thread: `NSScreen` is main-actor state.
    func start() {
        lock.lock()
        let alreadyRunning = link != nil || fallbackTimer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        guard let screen = Self.preferredScreen() else {
            startFallback()
            return
        }

        let link = screen.displayLink(target: self, selector: #selector(handleTick))
        lock.lock()
        self.link = link
        source = .displayLink
        lock.unlock()

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
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        let link = self.link
        self.link = nil
        let timer = fallbackTimer
        fallbackTimer = nil
        source = .idle
        lock.unlock()

        link?.isPaused = true
        timer?.cancel()
        thread?.cancel()
        thread = nil
    }

    @objc private func handleTick() {
        onTick()
    }

    /// Headless sessions and odd display configurations can leave `NSScreen.main` nil.
    /// A timer is worse but far better than silently not scrolling.
    private func startFallback() {
        let fps = 120.0
        let timer = DispatchSource.makeTimerSource(queue: fallbackQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(1_000_000_000.0 / fps)),
            leeway: .nanoseconds(0)
        )
        timer.setEventHandler { [weak self] in self?.onTick() }
        lock.lock()
        fallbackTimer = timer
        source = .timer
        lock.unlock()
        timer.resume()
    }
}
