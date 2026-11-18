import CryptoKit
import Foundation
import Security

/// This Mac's identity for Nearby Sharing: a P-256 key kept in the Keychain, and a
/// self-signed certificate made from it each launch, as the TLS identity both sides
/// present. A Mac is its public key, never its name (PRD, Technical approach).
///
/// The key is made the first time Nearby Sharing is turned on. It lives in the login
/// keychain on this Mac only: a key in the newer, iCloud-capable keychain needs an
/// entitlement that an ad-hoc signed build can't have, and this one never syncs.
struct NearbyIdentity {
    let secIdentity: SecIdentity
    /// The public key in X9.63 form (65 bytes).
    let publicKey: Data

    var fingerprint: String { Self.fingerprint(of: publicKey) }

    /// One key per app, so a test build with its own bundle ID never shares a key with
    /// the daily Polka.
    static var standardTag: String {
        "\(Bundle.main.bundleIdentifier ?? "com.maksimds.Polka").nearby.identity"
    }

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case key
        case certificate
        case identity(OSStatus)

        var description: String {
            switch self {
            case let .keychain(status): return "Keychain error \(status)"
            case .key: return "the key couldn't be made"
            case .certificate: return "the certificate couldn't be made"
            case let .identity(status): return "the identity couldn't be made (\(status))"
            }
        }
    }

    /// Reads this app's key from the Keychain, or makes and saves one, then makes the
    /// certificate and identity. Can wait on a Keychain prompt, so it runs off the main
    /// thread.
    static func loadOrCreate(tag: String) throws -> NearbyIdentity {
        let privateKey = try existingKey(tag: tag) ?? newKey(tag: tag)
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw Failure.key
        }
        let der = try certificate(publicKey: publicData, signer: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw Failure.certificate
        }
        var identity: SecIdentity?
        // Finds the private key that matches the certificate in the Keychain.
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw Failure.identity(status) }
        return NearbyIdentity(secIdentity: identity, publicKey: publicData)
    }

    /// Deletes the key, so the next start makes a new identity. Only tests use it.
    @discardableResult
    static func delete(tag: String) -> OSStatus {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ] as CFDictionary)
    }

    static func publicKey(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    /// The first 8 bytes of the key's SHA-256, as "AB12 CD34 EF56 7890".
    static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { start in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from..<hex.index(from, offsetBy: 4)])
        }.joined(separator: " ")
    }

    // MARK: - Keychain

    private static func existingKey(tag: String) throws -> SecKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { throw Failure.keychain(status) }
        return (item as! SecKey)
    }

    private static func newKey(tag: String) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrLabel as String: "Polka Nearby Sharing",
            ] as [String: Any],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else { throw Failure.key }
        return key
    }

    // MARK: - Self-signed certificate

    /// A minimal X.509 v3 certificate, CN "Polka Nearby", valid 2026 to 2049, signed by
    /// the key itself with ECDSA SHA-256. macOS has no public API that makes one, so
    /// it's written out in DER, X.509's binary form. No authority vouches for it: it
    /// only carries the public key, which is what Polka checks.
    static func certificate(publicKey: Data, signer: SecKey) throws -> [UInt8] {
        let ecdsaWithSHA256 = DER.sequence([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        let name = DER.sequence(DER.tlv(0x31, DER.sequence(
            [0x06, 0x03, 0x55, 0x04, 0x03],
            DER.tlv(0x0C, Array("Polka Nearby".utf8))
        )))
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        // Positive and without a leading zero byte, as DER wants.
        serial[0] = (serial[0] & 0x7F) | 0x01
        let validity = DER.sequence(
            DER.tlv(0x17, Array("260101000000Z".utf8)),
            DER.tlv(0x17, Array("491231235959Z".utf8))
        )
        let subjectPublicKeyInfo = DER.sequence(
            DER.sequence([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01],
                         [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]),
            DER.tlv(0x03, [0x00] + Array(publicKey))
        )
        let toBeSigned = DER.sequence(
            DER.tlv(0xA0, DER.tlv(0x02, [0x02])),
            DER.tlv(0x02, serial),
            ecdsaWithSHA256,
            name,
            validity,
            name,
            subjectPublicKeyInfo
        )
        guard let signature = SecKeyCreateSignature(signer, .ecdsaSignatureMessageX962SHA256,
                                                    Data(toBeSigned) as CFData, nil) as Data? else {
            throw Failure.certificate
        }
        return DER.sequence(toBeSigned, ecdsaWithSHA256, DER.tlv(0x03, [0x00] + Array(signature)))
    }
}

/// Just enough DER to write the certificate above.
private enum DER {
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let count = body.count
        let length: [UInt8] = count < 0x80 ? [UInt8(count)]
            : count <= 0xFF ? [0x81, UInt8(count)]
            : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        return [tag] + length + body
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] {
        tlv(0x30, parts.flatMap { $0 })
    }
}
