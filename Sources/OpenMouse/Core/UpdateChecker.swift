import Foundation

/// Checks GitHub Releases for a newer build.
///
/// Deliberately not Sparkle: Sparkle needs an EdDSA key pair, a hosted appcast and a signed
/// archive per release. This app is distributed as a repo you build yourself, so the honest
/// mechanism is "ask GitHub what the latest tag is, and if it is newer, point at the release
/// page". No auto-install, no update keys to lose, nothing running with elevated rights.
enum UpdateChecker {
    struct Release: Codable, Equatable, Sendable {
        var version: String
        var name: String
        var notes: String
        var url: URL
        var publishedAt: Date?
        var isPrerelease: Bool
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

    /// Parses the payload of `GET /repos/{owner}/{repo}/releases/latest`.
    /// Split out from the network call so the parsing can be checked without a request.
    static func parseRelease(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tag = root["tag_name"] as? String,
              let urlString = root["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }

        var published: Date?
        if let stamp = root["published_at"] as? String {
            published = ISO8601DateFormatter().date(from: stamp)
        }
        return Release(
            version: tag,
            name: (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: (root["body"] as? String) ?? "",
            url: url,
            publishedAt: published,
            isPrerelease: (root["prerelease"] as? Bool) ?? false
        )
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
        guard !repo.isEmpty, repo.contains("/") else { return .notConfigured }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("仓库地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects unidentified clients on some paths.
        request.setValue("OpenMouse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: sessionConfiguration())
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("无法解析服务器响应")
            }
            switch http.statusCode {
            case 200:
                guard let release = parseRelease(data) else {
                    return .failed("无法解析发布信息")
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
                return .failed("请求被限流（403），请稍后再试")
            default:
                return .failed("服务器返回 \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
