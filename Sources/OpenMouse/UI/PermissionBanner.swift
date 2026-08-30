import SwiftUI

/// Shown at the top of every pane while the tap cannot be installed. Without Accessibility
/// permission nothing in this app works, so it deserves to be impossible to miss.
struct PermissionBanner: View {
    @State private var engine = MouseEngine.shared

    var body: some View {
        if engine.status == .needsPermission {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Strings.permissionTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(Strings.permissionBody)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(Strings.permissionOpen) {
                            AccessibilityPermission.openSystemSettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)

                        Button(Strings.permissionRecheck) {
                            AccessibilityPermission.requestPrompt()
                            engine.apply()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        ConflictBanner()
    }
}

/// Warns when another scroll-tapping app is running alongside us. Renders nothing at all
/// when there is no conflict — `ConflictMonitor` does the watching, so this stays a pure
/// conditional and contributes no empty row to the form.
struct ConflictBanner: View {
    @State private var monitor = ConflictMonitor.shared

    var body: some View {
        if !monitor.conflicts.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Strings.conflictTitle, systemImage: "arrow.triangle.branch")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(Strings.conflictBody(monitor.conflicts.map(\.name)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
