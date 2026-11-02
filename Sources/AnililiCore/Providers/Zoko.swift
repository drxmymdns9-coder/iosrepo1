import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Zoko (zokoanime.video), ported from the Android app's `ZokoProvider`: an embed page keyed by
/// MAL id, read for the stream inside rather than shown.
///
/// ```
/// GET /stream/mal/{malId}/{episode}/{sub|dub}   -> ~2KB HTML carrying window.__P
/// ```
///
/// `__P` is the whole player configuration: base64 over UTF-8 JSON XOR'd with a fixed key. Inside
/// is a plain HLS master, VTT subtitles and the intro/outro windows. The playlists and segments
/// answer 403 without `Referer: https://zokoanime.video/`, so it travels with the stream.
///
/// There's no episode list: the count is a binary search over the aired episodes, two ~2KB pages
/// per track for a complete title. Uncached segments came slowly on Android (2026-09-26), which is
/// why it isn't a first choice there.
public actor Zoko: StreamProvider {
    public nonisolated let id = "zoko"
    public nonisolated let name = "Zoko"

    typealias Fetch = @Sendable (URL) async throws -> (Int, String)

    private let fetch: Fetch
    private var listings: [Int: (at: Date, listing: EpisodeListing)] = [:]

    static let listingTTL: TimeInterval = 30 * 60

    public init() {
        fetch = { url in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        if let cached = listings[media.id], Date().timeIntervalSince(cached.at) < Self.listingTTL { return cached.listing }
        guard let malID = media.idMal, malID > 0 else { return .empty }
        let limit = ProviderSupport.airedCount(media)
        async let sub = ProviderSupport.highestAvailable(limit) { try await self.hasEpisode(malID, $0, .sub) }
        async let dub = ProviderSupport.highestAvailable(limit) { try await self.hasEpisode(malID, $0, .dub) }
        let listing = ProviderSupport.counts(sub: try await sub, dub: try await dub)
        Log.info("zoko", "\(media.id) (MAL \(malID)): \(listing.subbed.count) sub, \(listing.dubbed.count) dub of \(limit)")
        listings[media.id] = (Date(), listing)
        return listing
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let malID = media.idMal, malID > 0 else { throw ProviderError.titleNotFound(provider: name) }
        guard let payload = ZokoParser.payload(try await page(malID, episode, audio)),
              let source = ZokoParser.source(payload, provider: name) else {
            throw ProviderError.noStreams(episode: episode, audio: audio)
        }
        return [source]
    }

    /// A miss is a 200 with a "Not found." card; anything else that isn't 200 is a failure, so a
    /// network blip isn't learnt as a shorter catalogue.
    private func hasEpisode(_ malID: Int, _ episode: Int, _ audio: AudioTrack) async throws -> Bool {
        ZokoParser.hasPayload(try await page(malID, episode, audio))
    }

    private func page(_ malID: Int, _ episode: Int, _ audio: AudioTrack) async throws -> String {
        let (status, text) = try await fetch(URL(string: "\(ZokoParser.base)/stream/mal/\(malID)/\(episode)/\(audio == .dub ? "dub" : "sub")")!)
        guard status == 200 else { throw HTTPError(status: status, "Zoko answered HTTP \(status) for episode \(episode)") }
        return text
    }
}

/// Pure payload handling for `Zoko`, kept network-free for tests.
enum ZokoParser {
    static let base = "https://zokoanime.video"
    static let referer = base + "/"
    /// The XOR key from the site's own `core/obfuscate.js`. If it changes, `payload` stops
    /// decoding and every episode reads as missing rather than playing garbage.
    static let key = Array("otaku-embed-v1".utf8)
    private static let blob = Pattern(#"window\.__P\s*=\s*"([A-Za-z0-9+/=]+)""#)

    static func hasPayload(_ page: String) -> Bool { blob.firstMatch(in: page) != nil }

    /// The decoded configuration. The site XORs the UTF-8 *bytes*, so a byte-wise XOR is exact.
    static func payload(_ page: String) -> JSON? {
        guard let text = blob.firstMatch(in: page)?[1], var bytes = Data(base64Encoded: text).map([UInt8].init) else { return nil }
        for index in bytes.indices { bytes[index] ^= key[index % key.count] }
        guard let root = try? JSON.parse(Data(bytes)), root.object != nil else { return nil }
        return root
    }

    /// The master with its Referer, and the subtitles with the default first. Every track says
    /// `lang: "en"` whatever it is, so the label names the language.
    static func source(_ payload: JSON, provider: String) -> VideoSource? {
        guard let text = payload["src"]?.string, text.hasPrefix("http"), let url = URL(string: text) else { return nil }
        var seen = Set<String>()
        let subtitles = (payload["subtitles"]?.array ?? [])
            .sorted { ($0["default"]?.bool == true ? 0 : 1) < ($1["default"]?.bool == true ? 0 : 1) }
            .compactMap { track -> SubtitleTrack? in
                guard let address = track["src"]?.string, let url = URL(string: address), seen.insert(address).inserted else { return nil }
                let label = track["label"]?.string?.trimmingCharacters(in: .whitespaces) ?? "Subtitles"
                return SubtitleTrack(url: url, label: label, language: language(label), isDefault: track["default"]?.bool ?? false)
            }
        return VideoSource(url: url, provider: provider, server: "1080p", kind: .hls,
                           headers: ["Referer": referer, "Origin": base], subtitles: subtitles, softSub: !subtitles.isEmpty)
    }

    static func skip(_ payload: JSON) -> SkipTimes? {
        func window(_ name: String) -> SkipTimes.Window? {
            guard let start = payload["skip"]?[name]?["start"]?.number, let end = payload["skip"]?[name]?["end"]?.number, end > start else { return nil }
            return .init(start: start, end: end)
        }
        let skip = SkipTimes(intro: window("intro"), outro: window("outro"))
        return skip.intro == nil && skip.outro == nil ? nil : skip
    }

    /// "Portuguese (Portuguese - Brazilian [Full])" → pt: the first word is the language.
    static func language(_ label: String) -> String {
        let word = label.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map { $0.lowercased() } ?? ""
        let table = ["english": "en", "spanish": "es", "portuguese": "pt", "french": "fr", "german": "de", "italian": "it",
                     "arabic": "ar", "russian": "ru", "indonesian": "id", "korean": "ko", "japanese": "ja", "chinese": "zh",
                     "danish": "da", "dutch": "nl", "finnish": "fi", "norwegian": "no", "polish": "pl", "swedish": "sv",
                     "turkish": "tr", "thai": "th", "vietnamese": "vi", "hindi": "hi", "malay": "ms"]
        return table[word] ?? "und"
    }
}
