import Foundation

/// The provisioning profile a sideloading tool (Sideloadly, SideStore, AltStore) embeds as
/// `embedded.mobileprovision` when it signs the app. A free Apple ID's lasts 7 days, after which
/// iOS won't open the app until it's signed again. Builds with no profile (the simulator, TrollStore,
/// an unsigned IPA) have nothing to expire.
public struct SigningProfile: Equatable, Sendable {
    public var created: Date?
    public var expires: Date

    public init(created: Date? = nil, expires: Date) {
        self.created = created
        self.expires = expires
    }

    /// The file is a CMS envelope with the profile's XML plist inside it as plain bytes, so the
    /// plist is cut out rather than the signature unwrapped.
    public init?(mobileprovision data: Data) {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let expires = plist["ExpirationDate"] as? Date else { return nil }
        self.init(created: plist["CreationDate"] as? Date, expires: expires)
    }
}

/// When to warn that the signature is running out, and what to say.
public enum SigningExpiry {
    /// Home shows its banner from this long before the profile expires.
    public static let warningLead: TimeInterval = 2 * 86_400
    /// The reminder goes out at this hour on the day before expiry: day 6 of a free Apple ID's 7.
    public static let reminderHour = 10

    public static func shouldWarn(_ profile: SigningProfile, now: Date) -> Bool {
        profile.expires.timeIntervalSince(now) <= warningLead
    }

    /// "Expires in 2 days", "Expires in 5 hours", "Expired".
    public static func remaining(_ profile: SigningProfile, now: Date) -> String {
        let left = profile.expires.timeIntervalSince(now)
        if left <= 0 { return "Expired" }
        if left < 3600 { return "Expires in under an hour" }
        if left < 86_400 {
            let hours = Int(left / 3600)
            return "Expires in \(hours) hour\(hours == 1 ? "" : "s")"
        }
        let days = Int(left / 86_400)
        return "Expires in \(days) day\(days == 1 ? "" : "s")"
    }

    /// `reminderHour` on the calendar day before the expiry day, or nil once that has passed
    /// (Home's banner covers it then).
    public static func reminderDate(_ profile: SigningProfile, now: Date, calendar: Calendar = .current) -> Date? {
        let expiryDay = calendar.startOfDay(for: profile.expires)
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: expiryDay),
              let reminder = calendar.date(bySettingHour: reminderHour, minute: 0, second: 0, of: dayBefore),
              reminder > now else { return nil }
        return reminder
    }
}
