import AppKit
import ServiceManagement

/// Login-item registration. `SMAppService.mainApp` is the modern replacement for the
/// deprecated `LSSharedFileList` API and needs no helper bundle.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message on failure — typically "app is not in a place the system
    /// will trust", which happens when running straight out of a build directory.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
