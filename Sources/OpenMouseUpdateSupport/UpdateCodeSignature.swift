import CryptoKit
import Foundation
import Security

/// Verifies an update with the running application's own designated requirement.
///
/// A stable signing identity produces the same requirement across releases. This both prevents
/// an unrelated bundle from being installed and is the identity continuity macOS uses for TCC
/// grants such as Accessibility and Input Monitoring.
public enum UpdateCodeSignature {
    public enum ValidationError: LocalizedError {
        case cannotReadCurrentSignature(OSStatus)
        case currentSignatureInvalid(OSStatus)
        case cannotReadCurrentRequirement(OSStatus)
        case cannotReadCandidateSignature(OSStatus)
        case candidateDoesNotMatch(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .cannotReadCurrentSignature(status):
                "无法读取当前应用签名（\(message(for: status))）"
            case let .currentSignatureInvalid(status):
                "当前应用签名或内容已经损坏（\(message(for: status))）"
            case let .cannotReadCurrentRequirement(status):
                "无法读取当前应用身份要求（\(message(for: status))）"
            case let .cannotReadCandidateSignature(status):
                "无法读取下载版本的代码签名（\(message(for: status))）"
            case let .candidateDoesNotMatch(status):
                "下载版本不是由同一发布身份签名（\(message(for: status))）"
            }
        }
    }

    /// SHA-1 of the fixed community release certificate, matching `Scripts/community-signing.sh`
    /// and `Resources/OpenMouseCommunitySigning.cer`. `Scripts/test-community-signature.sh`
    /// asserts this literal still equals the repository certificate, because the two copies
    /// cannot be compared at runtime: the certificate is not bundled.
    ///
    /// Pinned by fingerprint rather than by common name on purpose. A self-signed certificate's
    /// subject is not a claim anyone had to earn — a build signed by a certificate that merely
    /// *calls itself* "Open Mouse Community Signing" must not unlock automatic installation.
    /// The certificate is valid until 2036-08-29; replacing it means updating this literal, and
    /// until then that release must be installed by hand exactly once.
    public static let communitySigningCertificateSHA1 = "0DD76541008E2DD109E45A07942A0A2EBAC48D42"

    /// Whether the build at `applicationURL` may replace itself in place.
    ///
    /// Two identities qualify: Developer ID Application (Apple-issued, notarizable), and the one
    /// pinned community certificate. Apple Development is excluded because it needs a
    /// device-bound provisioning profile, and ad-hoc signatures because their designated
    /// requirement is a per-build cdhash — the next release could never satisfy it.
    ///
    /// This gate only decides what the UI *offers*. What actually protects the swap is
    /// `validate(candidateURL:matchesCurrentAppAt:)`, which requires the download to satisfy the
    /// running bundle's own designated requirement; for a community build that requirement pins
    /// this same certificate. Widening the gate therefore does not widen what gets installed.
    public static func supportsAutomaticInstallation(at applicationURL: URL) -> Bool {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return false }

        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(code, validityFlags, nil)
        guard status == errSecSuccess else { return false }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let values = information as? [CFString: Any],
              let certificates = values[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first else { return false }

        // A missing common name must not veto the fingerprint path, so this is not a `guard`.
        var commonName: CFString?
        let nameStatus = SecCertificateCopyCommonName(leaf, &commonName)
        return signerSupportsAutomaticInstallation(
            commonName: nameStatus == errSecSuccess ? commonName as String? : nil,
            leafSHA1: sha1Fingerprint(of: leaf)
        )
    }

    public static func signerSupportsAutomaticInstallation(
        commonName: String?,
        leafSHA1: String?
    ) -> Bool {
        if commonName?.hasPrefix("Developer ID Application:") == true { return true }
        guard let leafSHA1 else { return false }
        return leafSHA1.caseInsensitiveCompare(communitySigningCertificateSHA1) == .orderedSame
    }

    /// Uppercase hex SHA-1 of the DER certificate — the same digest `openssl x509 -fingerprint
    /// -sha1` and `security find-certificate -Z` print, so it can be compared against the value
    /// the signing scripts pin. SHA-1 is used because it is the format of that pin, not to
    /// establish trust: authenticity comes from the designated-requirement check in `validate`.
    public static func sha1Fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return Insecure.SHA1.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// Why a bundle does or does not qualify for in-app installation.
    ///
    /// `supportsAutomaticInstallation` collapses five distinct failures into `false`, which left
    /// "there is no install button" unanswerable — for the user and for a bug report. This reports
    /// the same decision with the reason attached; the updater exposes it as
    /// `--describe-auto-install`.
    public struct AutomaticInstallationReport: Sendable {
        public let isSupported: Bool
        public let commonName: String?
        public let leafSHA1: String?
        public let detail: String
    }

    public static func describeAutomaticInstallation(at applicationURL: URL) -> AutomaticInstallationReport {
        func report(_ detail: String) -> AutomaticInstallationReport {
            AutomaticInstallationReport(
                isSupported: false,
                commonName: nil,
                leafSHA1: nil,
                detail: detail
            )
        }

        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            return report("无法读取代码签名（\(message(for: status))）")
        }

        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(code, validityFlags, nil)
        guard status == errSecSuccess else {
            return report("签名或内容校验失败（\(message(for: status))）")
        }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess,
              let values = information as? [CFString: Any] else {
            return report("无法读取签名信息（\(message(for: status))）")
        }
        guard let certificates = values[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first else {
            return report("ad-hoc 签名没有证书，指定要求是每次构建都变化的 CDHash")
        }

        var commonName: CFString?
        let nameStatus = SecCertificateCopyCommonName(leaf, &commonName)
        let name = nameStatus == errSecSuccess ? commonName as String? : nil
        let fingerprint = sha1Fingerprint(of: leaf)
        let supported = signerSupportsAutomaticInstallation(commonName: name, leafSHA1: fingerprint)
        return AutomaticInstallationReport(
            isSupported: supported,
            commonName: name,
            leafSHA1: fingerprint,
            detail: supported
                ? "可应用内安装"
                : "签名身份既不是 Developer ID Application，指纹也不是固定社区证书 \(communitySigningCertificateSHA1)"
        )
    }

    public static func validate(candidateURL: URL, matchesCurrentAppAt currentURL: URL) throws {
        var currentCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(currentURL as CFURL, [], &currentCode)
        guard status == errSecSuccess, let currentCode else {
            throw ValidationError.cannotReadCurrentSignature(status)
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(currentCode, flags, nil)
        guard status == errSecSuccess else {
            throw ValidationError.currentSignatureInvalid(status)
        }

        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(currentCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw ValidationError.cannotReadCurrentRequirement(status)
        }

        var candidateCode: SecStaticCode?
        status = SecStaticCodeCreateWithPath(candidateURL as CFURL, [], &candidateCode)
        guard status == errSecSuccess, let candidateCode else {
            throw ValidationError.cannotReadCandidateSignature(status)
        }

        status = SecStaticCodeCheckValidity(candidateCode, flags, requirement)
        guard status == errSecSuccess else {
            throw ValidationError.candidateDoesNotMatch(status)
        }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
