#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Android's backup file (`AppBackup.kt`, format `anilili-backup` v1), read and written field for
/// field so a backup made on either app restores on the other: the settings under Android's keys,
/// the device's watchlist and Continue Watching, search history, custom lists, and, only when the
/// viewer asks, logins sealed under a passphrase the file never contains.
public struct BackupDocument: Codable, Sendable {
    public static let format = "anilili-backup"
    public static let version = 1
    /// A real backup is tens of kilobytes; the cap keeps a wrong pick from reaching the decoder.
    public static let maxBytes = 8 * 1024 * 1024

    public var format = BackupDocument.format
    public var version = BackupDocument.version
    /// Epoch milliseconds.
    public var createdAt: Int64 = 0
    public var appVersion = ""
    public var settings: [String: JSON] = [:]
    public var watchlist: [WatchlistEntry] = []
    public var history: [HistoryEntry] = []
    public var searchHistory: [String] = []
    public var customLists: [CustomList] = []
    public var credentials: SealedCredentials?

    public init() {}

    /// Android's `WatchlistEntry`.
    public struct WatchlistEntry: Codable, Equatable, Sendable {
        public var anilistId: Int
        public var title: String
        public var cover: String?
        public var format: String?
        public var averageScore: Int?
        public var addedAt: Int64

        public init(anilistId: Int, title: String, cover: String?, format: String? = nil, averageScore: Int? = nil, addedAt: Int64 = 0) {
            self.anilistId = anilistId
            self.title = title
            self.cover = cover
            self.format = format
            self.averageScore = averageScore
            self.addedAt = addedAt
        }

        enum CodingKeys: String, CodingKey { case anilistId, title, cover, format, averageScore, addedAt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            anilistId = try c.decode(Int.self, forKey: .anilistId)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            cover = try c.decodeIfPresent(String.self, forKey: .cover)
            format = try c.decodeIfPresent(String.self, forKey: .format)
            averageScore = try c.decodeIfPresent(Int.self, forKey: .averageScore)
            addedAt = try c.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
        }

        // kotlinx requires a nullable field without a default to be present, so nulls are written.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(anilistId, forKey: .anilistId)
            try c.encode(title, forKey: .title)
            try c.encode(cover, forKey: .cover)
            try c.encode(format, forKey: .format)
            try c.encode(averageScore, forKey: .averageScore)
            try c.encode(addedAt, forKey: .addedAt)
        }
    }

    /// Android's `EpisodeResume`.
    public struct EpisodeResume: Codable, Equatable, Sendable {
        public var positionMs: Int64
        public var durationMs: Int64

        public init(positionMs: Int64, durationMs: Int64) {
            self.positionMs = positionMs
            self.durationMs = durationMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            positionMs = try c.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
            durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        }
    }

    /// Android's `HistoryEntry`: one Continue Watching row, episodes as Doubles ("7.5" specials).
    public struct HistoryEntry: Codable, Equatable, Sendable {
        public var anilistId: Int
        public var title: String
        public var cover: String?
        public var episodeNumber: Double
        public var episodeTitle: String?
        public var provider: String
        public var category: String
        public var positionMs: Int64
        public var durationMs: Int64
        public var updatedAt: Int64
        public var watchedEpisodes: [Double]
        public var fromRemote: Bool
        public var resumePoints: [String: EpisodeResume]

        public init(anilistId: Int, title: String, cover: String?, episodeNumber: Double, episodeTitle: String? = nil,
                    provider: String = "auto", category: String = "sub", positionMs: Int64 = 0, durationMs: Int64 = 0,
                    updatedAt: Int64 = 0, watchedEpisodes: [Double] = [], fromRemote: Bool = false, resumePoints: [String: EpisodeResume] = [:]) {
            self.anilistId = anilistId
            self.title = title
            self.cover = cover
            self.episodeNumber = episodeNumber
            self.episodeTitle = episodeTitle
            self.provider = provider
            self.category = category
            self.positionMs = positionMs
            self.durationMs = durationMs
            self.updatedAt = updatedAt
            self.watchedEpisodes = watchedEpisodes
            self.fromRemote = fromRemote
            self.resumePoints = resumePoints
        }

        enum CodingKeys: String, CodingKey {
            case anilistId, title, cover, episodeNumber, episodeTitle, provider, category, positionMs, durationMs
            case updatedAt, watchedEpisodes, fromRemote, resumePoints
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            anilistId = try c.decode(Int.self, forKey: .anilistId)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            cover = try c.decodeIfPresent(String.self, forKey: .cover)
            episodeNumber = try c.decodeIfPresent(Double.self, forKey: .episodeNumber) ?? 1
            episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "auto"
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? "sub"
            positionMs = try c.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
            durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            watchedEpisodes = try c.decodeIfPresent([Double].self, forKey: .watchedEpisodes) ?? []
            fromRemote = try c.decodeIfPresent(Bool.self, forKey: .fromRemote) ?? false
            resumePoints = try c.decodeIfPresent([String: EpisodeResume].self, forKey: .resumePoints) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(anilistId, forKey: .anilistId)
            try c.encode(title, forKey: .title)
            try c.encode(cover, forKey: .cover)
            try c.encode(episodeNumber, forKey: .episodeNumber)
            try c.encode(episodeTitle, forKey: .episodeTitle)
            try c.encode(provider, forKey: .provider)
            try c.encode(category, forKey: .category)
            try c.encode(positionMs, forKey: .positionMs)
            try c.encode(durationMs, forKey: .durationMs)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encode(watchedEpisodes, forKey: .watchedEpisodes)
            try c.encode(fromRemote, forKey: .fromRemote)
            try c.encode(resumePoints, forKey: .resumePoints)
        }
    }

    /// Android's local `CustomList` (a list made while signed out).
    public struct CustomList: Codable, Equatable, Sendable {
        public var name: String
        public var entries: [WatchlistEntry]
        public var createdAt: Int64

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            entries = try c.decodeIfPresent([WatchlistEntry].self, forKey: .entries) ?? []
            createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        }
    }

    /// The logins, under passphrase. `services` stays outside the seal so a restore can say what
    /// it's about to ask the passphrase for; it names services, never accounts.
    public struct SealedCredentials: Codable, Equatable, Sendable {
        public var kdf: String
        public var iterations: Int
        public var salt: String
        public var iv: String
        public var ciphertext: String
        public var services: [String]

        public init(kdf: String = BackupCrypto.kdf, iterations: Int = BackupCrypto.iterations, salt: String, iv: String, ciphertext: String, services: [String]) {
            self.kdf = kdf
            self.iterations = iterations
            self.salt = salt
            self.iv = iv
            self.ciphertext = ciphertext
            self.services = services
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kdf = try c.decodeIfPresent(String.self, forKey: .kdf) ?? BackupCrypto.kdf
            iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? BackupCrypto.iterations
            salt = try c.decodeIfPresent(String.self, forKey: .salt) ?? ""
            iv = try c.decodeIfPresent(String.self, forKey: .iv) ?? ""
            ciphertext = try c.decodeIfPresent(String.self, forKey: .ciphertext) ?? ""
            services = try c.decodeIfPresent([String].self, forKey: .services) ?? []
        }
    }

    /// What's inside the seal (Android's `BackupCredentials`). A MyAnimeList login travels as an
    /// authorization code obtained for whoever restores the file, since MAL rotates refresh tokens
    /// and two devices sharing a pair would sign each other out.
    public struct Credentials: Codable, Equatable, Sendable {
        public var aniListToken: String?
        public var openSubtitlesUsername: String?
        public var openSubtitlesPassword: String?
        public var malCode: String?
        public var malVerifier: String?
        /// Epoch milliseconds the MAL code was obtained.
        public var malIssuedAt: Int64

        public init(aniListToken: String? = nil, malCode: String? = nil, malVerifier: String? = nil, malIssuedAt: Int64 = 0) {
            self.aniListToken = aniListToken
            self.malCode = malCode
            self.malVerifier = malVerifier
            self.malIssuedAt = malIssuedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            aniListToken = try c.decodeIfPresent(String.self, forKey: .aniListToken)
            openSubtitlesUsername = try c.decodeIfPresent(String.self, forKey: .openSubtitlesUsername)
            openSubtitlesPassword = try c.decodeIfPresent(String.self, forKey: .openSubtitlesPassword)
            malCode = try c.decodeIfPresent(String.self, forKey: .malCode)
            malVerifier = try c.decodeIfPresent(String.self, forKey: .malVerifier)
            malIssuedAt = try c.decodeIfPresent(Int64.self, forKey: .malIssuedAt) ?? 0
        }

        public var hasAniList: Bool { aniListToken?.nonBlank != nil }
        public var hasMALHandoff: Bool { malCode?.nonBlank != nil && malVerifier?.nonBlank != nil }
        public var hasOpenSubtitles: Bool { openSubtitlesUsername?.nonBlank != nil && openSubtitlesPassword?.nonBlank != nil }

        public var services: [String] {
            var names: [String] = []
            if hasAniList { names.append("anilist") }
            if hasMALHandoff { names.append("mal") }
            if hasOpenSubtitles { names.append("opensubtitles") }
            return names
        }
    }

    enum CodingKeys: String, CodingKey {
        case format, version, createdAt, appVersion, settings, watchlist, history, searchHistory, customLists, credentials
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.format
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.version
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        settings = try c.decodeIfPresent([String: JSON].self, forKey: .settings) ?? [:]
        watchlist = try c.decodeIfPresent([WatchlistEntry].self, forKey: .watchlist) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        searchHistory = try c.decodeIfPresent([String].self, forKey: .searchHistory) ?? []
        customLists = try c.decodeIfPresent([CustomList].self, forKey: .customLists) ?? []
        credentials = try c.decodeIfPresent(SealedCredentials.self, forKey: .credentials)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(settings, forKey: .settings)
        try c.encode(watchlist, forKey: .watchlist)
        try c.encode(history, forKey: .history)
        try c.encode(searchHistory, forKey: .searchHistory)
        try c.encode(customLists, forKey: .customLists)
        try c.encode(credentials, forKey: .credentials)
    }

    // MARK: - Reading and writing

    public enum BackupError: LocalizedError, Equatable {
        case notABackup(String)
        case newer(Int)
        case wrongPassphrase
        case damaged
        case shortPassphrase

        public var errorDescription: String? {
            switch self {
            case .notABackup(let detail): return "That file isn't an Anilili backup. \(detail)"
            case .newer(let version): return "That backup was written by a newer version of Anilili (format v\(version)). Update the app, then restore it."
            case .wrongPassphrase: return "That passphrase doesn't match this backup."
            case .damaged: return "The logins in that backup are damaged."
            case .shortPassphrase: return "Use a passphrase of at least \(BackupCrypto.minPassphraseLength) characters."
            }
        }
    }

    public static func decode(_ data: Data) throws -> BackupDocument {
        guard !data.isEmpty else { throw BackupError.notABackup("The chosen file is empty.") }
        guard data.count <= maxBytes else { throw BackupError.notABackup("The chosen file is far too large to be one.") }
        let document: BackupDocument
        do {
            document = try JSONDecoder().decode(BackupDocument.self, from: data)
        } catch {
            throw BackupError.notABackup("It isn't the JSON a backup is written as.")
        }
        guard document.format == format else {
            throw BackupError.notABackup("It says it's \"\(document.format)\", not \(format).")
        }
        guard document.version <= version else { throw BackupError.newer(document.version) }
        return document
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Indented, as Android writes it: a backup is a file people open and diff by hand.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// What the sealed section is bound to: this document's format and version.
    public var associatedData: Data { Data("\(format)/\(version)".utf8) }

    /// "31 settings · 12 saved · 8 continue watching", skipping what the file has none of.
    public var summary: String {
        Self.describe(settings: settings.count, watchlist: watchlist.count, history: history.count,
                      searches: searchHistory.count, logins: credentials?.services.count ?? 0, lists: customLists.count)
    }

    public static func describe(settings: Int, watchlist: Int, history: Int, searches: Int, logins: Int, lists: Int) -> String {
        var parts: [String] = []
        if settings > 0 { parts.append("\(settings) setting\(settings == 1 ? "" : "s")") }
        if watchlist > 0 { parts.append("\(watchlist) saved") }
        if lists > 0 { parts.append("\(lists) list\(lists == 1 ? "" : "s")") }
        if history > 0 { parts.append("\(history) continue watching") }
        if searches > 0 { parts.append("\(searches) search\(searches == 1 ? "" : "es")") }
        if logins > 0 { parts.append("\(logins) login\(logins == 1 ? "" : "s")") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " · ")
    }

    /// `Anilili-backup-20261012.json`, as Android names it.
    public static func fileName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return "Anilili-backup-\(formatter.string(from: date)).json"
    }

    // MARK: - Logins

    public mutating func seal(_ credentials: Credentials, passphrase: String) throws {
        guard passphrase.count >= BackupCrypto.minPassphraseLength else { throw BackupError.shortPassphrase }
        let plaintext = try JSONEncoder().encode(credentials)
        var sealed = try BackupCrypto.seal(passphrase: passphrase, plaintext: plaintext, associatedData: associatedData)
        sealed.services = credentials.services
        self.credentials = sealed
    }

    public func openCredentials(passphrase: String) throws -> Credentials? {
        guard let credentials else { return nil }
        let plaintext = try BackupCrypto.open(passphrase: passphrase, sealed: credentials, associatedData: associatedData)
        return try JSONDecoder().decode(Credentials.self, from: plaintext)
    }
}

/// The passphrase lock on a backup's logins (Android's `BackupCrypto`): PBKDF2-HMAC-SHA256 to a
/// 256-bit key, AES-GCM with the 16-byte tag after the ciphertext, as Java's Cipher writes it.
public enum BackupCrypto {
    public static let kdf = "pbkdf2-hmac-sha256"
    /// Recorded in the file rather than assumed, so it can rise without stranding old backups.
    public static let iterations = 210_000
    public static let minPassphraseLength = 8
    static let saltBytes = 16
    static let ivBytes = 12
    static let tagBytes = 16
    /// Crockford-style: no I, L, O, U, so nothing reads as a digit; typeable on a TV remote.
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// `K7M4-9QXR`, so nobody has to invent "password1".
    public static func generatePassphrase() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String((0..<4).map { _ in alphabet.randomElement(using: &generator)! }) }.joined(separator: "-")
    }

    static func seal(passphrase: String, plaintext: Data, associatedData: Data, iterations: Int = iterations) throws -> BackupDocument.SealedCredentials {
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<saltBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let iv = Data((0..<ivBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let key = SymmetricKey(data: deriveKey(passphrase: passphrase, salt: salt, iterations: iterations))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: iv), authenticating: associatedData)
        return BackupDocument.SealedCredentials(iterations: iterations, salt: salt.base64EncodedString(), iv: iv.base64EncodedString(),
                                                ciphertext: (box.ciphertext + box.tag).base64EncodedString(), services: [])
    }

    static func open(passphrase: String, sealed: BackupDocument.SealedCredentials, associatedData: Data) throws -> Data {
        guard sealed.kdf == kdf else { throw BackupDocument.BackupError.notABackup("Its logins were sealed by a newer version of Anilili.") }
        guard !passphrase.isEmpty else { throw BackupDocument.BackupError.wrongPassphrase }
        guard let salt = Data(base64Encoded: sealed.salt), let iv = Data(base64Encoded: sealed.iv),
              let combined = Data(base64Encoded: sealed.ciphertext), iv.count == ivBytes, combined.count >= tagBytes,
              sealed.iterations > 0 else { throw BackupDocument.BackupError.damaged }
        let key = SymmetricKey(data: deriveKey(passphrase: passphrase, salt: salt, iterations: sealed.iterations))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: combined.dropLast(tagBytes), tag: combined.suffix(tagBytes))
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            // A wrong passphrase and a corrupted file are the same event to GCM; name the likely one.
            throw BackupDocument.BackupError.wrongPassphrase
        }
    }

    /// PBKDF2 (RFC 2898) over HMAC-SHA256 to 32 bytes. CommonCrypto's where there is one (fast
    /// enough for 210,000 rounds while the viewer waits); by hand elsewhere, as Android does it.
    static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> Data {
        let password = Data(passphrase.utf8)
        #if canImport(CommonCrypto)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        if status == Int32(kCCSuccess) { return derived }
        #endif
        let key = SymmetricKey(data: password)
        // One SHA-256 block is 32 bytes: exactly one PBKDF2 block.
        var u = Data(HMAC<SHA256>.authenticationCode(for: salt + Data([0, 0, 0, 1]), using: key))
        var accumulated = [UInt8](u)
        for _ in 1..<max(1, iterations) {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for (index, byte) in u.enumerated() { accumulated[index] ^= byte }
        }
        return Data(accumulated)
    }
}
