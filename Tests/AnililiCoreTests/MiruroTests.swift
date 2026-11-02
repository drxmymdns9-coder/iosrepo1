import Foundation
import Testing
@testable import AnililiCore

/// Fixtures are Miruro's own responses for Frieren (AniList 154587), captured on 2026-10-11
/// exactly as served: `config` as JSON, the catalog paths masked and gzipped.
struct MiruroTests {
    private func catalog(_ name: String) throws -> JSON {
        try JSON.parse(Miruro.decodeCatalogBody(Fixture.data("miruro/\(name)")))
    }

    private func config() throws -> [Miruro.ProviderConfig] {
        Miruro.parseConfig(try JSON.parse(Fixture.data("miruro/config.json")))
    }

    @Test func configFollowsTheSiteProviderOrder() throws {
        let config = try config()
        #expect(config.prefix(3).map(\.key) == ["icarus", "anikoto", "anidbapp"])
        #expect(config.first { $0.key == "icarus" }?.label == "sun")
        #expect(config.first { $0.key == "allmanga" }?.visible == false)
    }

    @Test func titleCarriesItsIdAndAudioCounts() throws {
        let title = try #require(Miruro.parseTitle(try catalog("title.bin")))
        #expect(title == .init(id: "o2Eqmv4w0JYgQJWQFi9CDDdH-PgffNpm", subCount: 28, dubCount: 28))
    }

    @Test func episodesDropSpecialsAndPreferThePlainSkipWindow() throws {
        let episodes = Miruro.parseEpisodes(try catalog("episodes.bin"))

        // 28 regular rows; the 25 specials numbered 20001… are not part of the run.
        #expect(episodes.map(\.number) == Array(1...28))
        let first = episodes[0]
        #expect(first.title == "The Journey's End")
        #expect(first.thumbnail?.host == "image.tmdb.org")
        #expect(first.duration == 1800)
        #expect(first.isFiller == false)
        // `op` wins over the overlapping `mixed_op`.
        #expect(first.skip?.intro == .init(start: 3.221, end: 93.221))
        #expect(first.skip?.outro == .init(start: 1417.135, end: 1507.135))
    }

    @Test func subSourcesFollowProviderOrderAndSkipWhatCantPlay() throws {
        let every = Miruro.parseSources(config: try config(), play: try catalog("play.bin"), audio: .sub)
        let sources = every.filter { $0.kind != .embed }

        // animepahe (kiwi) plays through the stream proxy since 2026-10-12; aniwaves' embed-only
        // servers have no stream to play.
        // Soft-subbed servers follow the hard-subbed ones; see PlaybackTests for those.
        let hard = sources.filter { !$0.softSub }
        #expect(hard.map(\.label) == ["sun · icarus-2-1", "sun · vault-6-direct-2", "kiwi · animepahe", "knob · Vidplay"])
        #expect(sources.prefix(hard.count).allSatisfy { !$0.softSub })
        #expect(sources.allSatisfy { $0.kind == .hls })
        #expect(sources[0].headers["Referer"] == "https://ultracloud.cc/")
        #expect(sources[0].headers["Origin"] == "https://ultracloud.cc")
        // bun is anikoto's web player: sub has anikoto only soft-subbed, so its pages come from ssub.
        #expect(every.suffix(from: sources.count).map(\.label) == [
            "bun · Vidstream-1 · Web player", "bun · HD-1 · Web player", "bun · Vidstream-2 · Web player",
        ])
        #expect(every.last?.url.absoluteString == "https://megaplay.buzz/stream/s-2/107257/sub")
    }

    @Test func dubSourcesComeFromTheDubTrackOnly() throws {
        let sources = Miruro.parseSources(config: try config(), play: try catalog("play.bin"), audio: .dub)

        #expect(sources.map(\.label) == [
            "sun · icarus-1-1", "sun · vault-6-direct-1", "bee · Vidstream-1", "bee · HD-1", "hop · Vid", "knob · Vidplay",
            "bun · Vidstream-1 · Web player", "bun · HD-1 · Web player", "bun · Vidstream-2 · Web player",
        ])
        #expect(sources.filter { $0.kind == .embed }.allSatisfy { $0.url.host == "megaplay.buzz" })
    }

    @Test func listingCountsSayWhatIsOutInEachAudio() {
        let episodes = (1...12).map(EpisodeInfo.init(number:))

        let airing = Miruro.listing(episodes: episodes, title: .init(id: "x", subCount: 10, dubCount: 4))
        #expect(airing.available(.sub).map(\.number) == Array(1...10))
        #expect(airing.available(.dub).map(\.number) == Array(1...4))

        let unknown = Miruro.listing(episodes: episodes, title: .init(id: "x", subCount: nil, dubCount: nil))
        #expect(unknown.subbed.count == 12)
        #expect(unknown.dubbed.isEmpty)
    }

    @Test func walksToTheNextMirrorOnlyWhenOneIsDown() async throws {
        let calls = Calls()
        let provider = Miruro { url, _ in
            calls.append(url.host ?? "")
            if url.host == "www.miruro.to" { throw HTTPError(status: 502, "bad gateway") }
            if url.path.hasSuffix("/config") { return (try Fixture.data("miruro/config.json"), "application/json") }
            if url.path.hasSuffix("/play") { return (try Fixture.data("miruro/play.bin"), "application/octet-stream") }
            return (try Fixture.data("miruro/title.bin"), "application/octet-stream")
        }
        let media = Media(id: 154587, title: .init(english: "Frieren"))

        let sources = try await provider.sources(for: media, episode: 1, audio: .sub)

        #expect(sources.filter { !$0.softSub && $0.kind != .embed }.count == 4)
        // The first mirror failed once; after that the one that answered is asked first.
        #expect(calls.hosts == ["www.miruro.to", "www.miruro.tv", "www.miruro.tv", "www.miruro.tv"])
    }

    @Test func aClientErrorIsTheAnswerNotAMirrorFailure() async throws {
        let calls = Calls()
        let provider = Miruro { url, _ in
            calls.append(url.host ?? "")
            throw HTTPError(status: 403, "blocked")
        }

        await #expect(throws: HTTPError.self) {
            try await provider.episodes(for: Media(id: 1, title: .init(english: "x")))
        }
        #expect(calls.hosts == ["www.miruro.to"])
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var hosts: [String] { lock.withLock { stored } }
        func append(_ host: String) { lock.withLock { stored.append(host) } }
    }
}

struct GzipTests {
    @Test func decodesStoredFixedAndDynamicBlocks() throws {
        let plain = try Fixture.data("gzip/plain.json")
        #expect(try Gzip.decompress(Fixture.data("gzip/stored.gz")) == plain)
        #expect(try Gzip.decompress(Fixture.data("gzip/dynamic.gz")) == Data((0..<20).flatMap { _ in plain }))
        #expect(try Gzip.decompress(Fixture.data("gzip/fixed.gz")) == Data(#"{"ok":true,"n":[1,2,3]}"#.utf8))
    }

    @Test func rejectsWhatIsNotGzip() {
        #expect(throws: Gzip.Failure.notGzip) { try Gzip.decompress(Data("{}".utf8)) }
    }
}

struct SourceHubTests {
    private struct Fake: StreamProvider {
        var id: String
        var name: String { id }
        var listing: EpisodeListing?
        var sources: [VideoSource] = []
        var delay: Duration = .zero

        func episodes(for media: Media) async throws -> EpisodeListing {
            try await Task.sleep(for: delay)
            guard let listing else { throw HTTPError("\(id) is down") }
            return listing
        }

        func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
            try await Task.sleep(for: delay)
            guard listing != nil else { throw HTTPError("\(id) is down") }
            return sources
        }
    }

    private struct Spanish: StreamProvider {
        var id: String { "es" }
        var name: String { "es" }
        var declaredLanguage: String? { "Spanish" }
        let found: [VideoSource]
        func episodes(for media: Media) async throws -> EpisodeListing { .empty }
        func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] { found }
    }

    /// Android's declared languages: last unless asked for, then first.
    @Test(.serialized) func aDeclaredLanguageLeadsOnlyWhenAskedFor() async throws {
        let english = Fake(id: "en", listing: .empty, sources: [source("en")])
        let hub = SourceHub(providers: [Spanish(found: [source("es")]), english])
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TrackLanguage.subtitleKey)
        defer { defaults.set(saved, forKey: TrackLanguage.subtitleKey) }
        defaults.set("", forKey: TrackLanguage.subtitleKey)
        #expect(try await hub.sources(for: media, episode: 1, audio: .sub).map(\.server) == ["en", "es"])
        defaults.set("spa", forKey: TrackLanguage.subtitleKey)
        #expect(try await hub.sources(for: media, episode: 1, audio: .sub).map(\.server) == ["es", "en"])
    }

    /// A server that hangs mustn't hold the player for the full timeout once a better-ranked one
    /// has answered; one ranked above the answer is still waited for.
    @Test func aStragglerIsLeftBehindAfterTheGrace() async throws {
        let quick = Fake(id: "quick", listing: .empty, sources: [source("q")])
        let hanging = Fake(id: "hanging", listing: .empty, sources: [source("h")], delay: .seconds(12))
        let started = ContinuousClock.now
        let found = try await SourceHub(providers: [quick, hanging]).sources(for: media, episode: 1, audio: .sub)
        #expect(found.map(\.server) == ["q"])
        #expect(ContinuousClock.now - started < .seconds(4))

        let slowLeader = Fake(id: "lead", listing: .empty, sources: [source("l")], delay: .milliseconds(600))
        let ranked = try await SourceHub(providers: [slowLeader, quick]).sources(for: media, episode: 1, audio: .sub)
        #expect(ranked.map(\.server) == ["l", "q"], "the leader is waited for, the one behind it is kept")
    }

    private let media = Media(id: 1, title: .init(english: "x"))

    /// Settings → Servers: off is off, pinned go first, and all-off falls back to everything.
    @Test func serversFollowTheViewersArrangement() {
        let providers: [any StreamProvider] = [Fake(id: "a"), Fake(id: "b"), Fake(id: "c")]
        #expect(SourceHub.arranged(providers, disabled: ["b"], priority: []).map(\.id) == ["a", "c"])
        #expect(SourceHub.arranged(providers, disabled: [], priority: ["c", "gone"]).map(\.id) == ["c", "a", "b"])
        #expect(SourceHub.arranged(providers, disabled: ["c"], priority: ["c", "b"]).map(\.id) == ["b", "a"])
        #expect(SourceHub.arranged(providers, disabled: ["a", "b", "c"], priority: []).map(\.id) == ["a", "b", "c"])
    }

    private func source(_ server: String) -> VideoSource {
        VideoSource(url: URL(string: "https://cdn.test/\(server).m3u8")!, provider: "p", server: server, kind: .hls)
    }

    @Test func theFirstListingLeadsAndTheOthersFillIn() async throws {
        var rich = EpisodeListing(episodes: (1...2).map(EpisodeInfo.init(number:)), subbed: [1, 2], dubbed: [1])
        rich.episodes[0].title = "Pilot"
        let wider = EpisodeListing(episodes: (1...3).map(EpisodeInfo.init(number:)), subbed: [1, 2, 3], dubbed: [])
        let hub = SourceHub(providers: [Fake(id: "a", listing: rich), Fake(id: "b", listing: wider)])

        let listing = try await hub.episodes(for: media)

        #expect(listing.episodes.map(\.number) == [1, 2, 3])
        #expect(listing.episodes[0].title == "Pilot")
        #expect(listing.subbed == [1, 2, 3])
        #expect(listing.dubbed == [1])
    }

    @Test func oneProviderDownIsNotAFailure() async throws {
        let up = EpisodeListing(episodes: [EpisodeInfo(number: 1)], subbed: [1], dubbed: [])
        let hub = SourceHub(providers: [Fake(id: "down"), Fake(id: "up", listing: up, sources: [source("s1")])])

        #expect(try await hub.episodes(for: media) == up)
        #expect(try await hub.sources(for: media, episode: 1, audio: .sub).map(\.server) == ["s1"])
    }

    @Test func everyProviderDownThrows() async {
        let hub = SourceHub(providers: [Fake(id: "a"), Fake(id: "b")])
        await #expect(throws: HTTPError.self) { try await hub.episodes(for: media) }
        await #expect(throws: HTTPError.self) { try await hub.sources(for: media, episode: 1, audio: .sub) }
    }

    @Test func sourcesKeepProviderOrder() async throws {
        let listing = EpisodeListing(episodes: [EpisodeInfo(number: 1)], subbed: [1], dubbed: [])
        let hub = SourceHub(providers: [
            Fake(id: "a", listing: listing, sources: [source("a1"), source("a2")]),
            Fake(id: "b", listing: listing, sources: [source("b1")]),
        ])

        #expect(try await hub.sources(for: media, episode: 1, audio: .sub).map(\.server) == ["a1", "a2", "b1"])
    }
}
