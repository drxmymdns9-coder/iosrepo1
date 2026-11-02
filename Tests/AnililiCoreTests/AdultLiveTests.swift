import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnililiCore

/// The adult servers against the real sites, so off by default:
/// `ANILILI_LIVE=1 swift test --filter AdultLive`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANILILI_LIVE"] == "1"))
struct AdultLiveTests {
    /// Hentai Haven's Cloudflare challenges Linux's OpenSSL fingerprint whatever the User-Agent
    /// (403 "Just a moment…" from WSL on 2026-10-16, while Windows' Schannel got 200 from the same
    /// address), so it is checked live only on Apple's stack, the one the app uses.
    static let reachesHentaiHaven: Bool = {
        #if os(Linux)
        return false
        #else
        return true
        #endif
    }()

    /// AniList's own record for Imaizumin-chi (132203), the title Android's 97fadd44 was verified on.
    private func imaizumi() async throws -> Media {
        let media = try await AniListClient.shared.media(id: 132203)
        #expect(media.isAdult == true)
        print("Live: 132203 status=\(media.status ?? "-") episodes=\(media.episodes.map(String.init) ?? "nil") next=\(media.nextAiringEpisode?.episode ?? -1)")
        return media
    }

    @Test func imaizumiListsEpisodesFromEveryAdultServer() async throws {
        let media = try await imaizumi()
        let providers: [any StreamProvider] = (Self.reachesHentaiHaven ? [HentaiHaven()] : []) + [HStream(), Hanime()]
        for provider in providers {
            let listing = try await provider.episodes(for: media)
            print("Live: \(provider.name) lists \(listing.subbed.sorted()) for 132203")
            #expect(listing.subbed.isSuperset(of: Set(1...6)), "\(provider.name)")
        }
    }

    /// The hub as the app builds it with adult content shown: every server asked, and the episode
    /// list counted from the adult ones because AniList can't count this title.
    @Test func theWholeHubListsImaizumiFromTheAdultServers() async throws {
        let media = try await imaizumi()
        let hub = SourceHub(providers: SourceHub.selectable(hideAdult: false))
        let listing = try await hub.episodes(for: media)
        print("Live: hub lists \(listing.episodes.map(\.number)) for 132203")
        #expect(listing.episodes.count >= 6)
        #expect(listing.episodes.count < 20, "a general server's mismatched listing leaked in")
        #expect(!SourceHub(providers: SourceHub.selectable(hideAdult: true)).providers.contains { SourceHub.isAdultOnly($0.id) })
    }

    @Test(.enabled(if: reachesHentaiHaven))
    func hentaiHavenResolvesAManifestThatServesBare() async throws {
        let media = try await imaizumi()
        let source = try #require(try await HentaiHaven().sources(for: media, episode: 1, audio: .sub).first)
        print("Live: Hentai Haven ep 1 → \(source.url.host ?? "?"), \(source.subtitles.count) subtitle files")
        let master = try await HTTP.text(source.url)
        #expect(master.hasPrefix("#EXTM3U"))
        #expect(StreamRewrite.droppingFileSubtitles(master).contains("#EXT-X-STREAM-INF"))
        if let english = source.subtitles.first(where: { $0.language == "en" }) {
            let cues = try await Subtitles.load(english, headers: [:])
            #expect(cues.count > 20)
        }
    }

    @Test func hstreamResolvesAnMP4AndSubtitlesThatServeBare() async throws {
        let media = try await imaizumi()
        let sources = try await HStream().sources(for: media, episode: 1, audio: .sub)
        let source = try #require(sources.first)
        print("Live: HStream ep 1 → \(sources.map { $0.url.host ?? "?" })")
        var request = URLRequest(url: source.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await HTTP.data(for: request)
        #expect([200, 206].contains(response.statusCode))
        #expect(data.count > 8 && String(decoding: data[4..<8], as: UTF8.self) == "ftyp")
        let english = try #require(source.subtitles.first)
        #expect(try await Subtitles.load(english, headers: [:]).count > 20)
    }
}
