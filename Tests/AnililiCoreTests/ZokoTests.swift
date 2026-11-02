import Foundation
import Testing
@testable import AnililiCore

/// Android's `ZokoParserTest`. `one-piece.txt` is the `__P` blob `/stream/mal/21/1/sub` served on
/// 2026-09-22; `synthetic.txt` was made with the site's own `obfuscate()` over a hand-written
/// payload: a non-default first track, no skip times and non-ASCII text.
struct ZokoTests {
    private func page(_ fixture: String) throws -> String {
        let blob = try Fixture.text("zoko/\(fixture)").trimmingCharacters(in: .whitespacesAndNewlines)
        return #"<div id="player"></div><script>window.__P=""# + blob + #""</script><script type="module" src="x"></script>"#
    }

    @Test func theLivePayloadDecodesToItsStreamSubtitleAndSkip() throws {
        let payload = try #require(ZokoParser.payload(try page("one-piece.txt")))
        let source = try #require(ZokoParser.source(payload, provider: "Zoko"))
        #expect(source.url.absoluteString == "https://hls.1embed.buzz/v/scxqicy/ta9t4m1bhw/cm72fkvbpx/09qmw7k6mi5nzd/master.m3u8")
        #expect(source.kind == .hls)
        #expect(source.headers["Referer"] == "https://zokoanime.video/", "the playlists 403 without it")
        let subtitle = try #require(source.subtitles.first)
        #expect(source.subtitles.count == 1)
        #expect(subtitle.label == "English")
        #expect(subtitle.language == "en")
        #expect(subtitle.url.absoluteString.hasSuffix("/subs/6e4a0p3k8ehe9eee.vtt"))
        let skip = try #require(ZokoParser.skip(payload))
        #expect(skip.intro == .init(start: 31, end: 111))
        #expect(skip.outro == .init(start: 1376, end: 1447))
    }

    @Test func theDefaultTrackLeadsAndLabelsNameTheLanguage() throws {
        let payload = try #require(ZokoParser.payload(try page("synthetic.txt")))
        let subtitles = try #require(ZokoParser.source(payload, provider: "Zoko")).subtitles
        #expect(subtitles.map(\.label) == ["English", "Arabic (Arabic - [Full])", "Portuguese (Portuguese - Brazilian [Full])"])
        #expect(subtitles.map(\.language) == ["en", "ar", "pt"])
        #expect(payload["title"]?.string == "葬送のフリーレン", "non-ASCII survives: the XOR runs over UTF-8 bytes")
        #expect(ZokoParser.skip(payload) == nil)
    }

    @Test func theNotFoundCardIsAMiss() throws {
        let notFound = #"<div class="card"><h1 class="title">Not <span class="stroke">found.</span></h1></div>"#
        #expect(!ZokoParser.hasPayload(notFound))
        #expect(ZokoParser.payload(notFound) == nil)
        #expect(ZokoParser.hasPayload(try page("one-piece.txt")))
        #expect(ZokoParser.payload(#"window.__P="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=""#) == nil, "a changed key reads as nothing")
    }

    @Test func theCountIsTwoProbesForACompleteTitle() async throws {
        let asked = RequestLog()
        let provider = Zoko { url in
            asked.append(url.path)
            let episode = Int(url.pathComponents[4]) ?? 0
            let dub = url.path.hasSuffix("/dub")
            let exists = dub ? episode <= 7 : episode <= 28
            return (200, exists ? #"window.__P="x""# : "Not found.")
        }
        var media = Media(id: 154587, title: .init(english: "Frieren"))
        media.idMal = 52991
        media.episodes = 28
        media.status = "FINISHED"
        let listing = try await provider.episodes(for: media)
        #expect(listing.subbed == Set(1...28))
        #expect(listing.dubbed == Set(1...7))
        #expect(asked.entries.filter { $0.hasSuffix("/sub") }.count == 2)
    }

    @Test func theSearchFindsTheLastEpisode() async throws {
        for last in [0, 1, 5, 11, 12] {
            let found = try await ProviderSupport.highestAvailable(12) { $0 <= last }
            #expect(found == last)
        }
    }
}
