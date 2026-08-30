import ApplicationServices
import CoreGraphics
import Foundation

/// Owns the lifetime of a `CGEventTap`, including the one failure mode everybody hits:
/// macOS silently disables a tap whose callback takes too long, and the only signal is a
/// `tapDisabledByTimeout` event that you must respond to by re-enabling yourself.
final class EventTapController {
    typealias Handler = (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: Handler

    private(set) var isRunning = false
    /// Called when the system disables the tap so the app can surface it.
    var onAutoReenable: (() -> Void)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    func start(mask: CGEventMask) -> Bool {
        stop()

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
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
            return false
        }

        machPort = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isRunning = true
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
        machPort = nil
        runLoopSource = nil
        isRunning = false
    }

    private func dispatch(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // Our callback overran the deadline. Turn the tap back on, otherwise the app
            // looks like it randomly stopped working.
            if let port = machPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            onAutoReenable?()
            return nil
        case .tapDisabledByUserInput:
            if let port = machPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return nil
        default:
            return handler(proxy, type, event)
        }
    }
}
