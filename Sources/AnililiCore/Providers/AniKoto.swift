import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AniKoto: the MegaPlay embed (megaplay.buzz) keyed by AniList id, then MAL id, read for the
/// stream inside, as the Android app's `AnivexaClient.anikoto` does. Miruro's `bee` is the same
/// backend; this is a second way to it.
///
/// ```
/// GET  megaplay.buzz/stream/{ani|mal}/{id}/{ep}/{sub|dub}   -> page with data-id (Referer hianimes.re)
/// GET  {origin}/stream/getSources…?id=&id=                 -> {tracks, intro, outro, enc|sources}
/// ```
///
/// MegaPlay renames its source route on deploys, so the routes are read from its own client
/// script; since 2026-09-17 every route answers an `enc` blob, AES-256-CBC over base64url with
/// the key and IV from that script. A master that's refused gets its `index-f1-v1-a1.m3u8` sibling.
/// Episode counts are a binary search over the aired episodes, two pages per track when complete.
///
/// Not ported: the hianimes site fallback, and the subtitle offset Android applies when a dub
/// borrows the sub encode's file.
public actor AniKoto: StreamProvider {
    public nonisolated let id = "anikoto"
    public nonisolated let name = "AniKoto"

    static let base = "https://megaplay.buzz"
    static let referer = "https://hianimes.re/"
    static let fallbackRoute = "stream/getSources"
    static let scriptLookups = 3
    static let key = "i?LMTAx0Q6,:}50U"
    static let iv = "W0;27ToaUpl_P%'c"

    typealias Fetch = @Sendable (URL, [String: String]) async throws -> (Int, Data)

    private let fetch: Fetch
    private var routes: [String: (at: Date, routes: [String])] = [:]
    private var listings: [Int: (at: Date, listing: EpisodeListing)] = [:]

    static let routeTTL: TimeInterval = 6 * 60 * 60
    static let listingTTL: TimeInterval = 30 * 60

    public init() {
        fetch = { url, headers in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, data)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        if let cached = listings[media.id], Date().timeIntervalSince(cached.at) < Self.listingTTL { return cached.listing }
        let limit = ProviderSupport.airedCount(media)
        let ids = [("ani", media.id)] + (media.idMal.map { [("mal", $0)] } ?? [])
        async let sub = ProviderSupport.highestAvailable(limit) { episode in await self.available(ids, episode, .sub) }
        async let dub = ProviderSupport.highestAvailable(limit) { episode in await self.available(ids, episode, .dub) }
        let listing = ProviderSupport.counts(sub: try await sub, dub: try await dub)
        listings[media.id] = (Date(), listing)
        return listing
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        let track = audio == .dub ? "dub" : "sub"
        var embeds = ["\(Self.base)/stream/ani/\(media.id)/\(episode)/\(track)"]
        if let mal = media.idMal { embeds.append("\(Self.base)/stream/mal/\(mal)/\(episode)/\(track)") }
        // The player page itself follows the stream (Android's "MegaPlay embed"), and stands in
        // for it when the stream can't be read.
        var page: VideoSource?
        for embed in embeds {
            let (source, player) = try await resolve(embed)
            if page == nil, let player { page = VideoSource(url: player, provider: name, server: "MegaPlay", kind: .embed, headers: ["Referer": Self.referer]) }
            if let source {
                Log.info("anikoto", "\(media.id) ep \(episode) \(track): \(source.url.host ?? "?"), \(source.subtitles.count) subtitles")
                return [source] + (page.map { [$0] } ?? [])
            }
        }
        if let page { return [page] }
        throw ProviderError.noStreams(episode: episode, audio: audio)
    }

    // MARK: - Steps

    private func available(_ ids: [(String, Int)], _ episode: Int, _ audio: AudioTrack) async -> Bool {
        for (kind, id) in ids {
            let url = URL(string: "\(Self.base)/stream/\(kind)/\(id)/\(episode)/\(audio == .dub ? "dub" : "sub")")!
            if let answer = try? await fetch(url, ["Referer": Self.referer]), answer.0 == 200,
               MegaPlayParser.pageAvailable(String(decoding: answer.1, as: UTF8.self)) {
                return true
            }
        }
        return false
    }

    /// The stream inside an embed, and the player page that carried a file id (nil when there was
    /// none: the episode isn't there).
    private func resolve(_ address: String) async throws -> (VideoSource?, URL?) {
        var embed = address
        var page = (try? await text(embed, referer: Self.referer)) ?? ""
        if MegaPlayParser.dataAttribute(page, "id") == nil, let iframe = MegaPlayParser.iframe(page) {
            embed = AnimeKaiParser.absolute(embed, iframe)
            page = (try? await text(embed, referer: Self.referer)) ?? page
        }
        guard let fileID = MegaPlayParser.dataAttribute(page, "id"), let embedURL = URL(string: embed),
              let origin = AnimeKaiParser.origin(embedURL) else { return (nil, nil) }
        var metadata: JSON?
        var file: String?
        for route in await routes(origin: origin, embed: embed, page: page) {
            let encoded = fileID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileID
            guard let url = URL(string: "\(origin)/\(route)?id=\(encoded)&id=\(encoded)"),
                  let reply = try? await fetch(url, ["Referer": origin + "/", "X-Requested-With": "XMLHttpRequest"]),
                  reply.0 == 200, let answer = try? JSON.parse(reply.1) else { continue }
            if metadata == nil { metadata = answer }
            if let found = MegaPlayParser.sourceFile(answer) {
                metadata = answer
                file = found
                break
            }
        }
        guard let file, let playable = await playableManifest(file, origin: origin), let url = URL(string: playable) else { return (nil, embedURL) }
        let subtitles = MegaPlayParser.subtitles(metadata, streamURL: playable)
        return (VideoSource(url: url, provider: name, server: "MegaPlay", kind: .hls, headers: ["Referer": origin + "/"],
                            subtitles: subtitles, softSub: !subtitles.isEmpty), embedURL)
    }

    /// The routes MegaPlay's own client script names (longest, i.e. newest, first), then the one
    /// always known. Only a successful discovery is remembered.
    private func routes(origin: String, embed: String, page: String) async -> [String] {
        if let cached = routes[origin], Date().timeIntervalSince(cached.at) < Self.routeTTL { return cached.routes }
        for script in MegaPlayParser.clientScripts(page, embed: embed).prefix(Self.scriptLookups) {
            guard let body = try? await text(script, referer: embed) else { continue }
            let found = MegaPlayParser.sourceRoutes(body)
            if !found.isEmpty {
                var seen = Set<String>()
                let all = (found + [Self.fallbackRoute]).filter { seen.insert($0).inserted }
                routes[origin] = (Date(), all)
                return all
            }
        }
        return [Self.fallbackRoute]
    }

    /// The master when it plays; its single-rendition sibling when the master is refused.
    private func playableManifest(_ file: String, origin: String) async -> String? {
        for candidate in [file, MegaPlayParser.renditionURL(file)].compactMap({ $0 }) {
            if let body = try? await text(candidate, referer: origin + "/"), MegaPlayParser.manifestCanPlay(body) { return candidate }
        }
        return nil
    }

    private func text(_ address: String, referer: String) async throws -> String {
        guard let url = URL(string: address) else { throw HTTPError("Bad MegaPlay URL") }
        let (status, data) = try await fetch(url, ["Referer": referer])
        guard status == 200 else { throw HTTPError(status: status, "MegaPlay answered HTTP \(status)") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Pure handling for MegaPlay pages and answers (Android's `megaPlay…` functions).
enum MegaPlayParser {
    private static let iframeTag = Pattern(#"<iframe\b[^>]*src=["']([^"']+)["']"#)
    private static let errorPage = Pattern(#"<title>\s*Error\b|\berror-container\b"#)
    private static let scriptSrc = Pattern(#"<script\b[^>]*\bsrc=["']([^"']+)["']"#)
    private static let sourceRoute = Pattern(#"["'](stream/getSources[\w/-]*)"#)
    private static let poolPath = Pattern(#"^/anime/[0-9a-f]{32}/[0-9a-f]{32}/"#)

    static func dataAttribute(_ page: String, _ name: String) -> String? {
        Pattern(#"data-\#(NSRegularExpression.escapedPattern(for: name))=["']([^"']*)["']"#).firstMatch(in: page)?[1].map(HTML.decodeEntities)?.nonBlank
    }

    static func iframe(_ page: String) -> String? { iframeTag.firstMatch(in: page)?[1] }

    /// A page that is an episode: no error page, and a file id or an iframe.
    static func pageAvailable(_ page: String) -> Bool {
        !page.isEmpty && !errorPage.contains(in: page) && (dataAttribute(page, "id") != nil || iframe(page) != nil)
    }

    /// Same-origin scripts on the embed page, `newclient` first: where the routes live.
    static func clientScripts(_ page: String, embed: String) -> [String] {
        guard let url = URL(string: embed), let origin = AnimeKaiParser.origin(url) else { return [] }
        var seen = Set<String>()
        return scriptSrc.matches(in: page).compactMap { $0[1].map { AnimeKaiParser.absolute(embed, $0) } }
            .filter { $0.hasPrefix(origin + "/") && seen.insert($0).inserted }
            .sorted { ($0.localizedCaseInsensitiveContains("newclient") ? 0 : 1) < ($1.localizedCaseInsensitiveContains("newclient") ? 0 : 1) }
    }

    /// Every `stream/getSources…` route a script names, longest (newest) first.
    static func sourceRoutes(_ script: String) -> [String] {
        var seen = Set<String>()
        return sourceRoute.matches(in: script).compactMap { $0[1] }.filter { seen.insert($0).inserted }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// The manifest an answer carries: `sources` in the clear (object or one-element array), else
    /// the `enc` blob decrypted.
    static func sourceFile(_ answer: JSON) -> String? {
        if let plain = answer["sources"]?["file"]?.string ?? answer["sources"]?.array?.first?["file"]?.string { return plain }
        guard let blob = answer["enc"]?.string, let decrypted = decrypt(blob),
              let root = try? JSON.parse(Data(decrypted.utf8)) else { return nil }
        return root["file"]?.string
    }

    /// AES-256-CBC over base64url, the key widened to 32 bytes with zeros (not hashed).
    static func decrypt(_ blob: String) -> String? {
        guard let ciphertext = AESCBC.base64URL(blob), !ciphertext.isEmpty else { return nil }
        var key = Data(AniKoto.key.utf8)
        key.append(Data(count: max(0, 32 - key.count)))
        guard let plain = AESCBC.decrypt(ciphertext, key: key.prefix(32), iv: Data(AniKoto.iv.utf8)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// `…/master.m3u8` → `…/index-f1-v1-a1.m3u8`, the file the CDN served when it refused masters.
    static func renditionURL(_ master: String) -> String? {
        let cut = master.firstIndex { $0 == "?" || $0 == "#" } ?? master.endIndex
        let path = master[..<cut]
        guard path.hasSuffix("/master.m3u8") else { return nil }
        return path.dropLast("master.m3u8".count) + "index-f1-v1-a1.m3u8" + master[cut...]
    }

    /// A playlist that names a variant or a segment; a header alone or an error page isn't one.
    static func manifestCanPlay(_ body: String) -> Bool {
        let lines = body.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { return false }
        var expectsURI = false
        for line in lines.dropFirst() {
            if expectsURI, !line.isEmpty, !line.hasPrefix("#") { return true }
            expectsURI = line.hasPrefix("#EXT-X-STREAM-INF:") || line.hasPrefix("#EXTINF:")
        }
        return false
    }

    /// Caption tracks, the default first, moved onto the host the stream came from when both are
    /// pool paths: the pool's hosts are one origin, and some hold subtitle bodies for 10 s.
    static func subtitles(_ answer: JSON?, streamURL: String?) -> [SubtitleTrack] {
        var tracks: [SubtitleTrack] = []
        var seen = Set<URL>()
        for track in answer?["tracks"]?.array ?? [] {
            if let kind = track["kind"]?.string?.lowercased(), kind != "captions", kind != "subtitles" { continue }
            guard let file = track["file"]?.string, let url = URL(string: onStreamHost(file, streamURL)), seen.insert(url).inserted else { continue }
            let label = track["label"]?.string ?? "Subtitle"
            let item = SubtitleTrack(url: url, label: label, language: language(label), isDefault: track["default"]?.bool ?? false)
            if item.isDefault { tracks.insert(item, at: 0) } else { tracks.append(item) }
        }
        return tracks
    }

    static func onStreamHost(_ subtitle: String, _ stream: String?) -> String {
        guard let stream, let subtitleURL = URL(string: subtitle), let streamURL = URL(string: stream),
              subtitleURL.scheme == "https", streamURL.scheme == "https",
              let subtitleHost = subtitleURL.host, let streamHost = streamURL.host, subtitleHost != streamHost,
              poolPath.contains(in: subtitleURL.path), poolPath.contains(in: streamURL.path) else { return subtitle }
        return subtitle.replacingOccurrences(of: "://\(subtitleHost)", with: "://\(streamHost)")
    }

    static func skip(_ answer: JSON?) -> SkipTimes? {
        func window(_ name: String) -> SkipTimes.Window? {
            guard let start = answer?[name]?["start"]?.number, let end = answer?[name]?["end"]?.number, end > start else { return nil }
            return .init(start: start, end: end)
        }
        let skip = SkipTimes(intro: window("intro"), outro: window("outro"))
        return skip.intro == nil && skip.outro == nil ? nil : skip
    }

    static func language(_ label: String) -> String {
        let text = label.lowercased()
        let table: [(String, String)] = [("english", "en"), ("japanese", "ja"), ("indonesian", "id"), ("thai", "th"), ("arabic", "ar"),
                                         ("french", "fr"), ("german", "de"), ("spanish", "es"), ("portuguese", "pt"), ("italian", "it"), ("russian", "ru")]
        return table.first { text.contains($0.0) || text == $0.1 }?.1 ?? "und"
    }
}
