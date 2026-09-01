import Foundation

/// Replaces an application bundle on the same volume with rollback if the final move fails.
public enum ApplicationReplacement {
    public enum ReplacementError: LocalizedError {
        case invalidSource
        case invalidTarget
        case targetMissing

        public var errorDescription: String? {
            switch self {
            case .invalidSource: "下载版本的应用路径无效"
            case .invalidTarget: "当前应用的安装路径无效"
            case .targetMissing: "当前应用已经不在原安装位置"
            }
        }
    }

    /// Why the running bundle cannot replace itself where it currently sits.
    ///
    /// Both cases are about *location*, not about the download, so they are checked before
    /// spending a download: the outcome cannot change no matter what the archive contains.
    public enum LocationProblem: Equatable, Sendable {
        /// Gatekeeper ran the app from a read-only App Translocation mount.
        case translocated
        /// The bundle sits somewhere its container cannot be written (a mounted disk image, a
        /// volume the user cannot write to).
        case containerNotWritable

        public var errorDescription: String {
            switch self {
            case .translocated:
                "请先把 Open Mouse 拖到「应用程序」文件夹再更新：现在运行的是 macOS 为下载文件创建的只读副本"
            case .containerNotWritable:
                "当前安装位置不可写，请把 Open Mouse 移动到「应用程序」文件夹再更新"
            }
        }
    }

    /// App Translocation mounts a quarantined app read-only under a path containing
    /// `AppTranslocation`, so replacing the bundle there either fails or "succeeds" against a
    /// throwaway copy while the real app stays put. `SecTranslocateIsTranslocatedURL` is not
    /// surfaced in the Swift Security overlay, and the path marker is the same signal it reports.
    public static func isTranslocated(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains("AppTranslocation")
    }

    /// `isWritable` is injected so the rule itself is testable without a fixture on disk.
    public static func locationProblem(
        for target: URL,
        isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    ) -> LocationProblem? {
        if isTranslocated(target) { return .translocated }
        guard isWritable(target.standardizedFileURL.deletingLastPathComponent()) else {
            return .containerNotWritable
        }
        return nil
    }

    public static func replaceApplication(at targetURL: URL, with sourceURL: URL) throws {
        let manager = FileManager.default
        let source = sourceURL.standardizedFileURL
        let target = targetURL.standardizedFileURL

        guard source.isFileURL, source.pathExtension == "app", source != target else {
            throw ReplacementError.invalidSource
        }
        guard target.isFileURL, target.pathExtension == "app", target.lastPathComponent == "Open Mouse.app" else {
            throw ReplacementError.invalidTarget
        }
        guard manager.fileExists(atPath: target.path) else { throw ReplacementError.targetMissing }

        let parent = target.deletingLastPathComponent()
        let nonce = UUID().uuidString
        let staged = parent.appending(path: ".OpenMouse-update-\(nonce).app")
        let backup = parent.appending(path: ".OpenMouse-backup-\(nonce).app")

        try manager.copyItem(at: source, to: staged)
        do {
            try manager.moveItem(at: target, to: backup)
            do {
                try manager.moveItem(at: staged, to: target)
            } catch {
                try? manager.moveItem(at: backup, to: target)
                throw error
            }
            try? manager.removeItem(at: backup)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }
}
