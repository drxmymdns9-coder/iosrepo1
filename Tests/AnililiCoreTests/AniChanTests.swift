import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnililiCore

/// Android's `AniChanParserTest`, on its fixtures (trimmed from live responses, Frieren ep1, 2026-09-13).
struct AniChanTests {
    static let servers = """
    {"servers":[
      {"name":"vidhawk","label":"vidHawk","type":"embed","rank":8,"stream":null},
      {"name":"megaplay_hd1","label":"HD-1","type":"hls","rank":4,
       "stream":"https://c.toroplay.cymru/api/watch/m3u8?url=https%3A%2F%2Fmegap.mikora.top%2Fa",
       "subtitles":[{"lang":"English","default":true,"url":"https://s/mp-eng.vtt"}]},
      {"name":"aniwatchtv","label":"zoko","type":"hls","rank":3,
       "stream":"https://c.toroplay.cymru/api/watch/m3u8?url=https%3A%2F%2Fhls2.aniwatchtv.uk%2Fv",
       "subtitles":[{"lang":"English","default":true,"url":"https://s/zoko-eng.vtt"}]},
      {"name":"anichan","label":"★ AniChan","type":"hls","rank":1,
       "stream":"/api/watch/m3u8?sh=154587%2F1%2Fsub%2Fmaster.m3u8&sig=whANI&exp=1",
       "subtitles":[
         {"lang":"English","default":true,
          "url":"https://s1.toroplay.click/154587/1/sub/subs/eng0.vtt?md5=a&expires=1",
          "ass":"https://s1.toroplay.click/154587/1/sub/subs/eng0.ass?md5=b&expires=1"},
         {"lang":"Spanish (Latin American)","default":false,
          "url":"https://s1.toroplay.click/154587/1/sub/subs/spa1.vtt?md5=c&expires=1"}
       ]}
    ]}
    """

    static let serversWithSpaces = """
    {"servers":[
      {"name":"anichan","label":"★ AniChan","type":"hls","rank":1,
       "stream":"/api/watch/m3u8?sh=196187%2F1%2Fsub%2Fmaster.m3u8&sig=whANI&exp=1",
       "subtitles":[
         {"lang":"English","default":true,"url":"https://s1.toroplay.click/196187/1/sub/subs/English (CR)0.vtt?md5=a&expires=1"},
         {"lang":"Spanish (Latin America)","default":false,"url":"https://s1.toroplay.click/196187/1/sub/subs/Spanish (Latin America CR)2.vtt?md5=c&expires=1"}
       ]}
    ]}
    """

    private func sources(_ text: String) throws -> [VideoSource] {
        AniChanParser.sources(try JSON.parse(Data(text.utf8))["servers"], provider: "AniChan")
    }

    @Test func theCountAndTheDubFlagAreTheListing() throws {
        let both = try #require(AniChanParser.listing(try JSON.parse(Data(#"{"episodes":28,"dubAvailable":true}"#.utf8))))
        #expect(both.subbed == Set(1...28))
        #expect(both.dubbed == Set(1...28))
        let subOnly = try #require(AniChanParser.listing(try JSON.parse(Data(#"{"episodes":12,"dubAvailable":null}"#.utf8))))
        #expect(subOnly.dubbed.isEmpty)
        #expect(AniChanParser.listing(try JSON.parse(Data(#"{"episodes":0,"sources":[]}"#.utf8))) == nil, "a zero count is a title it lacks")
    }

    @Test func serversAreRankedAbsolutisedAndUnstarred() throws {
        let found = try sources(Self.servers)
        #expect(found.map(\.server) == ["AniChan", "zoko"], "megaplay and vidhawk are AniKoto's backend under other names")
        #expect(found[0].url.absoluteString == "https://anichan.to/api/watch/m3u8?sh=154587%2F1%2Fsub%2Fmaster.m3u8&sig=whANI&exp=1")
        #expect(found[1].url.absoluteString.hasPrefix("https://c.toroplay.cymru/"))
        #expect(found.allSatisfy { $0.kind == .hls && $0.headers.isEmpty })
    }

    @Test func subtitlesComeFromTheLeadingServerOnly() throws {
        let found = try sources(Self.servers)
        #expect(found[0].subtitles.map(\.label) == ["English", "Spanish (Latin American)"])
        #expect(found[0].subtitles.map(\.language) == ["en", "es"])
        #expect(found[0].softSub)
        #expect(found[1].subtitles.isEmpty)
    }

    @Test func spacesInTrackNamesAreEncodedAndNothingElse() throws {
        let found = try sources(Self.serversWithSpaces)
        #expect(found[0].subtitles.map(\.url.absoluteString) == [
            "https://s1.toroplay.click/196187/1/sub/subs/English%20(CR)0.vtt?md5=a&expires=1",
            "https://s1.toroplay.click/196187/1/sub/subs/Spanish%20(Latin%20America%20CR)2.vtt?md5=c&expires=1",
        ])
        #expect(found[0].url.absoluteString.contains("sh=196187%2F1%2Fsub%2Fmaster.m3u8"))
    }

    @Test func theSessionCookieIsReadFromSetCookie() {
        #expect(AniChanParser.sessionCookie("anichan_ws=abc.def; Max-Age=7200; Path=/; HttpOnly") == "anichan_ws=abc.def")
        #expect(AniChanParser.sessionCookie("other=1, anichan_ws=xyz; Path=/") == "anichan_ws=xyz")
        #expect(AniChanParser.sessionCookie("other=1") == nil)
    }

    @Test func aRefusedCookieIsMintedAgain() async throws {
        let log = RequestLog()
        let provider = AniChan { request in
            let path = request.url?.path ?? ""
            log.append(path + (request.value(forHTTPHeaderField: "Cookie").map { " " + $0 } ?? ""))
            let url = request.url!
            if path.hasSuffix("/session") {
                let count = log.entries.filter { $0.hasSuffix("/session") }.count
                return (Data(#"{"exp":4102444800}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "anichan_ws=c\(count); Path=/"])!)
            }
            let stale = request.value(forHTTPHeaderField: "Cookie") == "anichan_ws=c1"
            let body = stale ? #"{"detail":"session"}"# : Self.servers
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: stale ? 401 : 200, httpVersion: nil, headerFields: [:])!)
        }
        let found = try await provider.sources(for: Media(id: 154587, title: .init(english: "Frieren")), episode: 1, audio: .sub)
        #expect(found.count == 2)
        #expect(log.entries == ["/api/watch/session", "/api/watch/servers anichan_ws=c1", "/api/watch/session", "/api/watch/servers anichan_ws=c2"])
    }
}
