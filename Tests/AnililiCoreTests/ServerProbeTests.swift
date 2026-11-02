import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnililiCore

/// Walks every server an episode is offered on, the way AVPlayer would: playlist, variant, key
/// and the first piece of the first segment, under the server's own headers. A report, not a
/// pass/fail suite: `ANILILI_PROBE=1 swift test --filter ServerProbe`.
///
/// Gentle on purpose, so the sites never see a burst from one address: every request waits its
/// turn and a pause, a segment is read only for its first 64 KB, and the titles are few.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANILILI_PROBE"] == "1"), .serialized)
struct ServerProbeTests {
    static let pause: Duration = .milliseconds(700)

    /// (AniList id, episode, why it's here)
    static let titles: [(Int, Int, String)] = [
        (154587, 1, "Frieren, finished, sub and dub"),
        (21, 1100, "One Piece, long runner"),
        (151807, 1, "Solo Leveling, popular dub"),
    ]

    struct Probe {
        var lines: [String] = []
        mutating func say(_ line: String) { lines.append(line); print("PROBE " + line) }
    }

    static func get(_ url: URL, headers: [String: String], range: Bool = false) async -> (Int, String, Data) {
        try? await Task.sleep(for: pause)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(HTTP.safariUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if range { request.setValue("bytes=0-65535", forHTTPHeaderField: "Range") }
        do {
            let (data, response) = try await HTTP.session.data(for: request)
            let http = response as? HTTPURLResponse
            return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type") ?? "?", data)
        } catch {
            return (-1, Log.describe(error), Data())
        }
    }

    /// The playlist's first URI line after `#EXT-X-STREAM-INF`, or the first segment.
    static func firstURI(_ text: String, after tag: String?) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var armed = tag == nil
        for line in lines {
            if let tag, line.hasPrefix(tag) { armed = true; continue }
            if armed, !line.isEmpty, !line.hasPrefix("#") { return line }
        }
        return nil
    }

    /// Where an MPEG-TS stream starts: three sync bytes 188 apart.
    static func syncOffset(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count > 400 else { return nil }
        for index in 0..<(bytes.count - 377) where bytes[index] == 0x47 && bytes[index + 188] == 0x47 && bytes[index + 376] == 0x47 {
            return index
        }
        return nil
    }

    static func keyURI(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("#EXT-X-KEY") && !$0.contains("METHOD=NONE") }),
              let range = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst(5).dropLast())
    }

    static func walk(_ source: VideoSource, _ probe: inout Probe) async {
        let tag = "\(source.label) [\(source.kind.rawValue)] \(source.url.host ?? "?")"
        if source.kind != .hls {
            let (status, type, _) = await get(source.url, headers: source.headers, range: true)
            probe.say("  \(status == 206 || status == 200 ? "OK  " : "FAIL") \(tag): file \(status) \(type)")
            return
        }
        let (status, type, body) = await get(source.url, headers: source.headers)
        let text = String(decoding: body, as: UTF8.self)
        guard status == 200, text.hasPrefix("#EXTM3U") else {
            probe.say("  FAIL \(tag): playlist \(status) \(type) \(text.prefix(80).replacingOccurrences(of: "\n", with: " "))")
            return
        }
        var media = text
        var mediaURL = source.url
        if text.contains("#EXT-X-STREAM-INF"), let uri = firstURI(text, after: "#EXT-X-STREAM-INF"), let url = URL(string: uri, relativeTo: source.url)?.absoluteURL {
            let (vStatus, vType, vBody) = await get(url, headers: source.headers)
            media = String(decoding: vBody, as: UTF8.self)
            mediaURL = url
            guard vStatus == 200, media.hasPrefix("#EXTM3U") else {
                probe.say("  FAIL \(tag): variant \(vStatus) \(vType) at \(url.host ?? "?")")
                return
            }
        }
        var notes: [String] = []
        var keyBytes: Data?
        if let key = keyURI(media), let url = URL(string: key, relativeTo: mediaURL)?.absoluteURL {
            let (kStatus, _, kBody) = await get(url, headers: source.headers)
            keyBytes = kBody
            notes.append("key \(kStatus) \(kBody.count)B")
            if kStatus != 200 {
                probe.say("  FAIL \(tag): key \(kStatus) at \(url.host ?? "?")")
                return
            }
        }
        guard let segment = firstURI(media, after: nil), let url = URL(string: segment, relativeTo: mediaURL)?.absoluteURL else {
            probe.say("  FAIL \(tag): no segment in the media playlist")
            return
        }
        let (sStatus, sType, sBody) = await get(url, headers: source.headers, range: true)
        let ok = (sStatus == 200 || sStatus == 206) && sBody.count > 1000
        let head = sBody.prefix(4).map { String(format: "%02x", $0) }.joined()
        if let keyBytes {
            // Saved for openssl to decrypt: the key, the IV the playlist names (or the media
            // sequence), and the bytes.
            let stem = "/tmp/probe-\(abs(source.url.absoluteString.hashValue))"
            try? sBody.write(to: URL(fileURLWithPath: stem + ".seg"))
            let iv = media.split(whereSeparator: \.isNewline).first { $0.hasPrefix("#EXT-X-KEY") }
                .flatMap { line in line.range(of: #"IV=0x[0-9A-Fa-f]+"#, options: .regularExpression).map { String(line[$0].dropFirst(5)) } }
            let sequence = media.split(whereSeparator: \.isNewline).first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }
                .map { String($0.dropFirst(22)) } ?? "0"
            let keyHex = keyBytes.map { String(format: "%02x", $0) }.joined()
            notes.append("decrypt: \(stem).seg key=\(keyHex) iv=\(iv ?? "seq:" + sequence)")
        } else {
            notes.append("ts@\(syncOffset(sBody).map(String.init) ?? "none")")
        }
        probe.say("  \(ok ? "OK  " : "FAIL") \(tag): segment \(sStatus) \(sType) \(sBody.count)B head \(head) at \(url.host ?? "?") \(notes.joined(separator: " "))")
    }

    @Test func miruroEveryServer() async throws {
        var probe = Probe()
        let miruro = Miruro()
        // ANILILI_PROBE_ONE=1 asks about the first title only, for a quick second look.
        let titles = ProcessInfo.processInfo.environment["ANILILI_PROBE_ONE"] == "1" ? Array(Self.titles.prefix(1)) : Self.titles
        for (id, episode, why) in titles {
            let media = Media(id: id, title: .init(english: why))
            for audio in AudioTrack.allCases {
                try? await Task.sleep(for: Self.pause)
                do {
                    let sources = try await miruro.sources(for: media, episode: episode, audio: audio)
                    probe.say("\(why) ep \(episode) \(audio.rawValue): \(sources.count) sources")
                    for source in sources { await Self.walk(source, &probe) }
                } catch {
                    probe.say("\(why) ep \(episode) \(audio.rawValue): sources failed \(Log.describe(error))")
                }
            }
        }
        // The play response, unfiltered: which providers Miruro offered and in what shape, so a
        // server the parser drops shows up here.
        try? await Task.sleep(for: Self.pause)
        let raw = try await miruro.rawPlay(anilistID: 154587, episode: 1)
        for line in raw { probe.say("raw " + line) }
    }

    /// The servers the app leaves out (Miruro's animepahe/kiwi), walked as if they weren't.
    @Test func miruroLeftOutServers() async throws {
        var probe = Probe()
        let miruro = Miruro()
        let media = Media(id: 154587, title: .init(english: "Frieren"))
        let sources = try await miruro.everySource(anilistID: media.id, episode: 2, audio: .sub)
            .filter { $0.provider.lowercased().contains("pahe") || $0.provider == "kiwi" }
        probe.say("left out: \(sources.map(\.label))")
        for source in sources {
            probe.say("  headers \(source.headers)")
            await Self.walk(source, &probe)
        }
    }

    @Test func animeHeavenSeveralTitles() async throws {
        var probe = Probe()
        let provider = AnimeHeaven()
        for (id, episode, why) in Self.titles {
            try? await Task.sleep(for: Self.pause)
            let media = try await AniListClient.shared.media(id: id)
            do {
                let listing = try await provider.episodes(for: media)
                let numbers = listing.episodes.map(\.number)
                probe.say("AnimeHeaven \(why): \(numbers.count) episodes (\(numbers.first ?? 0)…\(numbers.last ?? 0)), dub \(listing.dubbed.count)")
                let pick = numbers.contains(episode) ? episode : (numbers.first ?? episode)
                try? await Task.sleep(for: Self.pause)
                let sources = try await provider.sources(for: media, episode: pick, audio: .sub)
                for source in sources { await Self.walk(source, &probe) }
            } catch {
                probe.say("AnimeHeaven \(why): failed \(Log.describe(error))")
            }
        }
    }
}

/// The servers ported from Android whose sites aren't behind Cloudflare's fingerprint gate, walked
/// once each on one title. AniChan and Ani.pm are, and are checked from the Mac instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANILILI_PROBE"] == "1"), .serialized)
struct PortedServerProbeTests {
    @Test func zokoAndLili() async throws {
        var probe = ServerProbeTests.Probe()
        try? await Task.sleep(for: ServerProbeTests.pause)
        // ANILILI_PROBE_MEDIA picks another AniList title (AnimeKhor only has Chinese ones).
        let id = Int(ProcessInfo.processInfo.environment["ANILILI_PROBE_MEDIA"] ?? "") ?? 154587
        let frieren = try await AniListClient.shared.media(id: id)
        // ANILILI_PROBE_ONLY=kaa,zoko narrows it to the servers being looked at.
        let only = Set((ProcessInfo.processInfo.environment["ANILILI_PROBE_ONLY"] ?? "").split(separator: ",").map(String.init))
        let all: [any StreamProvider] = [
            Zoko(), Lili(), KickAssAnime(), AnimeKai(), AniKoto(), AniDbApp(), AniZone(), AnimeGG(), UniqueStream(), AnimeAV1(),
            RareAnimes(), AnimeDekho(), ToonHub(), AnimeKhor(),
        ]
        for provider in all where only.isEmpty || only.contains(provider.id) {
            do {
                try? await Task.sleep(for: ServerProbeTests.pause)
                let listing = try await provider.episodes(for: frieren)
                probe.say("\(provider.name): \(listing.subbed.count) sub, \(listing.dubbed.count) dub")
                // The dub-only (Hindi) servers are asked for a dub.
                let audio: AudioTrack = listing.subbed.isEmpty ? .dub : .sub
                guard let first = listing.available(audio).first?.number else { continue }
                try? await Task.sleep(for: ServerProbeTests.pause)
                let sources = try await provider.sources(for: frieren, episode: first, audio: audio)
                // Web players are listed; only the first page is fetched (each is another site).
                for source in sources.filter({ $0.kind == .embed }) {
                    probe.say("  page \(source.label) \(source.url.absoluteString)")
                }
                for source in sources.filter({ $0.kind != .embed }) + sources.filter({ $0.kind == .embed }).prefix(1) {
                    await ServerProbeTests.walk(source, &probe)
                }
            } catch {
                probe.say("\(provider.name): failed \(Log.describe(error))")
            }
        }
    }
}
