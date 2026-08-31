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
