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
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
                .drop { $0 == "v" || $0 == "V" }
            // Stop at the first non-version component so "1.2.0-beta.3" compares as 1.2.0.
            let core = trimmed.prefix { $0.isNumber || $0 == "." }
            return core.split(separator: ".").compactMap { Int($0) }
        }
        let lhs = parts(candidate)
        let rhs = parts(current)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
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

    static func check(repository: String, currentVersion: String) async -> Outcome {
        let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, repo.contains("/") else { return .notConfigured }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("仓库地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects unidentified clients on some paths.
        request.setValue("OpenMouse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("无法解析服务器响应")
            }
            switch http.statusCode {
            case 200:
                guard let release = parseRelease(data) else {
                    return .failed("无法解析发布信息")
                }
                return isNewer(release.version, than: currentVersion)
                    ? .available(release)
                    : .upToDate(current: currentVersion)
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
