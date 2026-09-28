import AppKit
import Observation
import ServiceManagement

/// Login status is read asynchronously, not once in State's initializer and again in onAppear.
/// Status queries use a serial worker. Explicit registration keeps its original synchronous
/// commit semantics so quitting immediately afterwards cannot abandon a queued system change.
@MainActor
@Observable
final class LoginItem {
    struct Result {
        var enabled: Bool
        var error: String?
    }

    private static let queue = DispatchQueue(label: "com.openmouse.login-item", qos: .utility)
    private static let live = LoginItem(
        read: { complete in
            queue.async {
                let enabled = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async { complete(enabled) }
            }
        },
        write: { enabled, complete in
            // Only an explicit toggle calls this, never page entry. Commit the system change
            // before returning to the event loop; defer just the confirmation status query.
            var message: String?
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                message = error.localizedDescription
            }
            let errorMessage = message
            queue.async {
                let result = Result(enabled: SMAppService.mainApp.status == .enabled, error: errorMessage)
                DispatchQueue.main.async { complete(result) }
            }
        }
    )

    static let shared: LoginItem = {
        let model = live
        // The process-wide observer also covers returning from System Settings while another
        // pane is selected. No timer/polling, and no status query from a view initializer.
        model.activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.refresh(force: true) }
        }
        return model
    }()

    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    private(set) var isEnabled: Bool?
    private(set) var error: String?
    private(set) var isUpdating = false
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var updateID: UUID?
    @ObservationIgnored private var refreshedAt: TimeInterval?
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let read: (@escaping (Bool) -> Void) -> Void
    @ObservationIgnored private let write: (Bool, @escaping (Result) -> Void) -> Void

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: @escaping (@escaping (Bool) -> Void) -> Void,
        write: @escaping (Bool, @escaping (Result) -> Void) -> Void
    ) {
        self.now = now
        self.read = read
        self.write = write
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func refresh(force: Bool = false) {
        guard !isUpdating, refreshID == nil else { return }
        if !force, let refreshedAt, now() >= refreshedAt, now() - refreshedAt < 5 { return }
        let id = UUID()
        refreshID = id
        read { [weak self] enabled in
            guard let self, self.refreshID == id else { return }
            self.refreshID = nil
            self.isEnabled = enabled
            self.refreshedAt = self.now()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != nil, !isUpdating else { return }
        refreshID = nil // A late read must not overwrite a more recent user-requested write.
        let id = UUID()
        updateID = id
        isUpdating = true
        error = nil
        write(enabled) { [weak self] result in
            guard let self, self.updateID == id else { return }
            self.updateID = nil
            self.isUpdating = false
            self.isEnabled = result.enabled // Read back actual status, including rejection.
            self.error = result.error
            self.refreshedAt = self.now()
        }
    }
}
