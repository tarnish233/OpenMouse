import AppKit

// Hidden end-to-end probe for the private Dock-swipe encoder. Unlike `--self-check`, this
// intentionally changes the current Space and therefore only runs when requested explicitly.
// Keeping the probe inside the signed app is important: a throwaway command-line binary does
// not inherit Open Mouse's Accessibility authorization and produces a misleading no-op.
if let index = CommandLine.arguments.firstIndex(of: "--dock-swipe-test") {
    let direction = index + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[index + 1]
        : "right"
    let sign: Double = direction == "left" ? -1 : 1
    let steps = 25
    let step = sign * 1.5 / Double(steps)

    DockSwipeEventPoster.post(DockSwipeFrame(
        axis: .horizontal,
        phase: .began,
        progress: step,
        exitSpeed: 0
    ))
    for frame in 2...steps {
        Thread.sleep(forTimeInterval: 0.008)
        DockSwipeEventPoster.post(DockSwipeFrame(
            axis: .horizontal,
            phase: .changed,
            progress: step * Double(frame),
            exitSpeed: 0
        ))
    }
    DockSwipeEventPoster.post(DockSwipeFrame(
        axis: .horizontal,
        phase: .ended,
        progress: sign * 1.5,
        exitSpeed: step * 100
    ))
    // WindowServer consumes posted events asynchronously. Exiting immediately is a known source
    // of false negatives when testing synthetic system shortcuts and gestures.
    Thread.sleep(forTimeInterval: 0.7)
    exit(0)
}

// `OpenMouse --self-check` runs the pure-logic assertions and exits, without starting the
// UI or touching the event tap. Used by `make test`.
if CommandLine.arguments.contains("--self-check") {
    exit(SelfCheck.run() ? 0 : 1)
}

// `OpenMouse --check-update <owner/repo>` exercises the real network path and exits, so the
// updater can be verified without waiting for the daily automatic check.
if let index = CommandLine.arguments.firstIndex(of: "--check-update") {
    let override = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : ""
    let repository = override.hasPrefix("-") || override.isEmpty ? UpdateSettings.repository : override
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task {
        let outcome = await UpdateChecker.check(repository: repository, currentVersion: AppVersion.short)
        switch outcome {
        case .notConfigured:
            print("未配置更新源（需要 owner/repo）")
        case let .upToDate(current):
            print("已是最新版本: \(current)")
            code = 0
        case let .available(release):
            print("发现新版本: \(release.version)")
            print("  发布页: \(release.url)")
            code = 0
        case let .failed(message):
            print("检查失败: \(message)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(code)
}

// `NSApplication.delegate` is a weak reference, so the delegate has to be kept alive by
// something else — here, a top-level binding that lives for the process.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }

// Top-level code already runs on the main thread; `assumeIsolated` states that to the
// compiler without an extra hop.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = appDelegate
    // Menu-bar-only utility: no Dock icon, no window at launch.
    app.setActivationPolicy(.accessory)
    app.run()
}
