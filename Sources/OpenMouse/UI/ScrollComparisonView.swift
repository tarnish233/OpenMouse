import SwiftUI

struct ScrollComparisonView: View {
    @State private var store = SettingsStore.shared
    @State private var engine = MouseEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Strings.scrollComparisonTitle)
                    .font(.title2.bold())
                Text(Strings.scrollComparisonIntro)
                    .foregroundStyle(.secondary)
            }

            if engine.status == .needsPermission {
                comparisonPermissionBanner
            } else if engine.status == .failed {
                Label(Strings.statusFailed, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                ScrollComparisonPane(
                    pane: .system,
                    title: Strings.scrollComparisonSystemTitle,
                    subtitle: Strings.scrollComparisonSystemSubtitle,
                    systemImage: "power",
                    tint: .secondary,
                    isAvailable: true,
                    unavailableMessage: nil
                )

                ScrollComparisonPane(
                    pane: .openMouse,
                    title: canPreviewOpenMouse
                        ? Strings.scrollComparisonOpenMouseTitle
                        : Strings.scrollComparisonUnavailableTitle,
                    subtitle: canPreviewOpenMouse
                        ? openMouseSubtitle
                        : Strings.scrollComparisonUnavailableSubtitle,
                    systemImage: "sparkles",
                    tint: canPreviewOpenMouse ? .accentColor : .secondary,
                    isAvailable: canPreviewOpenMouse,
                    unavailableMessage: Strings.scrollComparisonUnavailableOverlay
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            engine.updateScrollComparisonSettings(store.preferences.scroll)
        }
        .onChange(of: store.preferences.scroll) { _, settings in
            engine.updateScrollComparisonSettings(settings)
        }
    }

    private var openMouseSubtitle: String {
        let settings = store.preferences.scroll
        return String(
            format: Strings.scrollComparisonOpenMouseFormat,
            settings.minimumStep,
            settings.speed,
            settings.smoothness * 100
        )
    }

    private var canPreviewOpenMouse: Bool {
        engine.status == .running
    }

    private var comparisonPermissionBanner: some View {
        HStack(spacing: 10) {
            Label(Strings.permissionTitle, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(Strings.scrollComparisonPermissionHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(Strings.permissionOpen) {
                AccessibilityPermission.openSystemSettings()
            }
            .controlSize(.small)
            Button(Strings.permissionRecheck) {
                AccessibilityPermission.requestPrompt()
                engine.apply()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

private struct ScrollComparisonPane: View {
    let pane: ScrollComparisonSession.Pane
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isAvailable: Bool
    let unavailableMessage: String?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.1), in: .rect(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(isHovered ? Strings.scrollComparisonActive : Strings.scrollComparisonHover)
                    .font(.caption)
                    .foregroundStyle(isHovered ? tint : Color.secondary.opacity(0.6))
            }

            ZStack {
                comparisonList
                    .scrollDisabled(!isAvailable)

                if let unavailableMessage, !isAvailable {
                    Label(unavailableMessage, systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 9))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
        .padding(14)
        .background(.background.opacity(0.55), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
        .contentShape(.rect)
        .onHover(perform: updateHover)
        .onChange(of: isAvailable) { _, available in
            if !available {
                isHovered = false
                MouseEngine.shared.clearScrollComparisonPane(pane)
            }
        }
        .onDisappear {
            MouseEngine.shared.clearScrollComparisonPane(pane)
        }
        .accessibilityElement(children: .contain)
    }

    private var comparisonList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(1...48, id: \.self) { index in
                    ComparisonRow(index: index, tint: tint)
                }
            }
            .padding(10)
        }
        .scrollIndicators(.visible)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderStyle, lineWidth: isHovered ? 2 : 1)
        }
    }

    private var borderStyle: Color {
        isHovered ? tint.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.5)
    }

    private func updateHover(_ inside: Bool) {
        guard isAvailable else {
            isHovered = false
            MouseEngine.shared.clearScrollComparisonPane(pane)
            return
        }
        isHovered = inside
        if inside {
            MouseEngine.shared.setScrollComparisonPane(pane)
        } else {
            MouseEngine.shared.clearScrollComparisonPane(pane)
        }
    }
}

private struct ComparisonRow: View {
    let index: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index))
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.tertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(tint.opacity(index.isMultiple(of: 5) ? 0.34 : 0.16))
                    .frame(maxWidth: index.isMultiple(of: 3) ? 210 : 260, minHeight: 7, maxHeight: 7)
                Capsule()
                    .fill(.secondary.opacity(0.1))
                    .frame(maxWidth: index.isMultiple(of: 4) ? 130 : 180, minHeight: 5, maxHeight: 5)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(.background.opacity(index.isMultiple(of: 2) ? 0.58 : 0.34), in: .rect(cornerRadius: 8))
    }
}
