import Foundation
import Testing
@testable import AnililiCore

/// Nostr signatures and announcements, against the live-signed events in Android's tests
/// (`NostrManifestVerificationTest`, `AnnouncementTest`).
struct AnnouncementTests {
    static let update = #"{"content":"{\"version\":\"0.1.54\",\"changelog\":\"Grouped downloads by series, pinned caption appearance preview, robust stream resolution fallback for embeds & HLS, and cold-start recovery.\",\"apkUrl\":\"https://github.com/kompoti121/Anilili/releases/latest/download/Anilili.apk\",\"sizeBytes\":15022786}","created_at":1785533738,"id":"5a06c71dc1b40ae21b0b32b9f958627c0f305b55c6b44fd639454b209e95933d","kind":30078,"pubkey":"f1abd1ac685aed1f5145271283cd9418bf13aa92ed26399df191ae0c08b22207","sig":"fe9c7200df30a27345f55c3f6485be84a565bbf4b9c68231c1eb378ec48fd77c9631513c144931b832d0dd75a54bc99b70ffb322adbb6dc24f8d7cfa1110b94e","tags":[["d","anilili-update"]]}"#
    static let announcement = #"{"id":"1a3e007da72179bb5cae37be96c334c06b58e1c9670541a9bf528a823e705d65","pubkey":"f1abd1ac685aed1f5145271283cd9418bf13aa92ed26399df191ae0c08b22207","created_at":1788559744,"kind":30078,"tags":[["d","anilili-announcement"]],"content":"{\"id\":\"test-signing-loop\",\"title\":\"Sources are down\",\"message\":\"Not your device - the provider is having an outage.\",\"url\":\"https://example.test/status\",\"urlLabel\":\"Status page\",\"severity\":\"emergency\",\"maxVersion\":\"0.1.99\"}","sig":"701f8435a36433c0543abd0c9dc1889c954b91b3691cee7f7d2e5493f6c37c3264ea29714a0ad71b4d36b32ce4bf4b1102a4c18f08fa177638beb8cbf8b694d9"}"#

    private func event(_ text: String) throws -> NostrEvent {
        try #require(NostrEvent(json: try JSON.parse(Data(text.utf8))))
    }

    @Test func theCurveArithmeticHolds() throws {
        // lift_x of the generator's x gives the generator (its y is even), and n·G is infinity.
        let g = try #require(Curve.liftX(Curve.generator.x))
        #expect(Curve.affine(g)?.y == Curve.generator.y)
        #expect(Curve.multiply(Curve.generator, by: Curve.n).isInfinity)
        let two = Curve.affine(Curve.double(Curve.generator))
        let sum = Curve.affine(Curve.add(Curve.generator, Curve.generator))
        #expect(two?.x == sum?.x && two?.y == sum?.y)
        #expect(Field.mul(Field.inverse(U256(limbs: [12345, 0, 0, 0])), U256(limbs: [12345, 0, 0, 0])) == .one)
    }

    @Test func theProjectsSignedEventsVerify() throws {
        let manifest = try event(Self.update)
        #expect(manifest.computedID == manifest.id)
        #expect(manifest.isValidSigned(dTag: "anilili-update"))
        let notice = try event(Self.announcement)
        #expect(notice.isValidSigned(dTag: Announcement.dTag))
        // Each channel is its own: a manifest isn't an announcement, nor the other way round.
        #expect(!manifest.isValidSigned(dTag: Announcement.dTag))
        #expect(!notice.isValidSigned(dTag: "anilili-update"))
    }

    @Test func forgeriesAreRefused() throws {
        var tampered = try event(Self.announcement)
        tampered.content = tampered.content.replacingOccurrences(of: "outage", with: "update now")
        #expect(!tampered.isValidSigned(dTag: Announcement.dTag), "content changed, id no longer matches")

        var reIDed = tampered
        reIDed.id = reIDed.computedID
        #expect(!reIDed.isValidSigned(dTag: Announcement.dTag), "a matching id without the key's signature")

        var badSig = try event(Self.announcement)
        badSig.sig = String(badSig.sig.dropLast()) + (badSig.sig.hasSuffix("9") ? "8" : "9")
        #expect(!badSig.isValidSigned(dTag: Announcement.dTag))

        var impostor = try event(Self.announcement)
        impostor.pubkey = String(repeating: "0", count: 64)
        #expect(!impostor.isValidSigned(dTag: Announcement.dTag))
    }

    @Test func announcementsReadLikeAndroid() throws {
        let parsed = try #require(Announcement.from(event: try JSON.parse(Data(Self.announcement.utf8))))
        #expect(parsed.id == "test-signing-loop")
        #expect(parsed.title == "Sources are down")
        #expect(parsed.urgent)
        #expect(parsed.url == "https://example.test/status")
        #expect(parsed.urlLabel == "Status page")
        #expect(parsed.maxVersion == "0.1.99")
        // Bounded to Android builds, so not for this app.
        #expect(!parsed.applies(now: 1_790_000_000))

        #expect(Announcement.parse(#"{"title":"x","message":"y"}"#) == nil)
        #expect(Announcement.parse(#"{"id":"a","message":"  "}"#) == nil)
        let plain = try #require(Announcement.parse(#"{"id":"a","message":"hello","url":"http://x.test","expiresAt":100}"#))
        #expect(plain.title == "Anilili")
        #expect(!plain.urgent)
        #expect(plain.url == nil, "only https links")
        #expect(plain.applies(now: 99))
        #expect(!plain.applies(now: 101))
        #expect(Announcement.parse(#"{"id":"a","message":"m","url":"javascript:alert(1)"}"#)?.url == nil)
        #expect(Announcement.parse(#"{"id":"a","message":"m"}"#)?.applies(now: .max) == true)
    }
}
