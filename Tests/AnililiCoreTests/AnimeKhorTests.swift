import Foundation
import Testing
@testable import AnililiCore

/// Android's `AnimekhorParserTest`, on its markup (copied from live animekhor.org pages).
struct AnimeKhorTests {
    @Test func searchResultsCarryTheTypeBadge() {
        let html = """
        <div class="listupd">
        <article class="bs" itemscope="itemscope">
          <div class="bsx">
            <a href="https://animekhor.org/anime/battle-through-the-heavens-season-4/" itemprop="url" title="Battle Through the Heavens Season 4" class="tip" rel="65760">
              <div class="limit"><div class="status Completed">Completed</div><div class="typez ONA">ONA</div></div>
            </a>
          </div>
        </article>
        <article class="bs" itemscope="itemscope">
          <div class="bsx">
            <a href="https://animekhor.org/anime/battle-through-the-heavens-comics/" itemprop="url" title="Battle Through the Heavens Comics" class="tip">
              <div class="limit"><div class="typez Comic">Comic</div></div>
            </a>
          </div>
        </article>
        </div>
        """
        let results = AnimeKhorParser.search(html)
        #expect(results.count == 2)
        #expect(results[0].title == "Battle Through the Heavens Season 4")
        #expect(results[0].url == "https://animekhor.org/anime/battle-through-the-heavens-season-4/")
        #expect(!results[0].isComic)
        #expect(results[1].isComic)
    }

    @Test func episodeLabelsCoverEveryNumberingStyle() {
        #expect(AnimeKhorParser.numbers("207") == [207])
        #expect(AnimeKhorParser.numbers("637 to 638") == [637, 638])
        #expect(AnimeKhorParser.numbers("1 to 12") == Array(1...12))
        #expect(AnimeKhorParser.numbers("S4 E380") == [380])
        #expect(AnimeKhorParser.numbers("S4 E378-379") == [378, 379])
        #expect(AnimeKhorParser.numbers("S2E290") == [290])
        #expect(AnimeKhorParser.numbers("Special") == [])
        // An episode paired with a year isn't a thousand-episode batch.
        #expect(AnimeKhorParser.numbers("12 (2024)") == [12])
    }

    @Test func bothEndsOfABatchResolveToItsPage() {
        let html = """
        <div class="eplister">
          <div class="ephead"><div class="eph-num">Ep</div></div>
          <ul>
            <li data-index="0">
              <a href="https://animekhor.org/god-of-martial-arts-episode-637-to-638/"><div class="epl-num">637 to 638</div><div class="epl-title">Episode 637 to 638</div></a>
            </li>
            <li data-index="1">
              <a href="https://animekhor.org/god-of-martial-arts-episode-636/"><div class="epl-num">636</div><div class="epl-title">Episode 636</div></a>
            </li>
          </ul>
        </div>
        """
        let episodes = AnimeKhorParser.episodes(html)
        #expect(Set(episodes.keys) == [636, 637, 638])
        #expect(episodes[637] == episodes[638])
        #expect(episodes[636] == "https://animekhor.org/god-of-martial-arts-episode-636/")
    }

    @Test func mirrorsAreDecodedFromTheBase64Options() {
        let okRu = "PGlmcmFtZSB3aWR0aD0iNjQwIiBoZWlnaHQ9IjM2MCIgc3JjPSIvL29rLnJ1L3ZpZGVvZW1iZWQvMTYzOTU0"
            + "MjQxNzI2NDAiIGZyYW1lYm9yZGVyPSIwIiBhbGxvd2Z1bGxzY3JlZW4+PC9pZnJhbWU+"
        let dailymotion = "PGRpdiBzdHlsZT0icG9zaXRpb246cmVsYXRpdmUiPiA8aWZyYW1lIHNyYz0iaHR0cHM6Ly93d3cuZGFpbHlt"
            + "b3Rpb24uY29tL2VtYmVkL3ZpZGVvL2s0eFJ3Z0FGeWNXZjVPSEg1SGciIGFsbG93ZnVsbHNjcmVlbj4g"
            + "PC9pZnJhbWU+IDwvZGl2Pg=="
        let html = """
        <div class="mobius">
        <select class="mirror" name="mirror" onchange="loadMi(this);">
          <option value="">Select Video Server</option>
          <option value="\(dailymotion)" data-index="1">
        VidPlayer [MULTI SUB]</option>
          <option value="\(okRu)" data-index="2">
        ok.ru&#12298;Ads Free&#12299; [ENGLISH]</option>
        </select>
        </div>
        """
        let mirrors = AnimeKhorParser.mirrors(html)
        #expect(mirrors.count == 2)
        #expect(mirrors.first?.label == "VidPlayer [MULTI SUB]")
        #expect(mirrors.first?.url == "https://www.dailymotion.com/embed/video/k4xRwgAFycWf5OHH5Hg")
        // Protocol-relative sources are the site's habit; no player opens one.
        #expect(mirrors.last?.url == "https://ok.ru/videoembed/16395424172640")
    }

    @Test func aPageWithoutASelectFallsBackToItsInlinePlayer() {
        let html = """
        <div class="player-embed">
          <iframe src="https://emturbovid.com/t/6a524624e82b3" frameborder="0"></iframe>
        </div>
        """
        #expect(AnimeKhorParser.mirrors(html) == [.init(label: "Emturbovid", url: "https://emturbovid.com/t/6a524624e82b3")])
    }

    @Test func onlyChineseTitlesAreAsked() async throws {
        let calls = RequestLog()
        let provider = AnimeKhor { url, _ in
            calls.append(url.absoluteString)
            return (200, "")
        }
        var media = Media(id: 1, title: .init(english: "Frieren"))
        media.countryOfOrigin = "JP"
        #expect(try await provider.episodes(for: media).isEmpty)
        #expect(calls.entries.isEmpty)
    }
}
