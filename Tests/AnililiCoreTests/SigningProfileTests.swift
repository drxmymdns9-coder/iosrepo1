import Foundation
import Testing
@testable import AnililiCore

struct SigningProfileTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// A made-up profile in its CMS envelope: binary bytes either side of the plist, as on disk.
    private func mobileprovision(_ plist: String) -> Data {
        Data([0x30, 0x82, 0x2F, 0x00, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x0B, 0x00, 0x3C])
    }

    @Test func readsTheDatesFromTheEnvelope() {
        let data = mobileprovision("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key><string>Test App</string>
            <key>CreationDate</key><date>2026-10-12T09:30:00Z</date>
            <key>ExpirationDate</key><date>2026-10-19T09:30:00Z</date>
            <key>TimeToLive</key><integer>7</integer>
        </dict>
        </plist>
        """)
        let profile = SigningProfile(mobileprovision: data)
        #expect(profile == SigningProfile(created: date(12, 9, 30), expires: date(19, 9, 30)))
    }

    @Test func noPlistOrNoExpiryIsNoProfile() {
        #expect(SigningProfile(mobileprovision: Data()) == nil)
        #expect(SigningProfile(mobileprovision: Data([0x30, 0x82, 0x00])) == nil)
        #expect(SigningProfile(mobileprovision: mobileprovision("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>")) == nil)
    }

    @Test func warnsFromTwoDaysOut() {
        let profile = SigningProfile(expires: date(19, 9, 30))
        #expect(!SigningExpiry.shouldWarn(profile, now: date(17, 9, 29)))
        #expect(SigningExpiry.shouldWarn(profile, now: date(17, 9, 30)))
        #expect(SigningExpiry.shouldWarn(profile, now: date(20)))
    }

    @Test func saysHowLongIsLeft() {
        let profile = SigningProfile(expires: date(19, 9, 30))
        #expect(SigningExpiry.remaining(profile, now: date(12, 9, 30)) == "Expires in 7 days")
        #expect(SigningExpiry.remaining(profile, now: date(17, 9, 30)) == "Expires in 2 days")
        #expect(SigningExpiry.remaining(profile, now: date(18, 8)) == "Expires in 1 day")
        #expect(SigningExpiry.remaining(profile, now: date(18, 10)) == "Expires in 23 hours")
        #expect(SigningExpiry.remaining(profile, now: date(19, 8, 30)) == "Expires in 1 hour")
        #expect(SigningExpiry.remaining(profile, now: date(19, 9)) == "Expires in under an hour")
        #expect(SigningExpiry.remaining(profile, now: date(19, 9, 30)) == "Expired")
    }

    @Test func remindsTheMorningOfDaySix() {
        // Signed on the 12th, expiring on the 19th: the reminder is 10:00 on the 18th.
        let profile = SigningProfile(created: date(12, 9, 30), expires: date(19, 9, 30))
        #expect(SigningExpiry.reminderDate(profile, now: date(12, 9, 30), calendar: utc) == date(18, 10))
        // Expiring just after midnight still gives the morning before.
        let early = SigningProfile(expires: date(19, 0, 5))
        #expect(SigningExpiry.reminderDate(early, now: date(12), calendar: utc) == date(18, 10))
        // Too late for a reminder: Home's banner says it instead.
        #expect(SigningExpiry.reminderDate(profile, now: date(18, 10), calendar: utc) == nil)
    }
}
