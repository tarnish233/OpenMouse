import Foundation

/// `OpenMouse --verbose` prints a line whenever the pipeline counters change.
///
/// A menu bar app has nowhere to show what it is doing, and "my scrolling feels wrong" is
/// impossible to debug from a screenshot. This turns the event pipeline into something you
/// can watch in a terminal, and is how the engine gets verified end to end.
@MainActor
final class VerboseLogger {
    static let shared = VerboseLogger()

    private var timer: Timer?
    private var previous = EngineStats()
    private var lastFrameSource: DisplayLinkTicker.Source = .idle
    private let started = Date()

    private init() {}

    static var isRequested: Bool {
        CommandLine.arguments.contains("--verbose")
    }

    func start() {
        emit("Open Mouse \(AppVersion.displayString) — verbose mode")
        emit("accessibility trusted: \(AccessibilityPermission.isTrusted)")
        emit("engine status: \(MouseEngine.shared.status)")
        let scroll = SettingsStore.shared.preferences.scroll
        let rate = ScrollAxis.rate(forSmoothness: scroll.smoothness)
        emit("scroll: smoothing=\(scroll.smoothingEnabled) minStep=\(scroll.minimumStep) "
            + "speed=\(scroll.speed) smoothness=\(scroll.smoothness) rate=\(rate) "
            + "reverseV=\(scroll.reverseVertical) affectContinuous=\(scroll.affectContinuousDevices)")

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = MouseEngine.shared.stats
        guard now != previous else { return }
        var parts: [String] = []
        if now.wheelEventsSmoothed != previous.wheelEventsSmoothed {
            parts.append("smoothed=\(now.wheelEventsSmoothed)")
        }
        if now.wheelEventsPassedThrough != previous.wheelEventsPassedThrough {
            parts.append("passthrough=\(now.wheelEventsPassedThrough)")
        }
        if now.continuousEventsSeen != previous.continuousEventsSeen {
            parts.append("continuous=\(now.continuousEventsSeen)")
        }
        if now.syntheticEventsPosted != previous.syntheticEventsPosted {
            parts.append("synthesized=\(now.syntheticEventsPosted)")
        }
        if now.wheelEventsUndeliverable != previous.wheelEventsUndeliverable {
            parts.append("UNDELIVERABLE=\(now.wheelEventsUndeliverable)")
        }
        if now.lastTargetPID != previous.lastTargetPID {
            parts.append("targetPID=\(now.lastTargetPID)")
        }
        if now.lastRawDeltaSource != previous.lastRawDeltaSource {
            parts.append("rawFrom=\(now.lastRawDeltaSource.rawValue)")
        }
        if now.buttonActionsFired != previous.buttonActionsFired {
            parts.append("buttonActions=\(now.buttonActionsFired)")
        }
        if MouseEngine.shared.frameSource != lastFrameSource {
            lastFrameSource = MouseEngine.shared.frameSource
            parts.append("frameSource=\(lastFrameSource.rawValue)")
        }
        if let ratio = now.amplification {
            parts.append(String(format: "amplification=%.1fx", ratio))
        }
        previous = now
        guard !parts.isEmpty else { return }
        emit(parts.joined(separator: " "))
    }

    private func emit(_ message: String) {
        let stamp = String(format: "%7.3f", Date().timeIntervalSince(started))
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}
