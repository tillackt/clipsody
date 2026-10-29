import ClippboardCore
import CryptoKit
import Foundation
import Security

/// Builds the code signing requirement the app demands of its decoder service.
enum CodeSigningRequirement {
    /// Same identifier and same leaf certificate as the running app. Nil means the service cannot
    /// be trusted and must not be used at all.
    static func forService(identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let signing = info as? [String: Any] else {
            logger.error("Could not read the app's own signature; the decoder service is not used")
            return nil
        }
        let quotedIdentifier = "identifier \"\(identifier)\""
        if let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            let hex = digest.map { String(format: "%02X", $0) }.joined()
            return "\(quotedIdentifier) and certificate leaf = H\"\(hex)\""
        }
        // Ad-hoc signed: any ad-hoc binary satisfies an identifier requirement. What ties the
        // service to this app is the app's own seal, which records the hash of the nested service,
        // so the whole bundle must verify. This runs once at launch: a service swapped while the app
        // is running is only caught at the next launch.
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            logger.error("The app bundle's seal does not verify; the decoder service is not used")
            return nil
        }
        return quotedIdentifier
    }
}
