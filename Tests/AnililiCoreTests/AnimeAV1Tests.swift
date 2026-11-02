import Foundation
import Testing
@testable import AnililiCore

struct AnimeAV1Tests {
    private func json(_ text: String) throws -> JSON { try JSON.parse(Data(text.utf8)) }

    /// A SvelteKit `__data.json`, devalue-flattened: values are indices into `data`.
    @Test func pageDataIsUnflattened() throws {
        let root = try json("""
        {"type":"data","nodes":[{"type":"data","data":[{"layout":1},"x"]},
          {"type":"data","data":[{"media":1},{"malId":2,"episodes":3,"title":7},52991,[4,5,6],{"number":8},{"number":9},{"number":10},"Sousou no Frieren",1,2,1.5]}]}
        """)
        let page = try #require(AnimeAV1Parser.pageData(root))
        let detail = try AnimeAV1Parser.detail(page)
        #expect(detail.malID == 52991)
        #expect(detail.episodes == [1, 2], "the 1.5 recap is dropped")
        #expect(page["media"]?["title"]?.string == "Sousou no Frieren")
    }

    @Test func voeHostsLeadAndYourUploadFollows() throws {
        #expect(AnimeAV1Parser.hostRank("VOE") == 0)
        #expect(AnimeAV1Parser.hostRank(" YourUpload ") == 1)
        #expect(AnimeAV1Parser.hostRank("MP4Upload") == nil)
        #expect(AnimeAV1Parser.hostRank("Streamtape") == nil)
        #expect(AnimeAV1Parser.voeRedirect("const u = new URL(window.location.href); window.location.href = 'https://jonathansociallike.com/e/abc';")
                == "https://jonathansociallike.com/e/abc")
        #expect(AnimeAV1Parser.ogVideo(#"<meta property="og:video" content="https://www.yourupload.com/play/x.mp4">"#) == "https://www.yourupload.com/play/x.mp4")
        #expect(AnimeAV1Parser.ogVideo(#"<meta property="og:video" content="https://www.yourupload.com/novideo.mp4">"#) == nil)
    }

    /// The VOE scheme run forwards on a known config, then read back.
    @Test func voeConfigIsDecoded() throws {
        let config = #"{"source":"https://cdn.example/master.m3u8"}"#
        let first = Data(config.utf8).base64EncodedString()
        let shifted = String(first.reversed().map { Character(Unicode.Scalar(UInt8($0.asciiValue! + 3))) })
        let second = Data(shifted.utf8.map { $0 }).base64EncodedString()
        let encoded = AnimeAV1Parser.rot13(second)
        let page = #"<script type="application/json">[""# + encoded + #""]</script>"#
        #expect(AnimeAV1Parser.voeConfig(page)?["source"]?.string == "https://cdn.example/master.m3u8")
    }
}
