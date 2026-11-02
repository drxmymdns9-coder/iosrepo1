import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnililiCore

/// Android's `KickAssAnimeProviderTest`, on its fixtures, and the audio hint iOS adds.
struct KickAssAnimeTests {
    private func json(_ text: String) throws -> JSON { try JSON.parse(Data(text.utf8)) }

    @Test func catalogEpisodesPlayerAndSoftSubtitlesParse() throws {
        let candidate = try #require(KickAssAnimeCodec.searchResults(try json(
            #"{"result":[{"slug":"show-1234","title":"Show","title_en":"Show EN","locales":["ja-JP","en-US"]}]}"#)).first)
        #expect(candidate.slug == "show-1234")
        #expect(candidate.title == "Show EN")
        #expect(candidate.locales == ["ja-JP", "en-US"])
        #expect(candidate.year == nil)

        let episodes = try json(#"{"pages":[{"eps":[1,2,3]}],"result":[{"slug":"abc","episode_number":1,"title":"Pilot"}]}"#)
        #expect(KickAssAnimeCodec.episodeNumbers(episodes) == [1, 2, 3])
        #expect(KickAssAnimeCodec.episode(episodes, 1)?.slug == "abc")

        let detail = try json(#"{"servers":[{"name":"BirdStream","src":"https://example.test/dash"},{"name":"VidStreaming","src":"https://krussdomi.com/cat-player/player?id=media-id&source=vidstream"}]}"#)
        let player = try #require(KickAssAnimeCodec.vidStreamingURL(detail))
        #expect(KickAssAnimeCodec.playerID(player) == "media-id")

        let html = #"<astro-island props="{&quot;language&quot;:[0,&quot;eng&quot;],&quot;name&quot;:[0,&quot;English&quot;],&quot;src&quot;:[0,&quot;https://subs.test/en.vtt&quot;]}"></astro-island>"#
        let subtitle = try #require(KickAssAnimeCodec.subtitles(html).first)
        #expect(subtitle.label == "English")
        #expect(subtitle.language == "eng")
        #expect(subtitle.url.absoluteString == "https://subs.test/en.vtt")
    }

    @Test func aRemakeLosesOnTheYearAndAMovieOnTheFormat() {
        var media = Media(id: 1, title: .init(english: "Hunter x Hunter"))
        media.seasonYear = 2011
        media.format = "TV"
        let remake = KickAssAnime.Show(slug: "a", title: "Hunter x Hunter", locales: [], year: 2011, type: "tv")
        let original = KickAssAnime.Show(slug: "b", title: "Hunter x Hunter", locales: [], year: 1999, type: "tv")
        let movie = KickAssAnime.Show(slug: "c", title: "Hunter x Hunter", locales: [], year: 2011, type: "movie")
        #expect(KickAssAnime.score(media, remake) > KickAssAnime.score(media, original))
        #expect(KickAssAnime.score(media, remake) > KickAssAnime.score(media, movie))
    }

    @Test func subAndDubAreOneMasterWithTheTrackNamed() async throws {
        let provider = KickAssAnime { request in
            let url = request.url!.absoluteString
            let body: String
            if url.hasSuffix("/fsearch") {
                body = #"{"result":[{"slug":"frieren-f3ae","title_en":"Frieren","locales":["ja-JP","en-US"],"year":2023,"type":"tv"}]}"#
            } else if url.contains("/episodes?") {
                body = #"{"pages":[{"eps":[1,2]}],"result":[{"slug":"5a1b","episode_number":1}]}"#
            } else if url.contains("/episode/ep-1-5a1b") {
                body = #"{"servers":[{"name":"VidStreaming","src":"https://krussdomi.com/cat-player/player?id=abc123&source=vidstream"}]}"#
            } else {
                body = "<html></html>"
            }
            return (200, Data(body.utf8))
        }
        var media = Media(id: 154587, title: .init(english: "Frieren"))
        media.seasonYear = 2023
        let sub = try #require(try await provider.sources(for: media, episode: 1, audio: .sub).first)
        let dub = try #require(try await provider.sources(for: media, episode: 1, audio: .dub).first)
        #expect(sub.url == dub.url)
        #expect(sub.url.absoluteString == "https://hls.krussdomi.com/manifest/abc123/master.m3u8")
        #expect(sub.audioLanguage == "jpn")
        #expect(dub.audioLanguage == "eng")
        #expect(sub.headers == ["Referer": "https://krussdomi.com/", "Origin": "https://krussdomi.com"])
        #expect(try await provider.episodes(for: media).dubbed == [1, 2])
    }
}
