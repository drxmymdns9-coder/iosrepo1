#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The once-a-day usage ping every Anilili app sends (`docs/USAGE-PING.md`, version 2): a device ID
/// that survives reinstalls, platform, version and build, which list services are signed in and a
/// hash of each account's ID (so one person's devices can be linked), the device, the main
/// settings, and how long the app was in front and playing since the last accepted ping. The
/// server adds the country and city. Always on, with no switch and no entry in Settings.
public enum UsagePing {
    static let endpoint = URL(string: "https://pulse.anilili.workers.dev/v1/ping")!
    static let salt = "anilili-usage-v1:"
    static let personSalt = "anilili-person-v1:"

    /// The UTC day (`yyyy-MM-dd`) of the last accepted ping. This install's only: never backed up.
    public static let dayKey = "usage_ping_day"
    /// The counters since the last accepted ping, as [Counters]. This install's only too.
    public static let countersKey = "usage_counters"

    public enum Platform: String, Sendable {
        case iphone, ipad
    }

    /// The device, as the contract names it.
    public struct Device: Encodable, Equatable, Sendable {
        public var os: String?
        public var maker: String?
        public var model: String?
        public var screen: String?
        public var lang: String?
        public var appLang: String?

        enum CodingKeys: String, CodingKey {
            case os, maker, model, screen, lang
            case appLang = "app_lang"
        }

        public init(os: String? = nil, maker: String? = nil, model: String? = nil, screen: String? = nil, lang: String? = nil,
                    appLang: String? = nil) {
            self.os = os.map { UsagePing.clean($0, max: 24) }
            self.maker = maker.map { UsagePing.clean($0, max: 40) }
            self.model = model.map { UsagePing.clean($0, max: 60) }
            self.screen = screen
            self.lang = lang
            self.appLang = appLang
        }
    }

    /// The app's main settings, under their stored values.
    public struct Choices: Encodable, Equatable, Sendable {
        public var quality: String
        public var theme: String
        public var audio: String
        public var player: String

        public init(quality: String, theme: String, audio: String, player: String) {
            self.quality = quality
            self.theme = theme
            self.audio = audio
            self.player = player
        }
    }

    /// Minutes in front and playing, and openings, since the last accepted ping. Kept as seconds so
    /// short visits add up; sent as whole minutes.
    public struct Counters: Codable, Equatable, Sendable {
        public var frontSeconds: Double = 0
        public var watchedSeconds: Double = 0
        public var sessions: Int = 0

        public init(frontSeconds: Double = 0, watchedSeconds: Double = 0, sessions: Int = 0) {
            self.frontSeconds = frontSeconds
            self.watchedSeconds = watchedSeconds
            self.sessions = sessions
        }

        /// What goes in a ping.
        public var usage: Usage {
            Usage(minutes: min(Int(frontSeconds / 60), 2880), watched: min(Int(watchedSeconds / 60), 2880), sessions: min(sessions, 500))
        }

        /// What is left once `sent` was accepted: whatever was counted while it was on its way.
        public func minus(_ sent: Usage) -> Counters {
            Counters(frontSeconds: max(0, frontSeconds - Double(sent.minutes * 60)),
                     watchedSeconds: max(0, watchedSeconds - Double(sent.watched * 60)),
                     sessions: max(0, sessions - sent.sessions))
        }
    }

    public struct Usage: Encodable, Equatable, Sendable {
        public let minutes: Int
        public let watched: Int
        public let sessions: Int
    }

    public struct Payload: Encodable, Equatable, Sendable {
        public let device: String
        public let platform: String
        public let version: String
        public let build: Int
        public let accounts: [String]
        public let first: Bool
        public let people: [String]
        public let env: Device?
        public let settings: Choices?
        public let usage: Usage?
    }

    /// The ID sent for a raw one: salted, so it matches nothing outside Anilili.
    public static func deviceID(raw: String) -> String {
        hex(salt + raw)
    }

    /// The hash every app makes of a list account: the same account, the same hash, on every device.
    public static func personHash(service: String, id: Int) -> String {
        hex("\(personSalt)\(service):\(id)")
    }

    static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A value as the server takes it: letters, digits, spaces and a few marks, trimmed, at most
    /// `max` characters.
    public static func clean(_ value: String, max: Int) -> String {
        let allowed = Set(" ._+-()/,'&")
        let kept = String(value.map { $0.isLetter || $0.isNumber || allowed.contains($0) ? $0 : " " })
        let collapsed = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    public static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The list services signed in, as the contract names them (iOS has no Simkl).
    public static func accounts(_ credentials: AccountCredentials) -> [String] {
        var accounts: [String] = []
        if credentials.anilistToken != nil { accounts.append("anilist") }
        if credentials.malTokens != nil { accounts.append("mal") }
        return accounts
    }

    /// What to send today, or nil when today's ping was already accepted.
    public static func payload(device: String, platform: Platform, version: String, build: Int, accounts: [String],
                               lastDay: String?, today: String, people: [String] = [], env: Device? = nil,
                               settings: Choices? = nil, usage: Usage? = nil) -> Payload? {
        if lastDay == today { return nil }
        return Payload(device: device, platform: platform.rawValue, version: version, build: build, accounts: accounts,
                       first: lastDay == nil, people: people, env: env, settings: settings, usage: usage)
    }

    /// Sends it; true when the server accepted it.
    public static func send(_ payload: Payload) async -> Bool {
        do {
            let body = try JSONEncoder().encode(payload)
            let (_, response) = try await HTTP.data(endpoint, method: "POST", headers: ["Content-Type": "application/json"], body: body)
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }
}
