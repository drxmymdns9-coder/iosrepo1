import Foundation
import Testing
@testable import AnililiCore

struct ServerSummaryTests {
    private func source(_ provider: String = "Miruro", server: String = "bee", kind: VideoSource.Kind = .hls,
                        subtitles: [SubtitleTrack] = [], audioLanguage: String? = nil) -> VideoSource {
        VideoSource(url: URL(string: "https://example.com/\(provider)/\(server).m3u8")!, provider: provider, server: server, kind: kind,
                    subtitles: subtitles, softSub: !subtitles.isEmpty, audioLanguage: audioLanguage)
    }

    private func track(_ language: String, _ label: String = "") -> SubtitleTrack {
        SubtitleTrack(url: URL(string: "https://example.com/\(language)\(label).vtt")!, label: label, language: language)
    }

    @Test func languageLabelsCollapseToOneName() {
        #expect(ServerSummary.normalizeLanguage("en") == "English")
        #expect(ServerSummary.normalizeLanguage("eng") == "English")
        #expect(ServerSummary.normalizeLanguage("English Dub") == "English")
        #expect(ServerSummary.normalizeLanguage("pt-BR") == "Portuguese")
        #expect(ServerSummary.normalizeLanguage("es_419") == "Spanish")
        #expect(ServerSummary.normalizeLanguage("Español") == "Spanish")
        #expect(ServerSummary.normalizeLanguage("ger") == "German")
        #expect(ServerSummary.normalizeLanguage("Hindi Uncut") == "Hindi")
        #expect(ServerSummary.normalizeLanguage("fr") == "French")
    }

    @Test func labelsThatOnlySaySubOrDubNameNoLanguage() {
        #expect(ServerSummary.normalizeLanguage("Dub") == nil)
        #expect(ServerSummary.normalizeLanguage("sub") == nil)
        #expect(ServerSummary.normalizeLanguage("  ") == nil)
        #expect(ServerSummary.normalizeLanguage(nil) == nil)
    }

    @Test func softSubsListTheirFilesAndEverythingElseIsAssumedEnglish() {
        let soft = source(subtitles: [track("en"), track("es"), track("pt-BR"), track("en", "English [CC]")])
        #expect(ServerSummary.languages(of: soft, audio: .sub) == ["English", "Portuguese", "Spanish"])
        #expect(ServerSummary.languages(of: source(), audio: .sub) == ["English"])
        #expect(ServerSummary.languages(of: source(audioLanguage: "jpn"), audio: .dub) == ["Japanese"])
    }

    @Test func aServerNamingItsLanguageIsThatLanguage() {
        #expect(ServerSummary.languages(of: source("AnimeDekho (Hindi)", kind: .embed), audio: .dub) == ["Hindi"])
        #expect(ServerSummary.languages(of: source("AnimeAV1 (Español)"), audio: .sub) == ["Spanish"])
        #expect(ServerSummary.declaredLanguage("Miruro") == nil)
    }

    @Test func filteringByLanguageKeepsOnlyTheServersCarryingIt() {
        let english = source(server: "bee")
        let spanish = source("AnimeAV1 (Español)")
        let multi = source(server: "kiwi", subtitles: [track("en"), track("es")])
        let all = [english, spanish, multi]
        #expect(ServerSummary.languages(of: all, audio: .sub) == ["English", "Spanish"])
        #expect(ServerSummary.filter(all, language: "Spanish", audio: .sub) == [spanish, multi])
        #expect(ServerSummary.filter(all, language: nil, audio: .sub) == all)
    }

    @Test func theDescriptionSaysWhatAViewerChoosesBy() {
        #expect(ServerSummary.description(of: source(), audio: .sub, playing: true, failure: nil)
            == "Playing now · Subtitles in the picture · English · Can download")
        let soft = source(subtitles: [track("en")])
        #expect(ServerSummary.description(of: soft, audio: .sub, playing: false, failure: "timed out")
            == "Subtitles you can switch · English · Failed: timed out")
        #expect(ServerSummary.description(of: source(kind: .embed), audio: .dub, playing: false, failure: nil)
            == "Dubbed · web player · English")
    }
}

struct FormFactorTests {
    @Test func theTelevisionLayoutIsTheIPadsUnlessTheViewerSaysOtherwise() {
        #expect(FormFactorPreference.stored(nil) == .automatic)
        #expect(FormFactorPreference.stored("television") == .television)
        #expect(FormFactorPreference.stored("nonsense") == .automatic)
        #expect(FormFactorPreference.automatic.usesTelevision(isPad: true, wideWindow: true))
        #expect(FormFactorPreference.television.usesTelevision(isPad: true, wideWindow: true))
        #expect(!FormFactorPreference.handheld.usesTelevision(isPad: true, wideWindow: true))
    }

    @Test func phonesAndNarrowWindowsKeepThePhoneLayout() {
        #expect(!FormFactorPreference.automatic.usesTelevision(isPad: false, wideWindow: true))
        #expect(!FormFactorPreference.television.usesTelevision(isPad: false, wideWindow: false))
        #expect(!FormFactorPreference.television.usesTelevision(isPad: true, wideWindow: false))
    }
}
