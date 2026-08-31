import Darwin
import Foundation
import OpenMouseUpdateSupport

enum OpenMouseUpdater {
    enum Failure: LocalizedError {
        case invalidArguments
        case applicationDidNotExit
        case relaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "更新助手参数无效"
            case .applicationDidNotExit: "Open Mouse 未能及时退出"
            case let .relaunchFailed(message): "无法重新启动 Open Mouse：\(message)"
            }
        }
    }

    static func install(arguments: [String]) throws {
        guard arguments.count == 6,
              arguments[1] == "--install",
              let parentPID = pid_t(arguments[2]) else { throw Failure.invalidArguments }

        let source = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let target = URL(fileURLWithPath: arguments[4], isDirectory: true)
        let version = arguments[5]
        let updateWorkspace = source.deletingLastPathComponent().deletingLastPathComponent()
        defer {
            let expectedParent = FileManager.default.temporaryDirectory.standardizedFileURL
            if updateWorkspace.deletingLastPathComponent().standardizedFileURL == expectedParent,
               updateWorkspace.lastPathComponent.hasPrefix("OpenMouseUpdate-") {
                try? FileManager.default.removeItem(at: updateWorkspace)
            }
        }

        try waitForExit(pid: parentPID)
        do {
            // Validate again after the host exits, closing the gap between its validation and
            // the filesystem swap.
            try UpdateCodeSignature.validate(candidateURL: source, matchesCurrentAppAt: target)
            try ApplicationReplacement.replaceApplication(at: target, with: source)
            try relaunch(target: target, flag: "--update-installed", value: version)
        } catch {
            if FileManager.default.fileExists(atPath: target.path) {
                try? relaunch(
                    target: target,
                    flag: "--update-error",
                    value: error.localizedDescription
                )
            }
            throw error
        }
    }

    private static func waitForExit(pid: pid_t) throws {
        let deadline = Date.now.addingTimeInterval(30)
        while kill(pid, 0) == 0 || errno == EPERM {
            guard Date.now < deadline else { throw Failure.applicationDidNotExit }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func relaunch(target: URL, flag: String, value: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", target.path,
            "--args", "--tab", "general", flag, value,
        ]
        do {
            try process.run()
        } catch {
            throw Failure.relaunchFailed(error.localizedDescription)
        }
    }

    static func selfCheck() -> Bool {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "OpenMouseUpdaterCheck-\(UUID().uuidString)")
        let source = root.appending(path: "source/Open Mouse.app")
        let target = root.appending(path: "target/Open Mouse.app")
        defer { try? manager.removeItem(at: root) }

        do {
            try manager.createDirectory(at: source, withIntermediateDirectories: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: source.appending(path: "marker"))
            try Data("old".utf8).write(to: target.appending(path: "marker"))
            try ApplicationReplacement.replaceApplication(at: target, with: source)
            let marker = try String(contentsOf: target.appending(path: "marker"), encoding: .utf8)
            guard marker == "new" else {
                print("✗ 更新助手替换后的内容不正确")
                return false
            }
            print("✓ 更新助手能在同卷暂存、替换并清理旧应用")
            return true
        } catch {
            print("✗ 更新助手自检失败：\(error.localizedDescription)")
            return false
        }
    }
}

if CommandLine.arguments.contains("--self-check") {
    exit(OpenMouseUpdater.selfCheck() ? 0 : 1)
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--validate-signature" {
    do {
        try UpdateCodeSignature.validate(
            candidateURL: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true),
            matchesCurrentAppAt: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        )
        print("✓ 两个应用满足同一指定要求")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("签名身份不连续：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

do {
    try OpenMouseUpdater.install(arguments: CommandLine.arguments)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("OpenMouseUpdater: \(error.localizedDescription)\n".utf8))
    exit(1)
}
