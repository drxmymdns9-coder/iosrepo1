import Foundation
import Testing
@testable import AnililiCore

/// Android's `AniPmParserTest`, on its fixtures.
struct AniPmTests {
    private func json(_ text: String) throws -> JSON { try JSON.parse(Data(text.utf8)) }

    @Test func eachTrackIsReadFromThePackageInventory() throws {
        // Otome Game S2 on 2026-09-23: dub stops at episode 10.
        let listing = AniPmParser.listing(try json("""
        {"anilistId":159309,"configured":true,"episodes":{
          "1":{"key":"a159309e1","sub":true,"dub":true},
          "11":{"key":"a159309e11","sub":true,"dub":false},
          "12":{"key":"a159309e12","sub":true},
          "0":{"key":"x","sub":true,"dub":true},
          "bad":{"sub":true}}}
        """))
        #expect(listing.subbed == [1, 11, 12])
        #expect(listing.dubbed == [1])
        #expect(AniPmParser.listing(try json(#"{"anilistId":1,"episodes":{}}"#)).isEmpty)
    }

    @Test func theSessionIsAHeaderFreeStreamWithNormalisedLanguages() throws {
        let source = try #require(AniPmParser.source(try json("""
        {"source":"https://media.settlar.io/v1/object/v2.a.b.c","kind":"hls","audioLang":"ja",
         "subtitles":[
          {"url":"https://media.settlar.io/v1/object/v2.th","label":"Thai","srclang":"tha","default":false},
          {"url":"https://media.settlar.io/v1/object/v2.en","label":"English","srclang":"en","default":true},
          {"url":"https://media.settlar.io/v1/object/v2.id","label":"Indonesian","srclang":"ind"},
          {"url":"http://insecure/x.vtt","label":"Bad","srclang":"en"}]}
        """), provider: "Ani.pm"))
        #expect(source.url.absoluteString == "https://media.settlar.io/v1/object/v2.a.b.c")
        #expect(source.headers.isEmpty)
        #expect(source.subtitles.map(\.language) == ["en", "th", "id"])
        #expect(source.subtitles.first?.label == "English")
        #expect(AniPmParser.source(try json(#"{"source":"http://x"}"#), provider: "Ani.pm") == nil)
    }

    @Test func aDubTheBootstrapQuietlySwapsForSubIsRefused() async throws {
        let provider = AniPm { url in
            if url.path.contains("playback-bootstrap") {
                return (200, Data(#"{"effectiveLanguage":"sub","settlarSelection":"x"}"#.utf8))
            }
            return (500, Data())
        }
        await #expect(throws: ProviderError.self) {
            try await provider.sources(for: Media(id: 1, title: .init()), episode: 12, audio: .dub)
        }
    }
}
