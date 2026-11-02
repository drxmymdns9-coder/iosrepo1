#if canImport(UIKit)
import AnililiCore
import Foundation
import Security
import UIKit

/// The daily usage ping (`docs/USAGE-PING.md`, version 2), tried at launch and on each return to
/// the app; at most one is accepted a day. Always on: Settings → App says what is sent. It also
/// keeps the counters the ping reports: seconds in front and playing, and openings (a launch, or a
/// return after five minutes away), since the last accepted ping.
@MainActor
enum UsageReporter {
    private static var sending = false
    private static var frontSince: Date?
    private static var awaySince: Date?
    private static var playingSince: Date?

    /// Away this long, coming back is a new session.
    private static let sessionGap: TimeInterval = 5 * 60

    // MARK: - Counting

    /// The app is in front (launch, or the scene became active).
    static func cameToFront(_ now: Date = Date()) {
        guard frontSince == nil else { return }
        if awaySince.map({ now.timeIntervalSince($0) >= sessionGap }) ?? true {
            update { $0.sessions += 1 }
        }
        frontSince = now
    }

    /// The app went to the background.
    static func wentAway(_ now: Date = Date()) {
        if let since = frontSince { update { $0.frontSeconds += now.timeIntervalSince(since) } }
        frontSince = nil
        awaySince = now
        // Picture in picture plays on with the app away; what played so far is banked now.
        if let since = playingSince { update { $0.watchedSeconds += now.timeIntervalSince(since) } }
        if playingSince != nil { playingSince = now }
    }

    /// The player started or stopped (`PlayerEngine`).
    static func playing(_ isPlaying: Bool, _ now: Date = Date()) {
        if isPlaying, playingSince == nil {
            playingSince = now
        } else if !isPlaying, let since = playingSince {
            update { $0.watchedSeconds += now.timeIntervalSince(since) }
            playingSince = nil
        }
    }

    private static var counters: UsagePing.Counters {
        get {
            UserDefaults.standard.data(forKey: UsagePing.countersKey)
                .flatMap { try? JSONDecoder().decode(UsagePing.Counters.self, from: $0) } ?? UsagePing.Counters()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: UsagePing.countersKey) }
        }
    }

    private static func update(_ change: (inout UsagePing.Counters) -> Void) {
        #if DEBUG
        return
        #else
        var c = counters
        change(&c)
        counters = c
        #endif
    }

    // MARK: - The ping

    static func check() {
        #if DEBUG
        return
        #else
        guard !sending else { return }
        let defaults = UserDefaults.standard
        let today = UsagePing.utcDay(Date())
        let lastDay = defaults.string(forKey: UsagePing.dayKey)
        guard lastDay != today else { return }
        _ = AccountStore.shared  // loads the sign-ins from the Keychain
        sending = true
        Task {
            defer { sending = false }
            let info = Bundle.main.infoDictionary
            let usage = counters.usage
            guard let payload = UsagePing.payload(
                device: UsagePing.deviceID(raw: rawDeviceID()),
                platform: UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone,
                version: info?["CFBundleShortVersionString"] as? String ?? "0.0",
                build: Int(info?["CFBundleVersion"] as? String ?? "") ?? 0,
                accounts: UsagePing.accounts(AccountCredentials.shared),
                lastDay: lastDay,
                today: today,
                people: await people(),
                env: device(),
                settings: choices(),
                usage: usage
            ) else { return }
            if await UsagePing.send(payload) {
                defaults.set(today, forKey: UsagePing.dayKey)
                // Only what was sent goes: what was counted while it was on its way stays.
                counters = counters.minus(usage)
            }
        }
        #endif
    }

    /// One hash per signed-in list account, AniList then MAL, of the account's numeric ID.
    /// AniList's is in its token; MAL's is asked for, and left out until the next ping when it
    /// can't be had.
    private static func people() async -> [String] {
        var people: [String] = []
        if let id = AccountCredentials.shared.anilistToken.flatMap(AniListAuth.viewerID), id > 0 {
            people.append(UsagePing.personHash(service: "anilist", id: id))
        }
        if AccountCredentials.shared.malTokens != nil {
            do {
                let id = try await MALClient.shared.viewer().id
                if id > 0 { people.append(UsagePing.personHash(service: "mal", id: id)) }
            } catch {
                Log.info("usage", "no MAL id for the usage ping: \(error)")
            }
        }
        return people
    }

    /// The device: its system, the hardware model (`iPhone15,2`), the screen in pixels as held
    /// upright, the system's first language and the app's.
    private static func device() -> UsagePing.Device {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let size = UIScreen.main.nativeBounds.size
        let screen = "\(Int(min(size.width, size.height)))x\(Int(max(size.width, size.height)))"
        return UsagePing.Device(os: UIDevice.current.systemVersion, maker: "Apple", model: model, screen: screen,
                                lang: Locale.preferredLanguages.first, appLang: MenuLanguage.usesSpanish ? "es" : "en")
    }

    /// The main settings, under the keys and stored values the app shares with Android.
    private static func choices() -> UsagePing.Choices {
        let defaults = UserDefaults.standard
        return UsagePing.Choices(
            quality: defaults.string(forKey: DefaultQuality.key) ?? DefaultQuality.fallback.rawValue,
            theme: defaults.string(forKey: "theme_background") ?? ThemeBackground.amoled.rawValue,
            audio: defaults.bool(forKey: Setting.preferDub) ? "dub" : "sub",
            player: defaults.bool(forKey: Setting.openInExternalPlayer) ? "external" : "internal"
        )
    }

    private static let service = "com.anilili.ios.usage"
    private static let fallbackKey = "usage_device_fallback"

    /// A random ID kept in the Keychain, which outlives the app, so a reinstall is the same device.
    /// This device only and never synced: an iCloud Keychain copy would make two phones one.
    /// Without the Keychain (an unsigned simulator build), it lives in the app's defaults instead.
    private static func rawDeviceID() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        if let id = UserDefaults.standard.string(forKey: fallbackKey) { return id }
        let id = UUID().uuidString
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device",
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.warning("usage", "Keychain unavailable (OSStatus \(status)); the device ID won't survive a reinstall")
            UserDefaults.standard.set(id, forKey: fallbackKey)
        }
        return id
    }
}
#endif
