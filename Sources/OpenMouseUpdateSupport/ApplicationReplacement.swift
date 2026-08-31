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
