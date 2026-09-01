import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @State private var store = SettingsStore.shared
    @State private var engine = MouseEngine.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            PermissionBanner()

            Section {
                Toggle(isOn: $store.preferences.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Open Mouse")
                        Text("关闭后完全不拦截任何事件，与退出应用等效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        loginItemError = LoginItem.setEnabled(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Strings.generalLaunchAtLogin)
                        if let loginItemError {
                            Text(loginItemError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.switch)
            }

            Section("诊断") {
                LabeledContent("事件监听") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(engine.status.isRunning ? .green : .orange)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                if engine.autoReenableCount > 0 {
                    LabeledContent("被系统自动关闭过") {
                        Text("\(engine.autoReenableCount) 次（已自动恢复）")
                            .foregroundStyle(.secondary)
                    }
                }
                LiveCounters()
                LabeledContent("配置文件") {
                    Button(Strings.generalRevealConfig) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.preferencesFileURL])
                    }
                    .controlSize(.small)
                }
            }

            Section(Strings.generalAbout) {
                LabeledContent("版本") {
                    Text(AppVersion.displayString)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(Strings.generalCredits)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UpdateSection()

            Section {
                HStack {
                    Button(Strings.generalResetAll, role: .destructive) {
                        isConfirmingReset = true
                    }
                    .controlSize(.small)
                    Spacer()
                    Button(Strings.generalQuit) {
                        NSApp.terminate(nil)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .confirmationDialog(
            "恢复全部默认设置？",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) { store.resetAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("滚动参数、按键映射与应用规则都会被清空。")
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var statusText: String {
        switch engine.status {
        case .running: Strings.statusRunning
        case .needsPermission: Strings.statusNeedsPermission
        case .failed: Strings.statusFailed
        case .off: Strings.statusOff
        }
    }
}

/// Polls the engine counters on a timer. This is the honest answer to "is smoothing really
/// happening?" — one wheel notch should expand into a run of synthetic events.
private struct LiveCounters: View {
    @State private var engine = MouseEngine.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let stats = engine.stats
            VStack(spacing: 6) {
                LabeledContent("滚轮事件") {
                    Text("平滑 \(stats.wheelEventsSmoothed) · 直通 \(stats.wheelEventsPassedThrough)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("触控板事件") {
                    Text("\(stats.continuousEventsSeen)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("已合成滚动事件") {
                    HStack(spacing: 8) {
                        Text("\(stats.syntheticEventsPosted)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let ratio = stats.amplification {
                            Text(String(format: "合成比 %.1f×", ratio))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if stats.buttonActionsFired > 0 {
                    LabeledContent("已触发按键动作") {
                        Text("\(stats.buttonActionsFired)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // Only shown once a notch has been handled: before that these read as zeros
                // that look like a fault rather than an idle pipeline.
                if stats.wheelEventsSmoothed > 0 {
                    LabeledContent("投递目标") {
                        HStack(spacing: 8) {
                            Text(targetName(pid: stats.lastTargetPID))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("步长取自 \(stats.lastRawDeltaSource.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                // Loud on purpose. A non-zero value is the signature of the tap sitting at
                // the wrong layer, which is what a dead scroll wheel looks like from here.
                if stats.wheelEventsUndeliverable > 0 {
                    LabeledContent("无法投递（已放行）") {
                        Text("\(stats.wheelEventsUndeliverable)")
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Spacer()
                    Button("清零计数") { engine.resetStats() }
                        .controlSize(.small)
                }
            }
        }
    }

    /// A pid alone tells the user nothing; the app name is the part that confirms frames are
    /// going where the pointer is.
    private func targetName(pid: Int) -> String {
        guard pid > 0 else { return "未解析" }
        let name = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
        return name.map { "\($0) (\(pid))" } ?? "pid \(pid)"
    }
}

/// Update checking and installation. The independent helper only runs during an update and
/// verifies the candidate against the current application's designated requirement twice.
private struct UpdateSection: View {
    @State private var store = SettingsStore.shared
    @State private var updates = UpdateCoordinator.shared

    var body: some View {
        Section {
            Toggle(isOn: $store.preferences.update.checkAutomatically) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Strings.updateAuto)
                    Text(Strings.updateAutoHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                Button(updates.isChecking ? Strings.updateChecking : Strings.updateCheckNow) {
                    Task { await updates.check(userInitiated: true) }
                }
                .controlSize(.small)
                .disabled(updates.isChecking || updates.installationState.isBusy)

                if updates.isChecking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let last = updates.lastCheckedAt {
                    Text(Strings.updateLastChecked(last.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            outcomeRow
        } header: {
            Text(Strings.updateSection)
        }
    }

    @ViewBuilder
    private var outcomeRow: some View {
        switch updates.installationState {
        case let .downloading(version):
            updateProgress(Strings.updateDownloading(version))
        case let .installing(version):
            updateProgress(Strings.updateInstalling(version))
        case let .installed(version):
            Label(Strings.updateInstalled(version), systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let release = updates.pendingRelease {
                    if updates.canInstallAutomatically {
                        Button(Strings.updateInstallRetry) {
                            Task { await updates.install(release) }
                        }
                        .controlSize(.small)
                    } else {
                        Button(Strings.updateDownloadManually) { updates.open(release) }
                            .controlSize(.small)
                    }
                }
            }
        case .idle:
            checkOutcomeRow
        }
    }

    @ViewBuilder
    private var checkOutcomeRow: some View {
        switch updates.outcome {
        case nil:
            EmptyView()
        case .notConfigured:
            Label(Strings.updateNotConfigured, systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .upToDate(current):
            Label(Strings.updateUpToDate(current), systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .available:
            if let release = updates.pendingRelease {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Strings.updateAvailable(release.version), systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    HStack(spacing: 8) {
                        if updates.canInstallAutomatically {
                            Button(Strings.updateInstall) {
                                Task { await updates.install(release) }
                            }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            Button(Strings.updateOpen) { updates.open(release) }
                                .controlSize(.small)
                        } else {
                            Button(Strings.updateDownloadManually) { updates.open(release) }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        }
                        Button(Strings.updateSkip) { updates.skip(release) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func updateProgress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
