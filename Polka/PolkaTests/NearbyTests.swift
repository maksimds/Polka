import Foundation
import Security
import Testing
@testable import Polka

/// Nearby Sharing, N1: what two Polkas send each other, which names are shown, and
/// the settings. Everything here arrives from another Mac in real use, so most tests
/// feed in what a hostile one might send.
struct NearbyMessageTests {
    private func frame(_ json: String) -> Data {
        let payload = Data(json.utf8)
        let count = payload.count
        return Data([UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF),
                     UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + payload
    }

    @Test func aHelloSurvivesTheWire() throws {
        let hello = NearbyMessage.hello(NearbyHello(version: 1, name: "Alex's MacBook Air"))
        var reader = NearbyFrameReader()
        let payloads = try reader.append(try hello.frame())
        #expect(payloads.count == 1)
        #expect(try NearbyMessage.decode(payloads[0]) == hello)
    }

    @Test func aHelloWithoutANameIsAllowed() throws {
        let hello = NearbyMessage.hello(NearbyHello(version: 1, name: nil))
        var reader = NearbyFrameReader()
        let payloads = try reader.append(try hello.frame())
        #expect(try NearbyMessage.decode(payloads[0]) == hello)
    }

    @Test func aMessageArrivingAByteAtATimeIsReadOnceWhole() throws {
        let data = try NearbyMessage.hello(NearbyHello(version: 1, name: "Sam")).frame()
        var reader = NearbyFrameReader()
        var payloads: [Data] = []
        for byte in data {
            payloads += try reader.append(Data([byte]))
        }
        #expect(payloads.count == 1)
        #expect(try NearbyMessage.decode(payloads[0]) == .hello(NearbyHello(version: 1, name: "Sam")))
    }

    @Test func twoMessagesInOneChunkAreBothRead() throws {
        let one = try NearbyMessage.hello(NearbyHello(version: 1, name: "One")).frame()
        let two = try NearbyMessage.hello(NearbyHello(version: 1, name: "Two")).frame()
        var reader = NearbyFrameReader()
        #expect(try reader.append(one + two).count == 2)
    }

    @Test func aHugeLengthIsRefusedFromItsHeaderAlone() {
        var reader = NearbyFrameReader()
        // Just the 4-byte length, claiming 2 GB: refused before anything is set aside.
        #expect(throws: NearbyFrameReader.Failure.tooLarge(0x7FFF_FFFF)) {
            _ = try reader.append(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        }
    }

    @Test func theLargestAllowedMessageGetsThrough() throws {
        let length = NearbyProtocol.maxMessageBytes
        var reader = NearbyFrameReader()
        let header = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                           UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        #expect(try reader.append(header + Data(count: length)).count == 1)
    }

    @Test func somethingThatIsntJSONIsUnreadable() {
        #expect(throws: NearbyMessage.Failure.unreadable) {
            _ = try NearbyMessage.decode(Data("not json at all".utf8))
        }
    }

    @Test func aTypeThisVersionDoesntKnowIsRefused() {
        #expect(throws: NearbyMessage.Failure.unknownType) {
            _ = try NearbyMessage.decode(Data(#"{"type":"gimme","path":"/etc/passwd"}"#.utf8))
        }
    }

    @Test func aHelloTypeWithoutItsBodyIsUnreadable() {
        #expect(throws: NearbyMessage.Failure.unreadable) {
            _ = try NearbyMessage.decode(Data(#"{"type":"hello"}"#.utf8))
        }
    }

    @Test func anOlderProtocolIsRefused() {
        #expect(throws: NearbyMessage.Failure.tooOld(0)) {
            _ = try NearbyMessage.decode(Data(#"{"type":"hello","hello":{"version":0,"name":"Old"}}"#.utf8))
        }
    }

    @Test func aNewerProtocolIsStillRead() throws {
        let message = try NearbyMessage.decode(Data(#"{"type":"hello","hello":{"version":7,"name":"New"}}"#.utf8))
        #expect(message == .hello(NearbyHello(version: 7, name: "New")))
    }

    @Test func aNameThatIsNothingButInvisibleCharactersIsRefused() {
        #expect(throws: NearbyMessage.Failure.badName) {
            _ = try NearbyMessage.decode(Data(#"{"type":"hello","hello":{"version":1,"name":"​‮\n"}}"#.utf8))
        }
    }

    @Test func aReceivedNameIsCleaned() throws {
        let json = #"{"type":"hello","hello":{"version":1,"name":"  Polka\nSecurity‮  "}}"#
        #expect(try NearbyMessage.decode(Data(json.utf8)) == .hello(NearbyHello(version: 1, name: "Polka Security")))
    }

    @Test func framesFromAnotherWriterAreReadTheSame() throws {
        var reader = NearbyFrameReader()
        let payloads = try reader.append(frame(#"{"type":"hello","hello":{"version":1,"name":"Kim"}}"#))
        #expect(try NearbyMessage.decode(payloads[0]) == .hello(NearbyHello(version: 1, name: "Kim")))
    }
}

struct NearbyNameTests {
    @Test func spacesAroundAreTrimmedAndRunsSqueezed() {
        #expect(NearbyName.clean("  Alex's   MacBook\tAir \n") == "Alex's MacBook Air")
    }

    @Test func aRightToLeftOverrideIsRemoved() {
        // "invoice" + RLO + "fdp.app" reads as "invoiceppa.pdf" on screen.
        #expect(NearbyName.clean("invoice\u{202E}fdp.app") == "invoicefdp.app")
    }

    @Test func isolatesAndZeroWidthCharactersAreRemoved() {
        #expect(NearbyName.clean("A\u{2066}l\u{200B}e\u{2069}x\u{FEFF}") == "Alex")
    }

    @Test func controlCharactersBecomeSpaces() {
        #expect(NearbyName.clean("Line\u{0007}One\u{0000}Two") == "Line One Two")
    }

    @Test func aLongNameIsCutAt40Characters() {
        let name = NearbyName.clean(String(repeating: "a", count: 100))
        #expect(name?.count == 40)
    }

    @Test func charactersAreCountedAsYouSeeThem() {
        // 40 flags, each two code points: all 40 are kept.
        let flags = String(repeating: "🇺🇿", count: 45)
        #expect(NearbyName.clean(flags)?.count == 40)
    }

    @Test func pilesOfCombiningMarksAreCutDown() {
        let zalgo = "Z" + String(repeating: "\u{0301}", count: 50) + "ed"
        let cleaned = NearbyName.clean(zalgo)
        #expect(cleaned?.unicodeScalars.count == 5)
        #expect(cleaned?.hasSuffix("ed") == true)
    }

    @Test func accentedLettersStay() {
        #expect(NearbyName.clean("Zoë's Mac") == "Zoë's Mac")
        #expect(NearbyName.clean("Максим") == "Максим")
    }

    @Test func nothingLeftIsNil() {
        #expect(NearbyName.clean("") == nil)
        #expect(NearbyName.clean("   \n\t") == nil)
        #expect(NearbyName.clean("\u{202E}\u{200B}") == nil)
    }
}

struct NearbySettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func nearbySharingStartsOffReceivingFromEveryone() throws {
        try withDefaults { defaults in
            let settings = ShelfSettings(defaults: defaults)
            #expect(settings.nearbySharingEnabled == false)
            #expect(settings.nearbyReceiveFrom == .everyone)
            #expect(settings.nearbyName == "")
        }
    }

    @Test func choicesAreKept() throws {
        try withDefaults { defaults in
            ShelfSettings(defaults: defaults).nearbySharingEnabled = true
            ShelfSettings(defaults: defaults).nearbyReceiveFrom = .remembered
            ShelfSettings(defaults: defaults).nearbyName = "Studio"
            let settings = ShelfSettings(defaults: defaults)
            #expect(settings.nearbySharingEnabled)
            #expect(settings.nearbyReceiveFrom == .remembered)
            #expect(settings.nearbyName == "Studio")
        }
    }

    @Test func aReceiveFromSetByHandThatPolkaDoesntKnowIsEveryone() throws {
        try withDefaults { defaults in
            defaults.set("friends", forKey: ShelfSettings.nearbyReceiveFromKey)
            #expect(ShelfSettings(defaults: defaults).nearbyReceiveFrom == .everyone)
        }
    }

    @Test func noTypedNameMeansTheMacsName() {
        #expect(ShelfSettings.nearbyName(typed: "", macName: "Maksim's MacBook Air") == "Maksim's MacBook Air")
        #expect(ShelfSettings.nearbyName(typed: "  \n", macName: "Maksim's MacBook Air") == "Maksim's MacBook Air")
        #expect(ShelfSettings.nearbyName(typed: "Studio", macName: "Maksim's MacBook Air") == "Studio")
        #expect(ShelfSettings.nearbyName(typed: "", macName: "\u{202E}") == "Mac")
    }
}

struct NearbyIdentityTests {
    /// A key that only lives in memory, so the test never touches the Keychain.
    private func memoryKey() throws -> SecKey {
        try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ] as CFDictionary, nil))
    }

    @Test func theCertificateIsOneMacOSReadsAndCarriesTheKey() throws {
        let key = try memoryKey()
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let publicData = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let der = try NearbyIdentity.certificate(publicKey: publicData, signer: key)
        let certificate = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))
        #expect(NearbyIdentity.publicKey(of: certificate) == publicData)
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Polka Nearby")
    }

    @Test func theCertificateIsSignedByItsOwnKey() throws {
        let key = try memoryKey()
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let publicData = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let certificate = try #require(SecCertificateCreateWithData(
            nil, Data(try NearbyIdentity.certificate(publicKey: publicData, signer: key)) as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let trustRef = try #require(trust)
        // Trusting it as its own root checks the signature, though nothing else vouches for it.
        #expect(SecTrustSetAnchorCertificates(trustRef, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustEvaluateWithError(trustRef, nil))
    }

    @Test func aFingerprintIsFourGroupsOfFour() throws {
        let fingerprint = NearbyIdentity.fingerprint(of: Data(repeating: 7, count: 65))
        #expect(fingerprint.count == 19)
        #expect(fingerprint.split(separator: " ").map(\.count) == [4, 4, 4, 4])
    }
}

/// Two Nearby Sharing services in this one process, talking over the network as two
/// Macs would (here over loopback or Wi-Fi), each with its own settings and its own
/// throwaway Keychain key.
@MainActor
struct NearbyDiscoveryTests {
    @MainActor
    private struct Side {
        let suite: String
        let defaults: UserDefaults
        let tag: String
        let service: NearbyService

        var settings: ShelfSettings { ShelfSettings(defaults: defaults) }

        init() throws {
            suite = "PolkaTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            tag = "com.maksimds.Polka.tests.nearby.\(UUID().uuidString)"
            service = NearbyService(settings: ShelfSettings(defaults: defaults), identityTag: tag)
        }

        func cleanUp() {
            service.stop()
            NearbyIdentity.delete(tag: tag)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// Waits up to `seconds` for `condition`, checking every tenth of a second.
    private func eventually(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacNearbyIsFoundByItsNameAndHidesItWhenItReceivesOnlyFromRemembered() async throws {
        let shown = try Side()
        let looking = try Side()
        defer {
            shown.cleanUp()
            looking.cleanUp()
        }
        let name = "Polka Test \(Int.random(in: 1000...9999))"
        shown.settings.nearbyName = name

        looking.settings.nearbySharingEnabled = true
        looking.service.start()
        looking.service.beginBrowsing()
        shown.service.start()

        // Off: not advertised, so never found.
        try await Task.sleep(for: .seconds(2))
        #expect(!looking.service.peers.contains { $0.name == name })

        shown.settings.nearbySharingEnabled = true
        let found = try await eventually(20) { looking.service.peers.contains { $0.name == name } }
        #expect(found)
        #expect(looking.service.peers.first { $0.name == name }?.fingerprint != nil)
        #expect(shown.service.status == .on)

        // Remembered Macs only: it advertises anew and answers without its name.
        shown.settings.nearbyReceiveFrom = .remembered
        let hidden = try await eventually(20) { !looking.service.peers.contains { $0.name == name } }
        #expect(hidden)
    }
}
