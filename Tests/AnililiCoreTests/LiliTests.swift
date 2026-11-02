import Foundation
import Testing
@testable import AnililiCore

/// Android's `KonohaLiliSourcesTest`, on the records `scripts/lili_sources.py` wrote (2026-09-14).
struct LiliTests {
    static let jujutsu = #"""
    {"provider":"xfdm","bangumi":294993,"subject":"/bangumi/1191.html","layout":"archive",
     "crawled":"2026-09-14","base":"https://play.xfvod.pro:8088/Z/Z-%E5%92%92%E6%9C%AF%E5%9B%9E%E6%88%98/",
     "episodes":{"1":"01.mp4","24":"24.mp4"}}
    """#
    static let airing = #"""
    {"provider":"xfdm","bangumi":501963,"subject":"/bangumi/3541.html","layout":"temp",
     "crawled":"2026-09-14","base":"https://play.xfvod.pro:8088/temp/2607/",
     "episodes":{"7":"%E6%97%A0%E8%81%8C07z.mp4","8":"%E6%97%A0%E8%81%8C08.mp4"}}
    """#

    private func record(_ text: String) throws -> Lili.Sources {
        try JSONDecoder().decode(Lili.Sources.self, from: Data(text.utf8))
    }

    @Test func anEpisodeIsTheBasePlusItsEntry() throws {
        let sources = try record(Self.jujutsu)
        #expect(sources.url(for: 1)?.absoluteString == "https://play.xfvod.pro:8088/Z/Z-%E5%92%92%E6%9C%AF%E5%9B%9E%E6%88%98/01.mp4")
        #expect(sources.url(for: 24)?.absoluteString == "https://play.xfvod.pro:8088/Z/Z-%E5%92%92%E6%9C%AF%E5%9B%9E%E6%88%98/24.mp4")
        #expect(sources.url(for: 25) == nil, "never a bare directory")
        #expect(sources.url(for: 0) == nil)
        #expect(sources.numbers == [1, 24])
    }

    @Test func filenamesAreKeptAsTheSiteWroteThem() throws {
        let sources = try record(Self.airing)
        #expect(sources.url(for: 7)?.absoluteString == "https://play.xfvod.pro:8088/temp/2607/%E6%97%A0%E8%81%8C07z.mp4")
        #expect(sources.url(for: 8)?.absoluteString == "https://play.xfvod.pro:8088/temp/2607/%E6%97%A0%E8%81%8C08.mp4")
        #expect(sources.isProvisional)
        #expect(!(try record(Self.jujutsu)).isProvisional)
        #expect(try record(#"{"provider":"xfdm"}"#).url(for: 1) == nil)
    }

    @Test func theProviderListsAndPlaysTheRecord() async throws {
        let provider = Lili { id in id == 1 ? try JSONDecoder().decode(Lili.Sources.self, from: Data(Self.jujutsu.utf8)) : nil }
        let media = Media(id: 1, title: .init(english: "Jujutsu Kaisen"))
        #expect(try await provider.episodes(for: media).subbed == [1, 24])
        #expect(try await provider.sources(for: media, episode: 24, audio: .sub).first?.kind == .mp4)
        #expect(try await provider.sources(for: media, episode: 24, audio: .dub).isEmpty)
        #expect(try await provider.episodes(for: Media(id: 2, title: .init())).isEmpty)
    }
}
