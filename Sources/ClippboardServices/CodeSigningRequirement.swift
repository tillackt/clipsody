import ClippboardCore
import CryptoKit
import Foundation
import Security

/// Builds the code signing requirement the app demands of its decoder service.
enum CodeSigningRequirement {
    /// Same identifier and same leaf certificate as the running app. An ad-hoc signed build has no
    /// certificate, so only the identifier can be required; nil if the app's signature is unreadable.
    static func forService(identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let signing = info as? [String: Any] else {
            logger.error("Could not read the app's own signature; decoder service is not pinned")
            return nil
        }
        let quotedIdentifier = "identifier \"\(identifier)\""
        guard let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            return quotedIdentifier
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return "\(quotedIdentifier) and certificate leaf = H\"\(hex)\""
    }
}
