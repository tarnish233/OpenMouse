import AppKit

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
            print("发现新版本: \(release.version) (\(release.name))")
            print("  预发布: \(release.isPrerelease)")
            print("  发布页: \(release.url)")
            if let date = release.publishedAt { print("  发布于: \(date)") }
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
