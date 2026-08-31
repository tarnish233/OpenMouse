import Foundation

/// Checks GitHub Releases for a newer build without using the rate-limited REST API.
///
/// Deliberately not Sparkle: Sparkle needs an EdDSA key pair, a hosted appcast and a signed
/// archive per release. This app is distributed as a repo you build yourself, so the honest
/// mechanism is "follow GitHub's latest-release redirect, compare its tag, then point at that
/// page". No API token, no auto-install, no update keys to lose, and nothing running with
/// elevated rights.
enum UpdateChecker {
    struct Release: Codable, Equatable, Sendable {
        var version: String
        var url: URL
    }

    enum Outcome: Equatable, Sendable {
        case notConfigured
        case upToDate(current: String)
        case available(Release)
        case failed(String)
    }

    /// Compares dotted numeric versions, ignoring a leading `v` and any suffix.
    /// `1.10.0` sorts above `1.9.9`, which a string comparison would get wrong.
    static func isNewer(_ candidate: String, than current: String) -> Bool? {
        func parts(_ text: String) -> [UInt64]? {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
            // Stop at the first suffix component so "1.2.0-beta.3" compares as 1.2.0, but
            // reject empty/overflowing numeric components instead of compacting them away.
            let core = trimmed.prefix { $0.isNumber || $0 == "." }
            guard !core.isEmpty else { return nil }
            let components = core.split(separator: ".", omittingEmptySubsequences: false)
            guard !components.isEmpty else { return nil }
            var result: [UInt64] = []
            result.reserveCapacity(components.count)
            for component in components {
                guard !component.isEmpty, let value = UInt64(component) else { return nil }
                result.append(value)
            }
            return result
        }
        guard let lhs = parts(candidate), let rhs = parts(current) else { return nil }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func repositoryComponents(_ repository: String) -> [String]? {
        let components = repository
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }
        return components
    }

    /// GitHub redirects this stable page to `/releases/tag/<version>`. It is a normal web
    /// request, so every installed copy does not compete for the REST API's anonymous IP quota.
    static func latestReleasePageURL(repository: String) -> URL? {
        guard let components = repositoryComponents(repository),
              let github = URL(string: "https://github.com") else { return nil }
        return github
            .appending(path: components[0])
            .appending(path: components[1])
            .appending(path: "releases")
            .appending(path: "latest")
    }

    /// Extracts the tag only from the expected repository's final GitHub release URL. Keeping
    /// this strict prevents a proxy or an unexpected redirect from becoming an update link.
    static func release(from redirectedURL: URL, repository: String) -> Release? {
        guard let repository = repositoryComponents(repository),
              redirectedURL.scheme?.lowercased() == "https",
              redirectedURL.host?.lowercased() == "github.com" else { return nil }

        let path = redirectedURL.pathComponents.filter { $0 != "/" }
        guard path.count == 5,
              path[0].caseInsensitiveCompare(repository[0]) == .orderedSame,
              path[1].caseInsensitiveCompare(repository[1]) == .orderedSame,
              path[2] == "releases",
              path[3] == "tag" else { return nil }

        let tag = path[4].removingPercentEncoding ?? path[4]
        guard !tag.isEmpty else { return nil }
        return Release(version: tag, url: redirectedURL)
    }

    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        // Unlike the per-request idle timeout, this caps the whole response lifetime, so a
        // server that trickles bytes cannot keep UpdateCoordinator.isChecking latched forever.
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    static func check(repository: String, currentVersion: String) async -> Outcome {
        let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return .notConfigured }
        guard let url = latestReleasePageURL(repository: repo) else { return .failed("仓库地址无效") }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = requestTimeout
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("OpenMouse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: sessionConfiguration())
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("无法解析服务器响应")
            }
            switch http.statusCode {
            case 200:
                guard let finalURL = http.url,
                      let release = release(from: finalURL, repository: repo) else {
                    return .failed("无法从 GitHub Releases 重定向解析版本")
                }
                guard let isNewer = isNewer(release.version, than: currentVersion) else {
                    return .failed(
                        "无法比较版本号（当前：\(currentVersion)，发布：\(release.version)）"
                    )
                }
                return isNewer ? .available(release) : .upToDate(current: currentVersion)
            case 404:
                return .failed("仓库或发布不存在（404）")
            case 403:
                return .failed("GitHub 拒绝了请求（403），请稍后再试")
            case 429:
                return .failed("GitHub 请求过于频繁（429），请稍后再试")
            default:
                return .failed("服务器返回 \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
