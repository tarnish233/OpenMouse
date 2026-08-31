import Foundation
import OpenMouseUpdateSupport

/// Downloads, extracts and validates a release before handing it to the independent updater.
enum UpdateInstaller {
    struct PreparedUpdate: Sendable {
        let candidateAppURL: URL
        let helperURL: URL
        let targetAppURL: URL
        let version: String
    }

    enum Failure: LocalizedError {
        case invalidDownloadURL
        case unexpectedResponse
        case serverStatus(Int)
        case malformedArchive
        case extractionFailed(Int32)
        case invalidBundleIdentifier
        case unexpectedVersion(expected: String, actual: String)
        case missingUpdater
        case updaterNotExecutable

        var errorDescription: String? {
            switch self {
            case .invalidDownloadURL: "无法生成更新包下载地址"
            case .unexpectedResponse: "无法解析更新服务器响应"
            case let .serverStatus(status): "下载服务器返回 \(status)"
            case .malformedArchive: "更新包中没有有效的 Open Mouse 应用"
            case let .extractionFailed(status): "无法解压更新包（ditto 退出码 \(status)）"
            case .invalidBundleIdentifier: "更新包的应用标识不匹配"
            case let .unexpectedVersion(expected, actual):
                "更新包版本不匹配（期望 \(expected)，实际 \(actual)）"
            case .missingUpdater: "当前应用缺少更新安装助手"
            case .updaterNotExecutable: "更新安装助手不可执行"
            }
        }
    }

    static func prepare(
        release: UpdateChecker.Release,
        repository: String,
        currentBundleURL: URL
    ) async throws -> PreparedUpdate {
        guard let downloadURL = UpdateChecker.archiveURL(for: release, repository: repository) else {
            throw Failure.invalidDownloadURL
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "OpenMouseUpdate-\(UUID().uuidString)")
        let archive = root.appending(path: "update.zip")
        let extracted = root.appending(path: "extracted")

        do {
            try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try await download(from: downloadURL, to: archive)
            try await run(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])

            let candidate = extracted.appending(path: "Open Mouse.app")
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw Failure.malformedArchive
            }

            guard let bundle = Bundle(url: candidate),
                  bundle.bundleIdentifier == "com.openmouse.OpenMouse" else {
                throw Failure.invalidBundleIdentifier
            }
            let actualVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? AppVersion.unknown
            guard UpdateChecker.versionsMatch(release.version, actualVersion) else {
                throw Failure.unexpectedVersion(expected: release.version, actual: actualVersion)
            }

            try UpdateCodeSignature.validate(
                candidateURL: candidate,
                matchesCurrentAppAt: currentBundleURL
            )

            let bundledHelper = currentBundleURL
                .appending(path: "Contents")
                .appending(path: "Helpers")
                .appending(path: "OpenMouseUpdater")
            guard manager.fileExists(atPath: bundledHelper.path) else { throw Failure.missingUpdater }
            guard manager.isExecutableFile(atPath: bundledHelper.path) else {
                throw Failure.updaterNotExecutable
            }
            let helper = root.appending(path: "OpenMouseUpdater")
            try manager.copyItem(at: bundledHelper, to: helper)

            return PreparedUpdate(
                candidateAppURL: candidate,
                helperURL: helper,
                targetAppURL: currentBundleURL,
                version: actualVersion
            )
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    static func launch(_ update: PreparedUpdate, parentPID: Int32) throws {
        let process = Process()
        process.executableURL = update.helperURL
        process.arguments = [
            "--install",
            String(parentPID),
            update.candidateAppURL.path,
            update.targetAppURL.path,
            update.version,
        ]
        try process.run()
    }

    private static func download(from url: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 5 * 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("OpenMouse/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        guard http.statusCode == 200 else { throw Failure.serverStatus(http.statusCode) }
        // URLSession owns its temporary download and may remove it as soon as this method
        // returns. Move it into our update workspace while the session is still alive.
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private static func run(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure.extractionFailed(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
