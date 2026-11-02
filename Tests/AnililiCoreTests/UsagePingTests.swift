import Foundation
import Testing
@testable import AnililiCore

/// The once-a-day ping's rules (`docs/USAGE-PING.md`), shared with Android and the desktop.
struct UsagePingTests {
    static let device = String(repeating: "a", count: 64)

    @Test func theDeviceIDIsTheSaltedHashEveryAppMakes() {
        // The same vector is in Android's and the desktop's tests.
        #expect(UsagePing.deviceID(raw: "9774d56d682e549c") == "0eb0cde3e2356397f8217597eace93a803af7fcf676c9fa42d98c23a5f7f5b97")
    }

    @Test func thePersonHashIsTheOneEveryAppMakes() {
        // The same vector is in Android's and the desktop's tests and in docs/USAGE-PING.md.
        #expect(UsagePing.personHash(service: "anilist", id: 123456) == "79f2ba9972b3e2f1fb4ee6ce0e47fe7ca11faa2c8d7d435eed44eac40f938860")
        #expect(UsagePing.personHash(service: "anilist", id: 123456) != UsagePing.personHash(service: "mal", id: 123456))
    }

    @Test func daysAreUTC() {
        // 23:30 on Oct 11 in New York is already Oct 12 in UTC.
        #expect(UsagePing.utcDay(Date(timeIntervalSince1970: 1_791_775_800)) == "2026-10-12")
        #expect(UsagePing.utcDay(Date(timeIntervalSince1970: 0)) == "1970-01-01")
    }

    @Test func accountsNameServicesNotPeople() {
        let credentials = AccountCredentials()
        #expect(UsagePing.accounts(credentials).isEmpty)
        credentials.anilistToken = "token"
        #expect(UsagePing.accounts(credentials) == ["anilist"])
        credentials.malTokens = MALAuth.Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        #expect(UsagePing.accounts(credentials) == ["anilist", "mal"])
    }

    @Test func onceADay() {
        #expect(UsagePing.payload(device: Self.device, platform: .iphone, version: "0.1.0", build: 3, accounts: [],
                                  lastDay: "2026-10-12", today: "2026-10-12") == nil)
    }

    @Test func firstOnlyWithoutAnEarlierPing() throws {
        let fresh = try #require(UsagePing.payload(device: Self.device, platform: .ipad, version: "0.1.0", build: 3, accounts: [],
                                                   lastDay: nil, today: "2026-10-12"))
        #expect(fresh.first && fresh.platform == "ipad")
        let returning = try #require(UsagePing.payload(device: Self.device, platform: .iphone, version: "0.1.0", build: 3, accounts: [],
                                                       lastDay: "2026-09-30", today: "2026-10-12"))
        #expect(!returning.first)
    }

    @Test func theBodyUsesTheContractsNames() throws {
        let payload = try #require(UsagePing.payload(device: Self.device, platform: .iphone, version: "0.1.0", build: 7,
                                                     accounts: ["anilist", "mal"], lastDay: "2026-09-30", today: "2026-10-01"))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(Set(object.keys) == ["device", "platform", "version", "build", "accounts", "first", "people"])
        #expect(object["device"] as? String == Self.device)
        #expect(object["platform"] as? String == "iphone")
        #expect(object["version"] as? String == "0.1.0")
        #expect(object["build"] as? Int == 7)
        #expect(object["accounts"] as? [String] == ["anilist", "mal"])
        #expect(object["first"] as? Bool == false)
    }

    @Test func versionTwoCarriesPeopleTheDeviceSettingsAndUsage() throws {
        let payload = try #require(UsagePing.payload(
            device: Self.device, platform: .iphone, version: "0.0.3", build: 4, accounts: ["anilist"],
            lastDay: "2026-10-12", today: "2026-10-13", people: [String(repeating: "ab", count: 32)],
            env: UsagePing.Device(os: "18.0", maker: "Apple", model: "iPhone15,2", screen: "1179x2556", lang: "sq-XK", appLang: "en"),
            settings: UsagePing.Choices(quality: "highest", theme: "amoled", audio: "sub", player: "internal"),
            usage: UsagePing.Usage(minutes: 95, watched: 60, sessions: 3)
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let env = try #require(object["env"] as? [String: Any])
        #expect(env["model"] as? String == "iPhone15,2")
        #expect(env["app_lang"] as? String == "en")
        #expect((object["settings"] as? [String: Any])?["quality"] as? String == "highest")
        let usage = try #require(object["usage"] as? [String: Any])
        #expect(usage["minutes"] as? Int == 95 && usage["watched"] as? Int == 60 && usage["sessions"] as? Int == 3)
        #expect(object["people"] as? [String] == [String(repeating: "ab", count: 32)])
    }

    @Test func countersAreSentAsWholeMinutesAndWhatCameAfterIsKept() {
        let counters = UsagePing.Counters(frontSeconds: 125, watchedSeconds: 59, sessions: 2)
        #expect(counters.usage == UsagePing.Usage(minutes: 2, watched: 0, sessions: 2))
        // Sent while 30 more seconds and another opening were counted.
        let later = UsagePing.Counters(frontSeconds: 155, watchedSeconds: 59, sessions: 3)
        #expect(later.minus(counters.usage) == UsagePing.Counters(frontSeconds: 35, watchedSeconds: 59, sessions: 1))
    }

    @Test func valuesAreCleanedForTheServer() {
        #expect(UsagePing.clean("  Dell   Inc.™ ", max: 40) == "Dell Inc.")
        #expect(UsagePing.clean("Micro-Star International Co., Ltd.", max: 24) == "Micro-Star International")
        #expect(UsagePing.Device(model: "iPhone15,2").model == "iPhone15,2")
    }
}
