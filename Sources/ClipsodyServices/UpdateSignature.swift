import ClipsodyCore
import CryptoKit
import Foundation
import Security

/// What the signature of a downloaded app says, as far as the installer needs it.
public struct UpdateSignature: Equatable, Sendable {
    /// SHA-256 of the leaf certificate, lowercase hex; nil if the code carries no certificate (ad-hoc).
    public let certificateSHA256: String?
    public let identifier: String?

    public init(certificateSHA256: String?, identifier: String?) {
        self.certificateSHA256 = certificateSHA256
        self.identifier = identifier
    }

    /// Checks the seal of the code at `url` (all architectures, nested code such as the decoder
    /// service, strict) and reads its leaf certificate. Nil if the seal does not verify, so a modified
    /// or unsigned app never gets this far.
    public static func read(at url: URL) -> UpdateSignature? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let signing = info as? [String: Any] else { return nil }
        let leaf = (signing[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let hash = leaf.map { SHA256.hash(data: SecCertificateCopyData($0) as Data) }
        return UpdateSignature(certificateSHA256: hash?.map { String(format: "%02x", $0) }.joined(),
                               identifier: signing[kSecCodeInfoIdentifier as String] as? String)
    }
}
