import ApplicationServices
import CoreGraphics
import Foundation

enum EventTapDisableReason: String, Equatable {
    case timeout
    case userInput
}

/// The small lifecycle surface MouseEngine needs. Keeping it abstract lets the runtime
/// convergence rules be exercised without creating an Accessibility-privileged event tap.
protocol EventTapLifecycle: AnyObject {
    var isRunning: Bool { get }
    var onAutoReenable: ((EventTapDisableReason) -> Void)? { get set }

    @discardableResult
    func start(mask: CGEventMask) -> Bool
    func stop()
}

/// Owns the lifetime of a `CGEventTap`, including the one failure mode everybody hits:
/// macOS silently disables a tap whose callback takes too long, and the only signal is a
/// `tapDisabledByTimeout` event that you must respond to by re-enabling yourself.
final class EventTapController {
    typealias Handler = (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    /// The *annotated* session tap, and the annotation is the whole point: only at this layer
    /// does the system fill in `kCGEventTargetUnixProcessID` with the process the event is
    /// actually routed to. Tap the raw HID stream instead and that field reports whichever
    /// window is merely frontmost, so every synthesised frame gets delivered to the wrong
    /// process — scrolling a window that does not have focus (which macOS allows) then does
    /// nothing at all. Mos taps here for the same reason.
    static let tapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap

    /// Tail, not head: let anything already installed see the event first, and take what
    /// survives. Head-inserting puts us ahead of drivers that legitimately rewrite wheel
    /// events before we scale them.
    static let tapPlacement: CGEventTapPlacement = .tailAppendEventTap

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: Handler
    /// Names this tap in the log; there is more than one and they fail differently.
    private let label: String

    private(set) var isRunning = false
    /// Called when the system disables the tap so the app can surface it.
    var onAutoReenable: ((EventTapDisableReason) -> Void)?

    init(label: String, handler: @escaping Handler) {
        self.label = label
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    func start(mask: CGEventMask) -> Bool {
        stop()

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            // The *annotated* session tap, and the annotation is the whole point: only at
            // this layer does the system fill in `kCGEventTargetUnixProcessID` with the
            // process the event is actually routed to. Tap the raw HID stream instead and
            // that field reports whichever window is merely frontmost, so every synthesised
            // frame gets delivered to the wrong process — scrolling a window that does not
            // have focus (which macOS allows) then does nothing at all.
            tap: Self.tapLocation,
            // Tail, not head: let anything already installed see the event first, and take
            // what survives. Head-inserting puts us ahead of drivers that legitimately
            // rewrite wheel events before we scale them.
            place: Self.tapPlacement,
            // `.defaultTap` (not `.listenOnly`) is required because we rewrite and
            // swallow events. That is also why Accessibility permission is mandatory.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.dispatch(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Trace.tapStarted(kind: label, mask: mask, ok: false)
            return false
        }

        machPort = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isRunning = true
        Trace.tapStarted(kind: label, mask: mask, ok: true)
        return true
    }

    func stop() {
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let wasRunning = isRunning
        machPort = nil
        runLoopSource = nil
        isRunning = false
        if wasRunning { Trace.tapStopped(kind: label) }
    }

    /// Handle both system disable reasons through one observable recovery path. Exposed
    /// internally so self-checks can cover the callbacks without creating a privileged tap.
    @discardableResult
    func handleDisableEvent(_ type: CGEventType) -> Bool {
        let reason: EventTapDisableReason
        switch type {
        case .tapDisabledByTimeout:
            reason = .timeout
        case .tapDisabledByUserInput:
            reason = .userInput
        default:
            return false
        }

        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        Trace.tapAutoReenabled(kind: label, reason: reason.rawValue)
        onAutoReenable?(reason)
        return true
    }

    private func dispatch(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if handleDisableEvent(type) { return nil }
        return handler(proxy, type, event)
    }
}

extension EventTapController: EventTapLifecycle {}
