import Foundation
import Testing
@testable import AnililiCore

struct SettingsSearchTests {
    @Test func everyEntryIsInASection() {
        let sections: Set = ["player", "subtitles", "downloads", "servers", "accounts", "notifications", "content",
                             "appearance", "data", "app", "about"]
        #expect(Set(SettingsSearch.entries.map(\.sectionID)).isSubset(of: sections))
        let ids = SettingsSearch.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "a title twice in one section couldn't say which row to mark")
    }

    @Test func ranksTitlesAboveKeywords() {
        #expect(SettingsSearch.search("dub").first?.title == "Prefer dubbed audio")
        #expect(SettingsSearch.search("skip length").map(\.title) == ["Skip button length"])
        #expect(SettingsSearch.search("spoiler").first?.title == "Blur episode images")
        #expect(SettingsSearch.search("Watched").first?.title == "Watched at")
        #expect(SettingsSearch.search("   ").isEmpty)
        #expect(SettingsSearch.search("zzzz").isEmpty)
        #expect(SettingsSearch.search("a").count == 8, "capped like Android's")
    }

    @Test func pastQueriesCompleteWhatIsTyped() {
        let history = ["subtitles", "Subtitle language", "skip", "sub"]
        #expect(SettingsSearch.completions("", history: history).isEmpty)
        #expect(SettingsSearch.completions("sub", history: history) == ["subtitles", "Subtitle language"])
        #expect(SettingsSearch.recording(" Skip ", in: history) == ["Skip", "subtitles", "Subtitle language", "sub"])
        #expect(SettingsSearch.recording("new", in: (1...8).map(String.init)).count == 8)
    }
}

struct PlayerPreferenceTests {
    @Test func qualityCapsWithoutGoingOver() {
        let heights = [1080, 720, 360]
        #expect(DefaultQuality.auto.pickHeight(heights) == nil)
        #expect(DefaultQuality.highest.pickHeight(heights) == 1080)
        #expect(DefaultQuality.p480.pickHeight(heights) == 360)
        #expect(DefaultQuality.p720.pickHeight(heights) == 720)
        #expect(DefaultQuality.p360.pickHeight([1080]) == 1080, "nothing under the cap still starts the episode")
        #expect(DefaultQuality.stored("nonsense") == .highest)
        #expect(DefaultQuality.stored("360") == .p360)
    }

    @Test func languagesReadAndroidAndOldIOSValues() {
        #expect(TrackLanguage.stored("eng", in: TrackLanguage.subtitles).label == "English")
        #expect(TrackLanguage.stored("en", in: TrackLanguage.subtitles).code == "eng", "earlier iOS builds stored two letters")
        #expect(TrackLanguage.stored("", in: TrackLanguage.subtitles).isAutomatic)
        #expect(TrackLanguage.stored("xx", in: TrackLanguage.audio).isAutomatic)
        #expect(TrackLanguage.stored("ita", in: TrackLanguage.audio).isAutomatic, "Italian isn't an audio choice on Android")
    }

    @Test func languagesMatchTrackTags() {
        let english = TrackLanguage.stored("eng", in: TrackLanguage.subtitles)
        for tag in ["en", "eng", "EN-us", "English", "English (CC)", "english sdh"] { #expect(english.matches(tag), "\(tag)") }
        for tag in ["es", "", "Englishman"] { #expect(!english.matches(tag), "\(tag)") }
        #expect(TrackLanguage.stored("fra", in: TrackLanguage.audio).matches("fre"))
        #expect(!TrackLanguage.automatic.matches("en"))

        let tracks = ["ja", "es", "en"]
        let spanish = TrackLanguage.stored("spa", in: TrackLanguage.subtitles)
        let korean = TrackLanguage.stored("kor", in: TrackLanguage.subtitles)
        #expect(TrackLanguage.pick(tracks, preferences: [korean, spanish], tag: { $0 }) == "es", "the second choice when the first is missing")
        #expect(TrackLanguage.pick(tracks, preferences: [english, spanish], tag: { $0 }) == "en")
        #expect(TrackLanguage.pick(tracks, preferences: [.automatic, korean], tag: { $0 }) == nil)
    }

    @Test func limitsClampLikeAndroid() {
        #expect(PlayerLimits.skipSeconds(nil) == 85)
        #expect(PlayerLimits.skipSeconds(500) == 180)
        #expect(PlayerLimits.skipSeconds(0) == 5)
        #expect(PlayerLimits.watchedPercent(10) == 50)
        #expect(PlayerLimits.watchedPercent(100) == 95)
        #expect(PlayerLimits.speed(9, default: 1) == 4)
        #expect(PlayerLimits.speed(nil, default: 2) == 2)
        #expect(PlayerLimits.speedLabel(1) == "1x")
        #expect(PlayerLimits.speedLabel(1.25) == "1.25x")
        #expect(PlayerLimits.speedLabel(0.9) == "0.9x")
        #expect(PlaybackBufferSize.stored("very_large").seconds == 240)
        #expect(PlaybackBufferSize.stored(nil) == .automatic)
    }
}

struct MALImportTests {
    @Test func readsAnExportOncePerTitle() throws {
        let entries = try MALImport.parse(Fixture.data("mal-export.xml"))
        #expect(entries.map(\.malID) == [52991, 21, 5114], "the duplicate and the entry without an id are skipped")
        #expect(entries[0].title == "Sousou no Frieren")
        #expect(entries[0].status == "Completed")
        #expect(entries[1].status == "Watching", "numeric status codes from old exports")
        #expect(entries[1].watchedEpisodes == 1071)
        #expect(entries[2].watchedEpisodes == 0)
        #expect(entries[2].status == "Plan to Watch")
    }

    @Test func readsTheGzippedFileMALServes() throws {
        let plain = try MALImport.parse(Fixture.data("mal-export.xml"))
        #expect(try MALImport.parse(Fixture.data("mal-export.xml.gz")) == plain)
    }

    @Test func refusesWhatIsNotAnExport() {
        #expect(throws: MALImport.Failure.notAnExport) { try MALImport.parse(Data("<anilili><anime/></anilili>".utf8)) }
        #expect(throws: MALImport.Failure.notAnExport) { try MALImport.parse(Data("{\"format\":\"anilili-backup\"}".utf8)) }
        let entity = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e \"boom\">]><myanimelist></myanimelist>"
        #expect(throws: MALImport.Failure.unsafe) { try MALImport.parse(Data(entity.utf8)) }
    }

    @Test func summaryReadsLikeAndroid() {
        #expect(MALImport.Summary(total: 5, added: 3, alreadySaved: 1, unmatched: 1).text
                == "Imported 3 new anime; 1 already saved; 1 not found on AniList")
        #expect(MALImport.Summary(total: 2, added: 2, alreadySaved: 0, unmatched: 0).text == "Imported 2 new anime")
    }
}

struct ContinueVisibilityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func show(episode: Int, position: Double, duration: Double = 1440, id: Int = 7) -> WatchHistory.Show {
        var history = WatchHistory()
        history.record(Media(id: id, title: .init(english: "Weekly")), episode: episode, position: position, duration: duration, at: now)
        return history.shows[id]!
    }

    @Test func caughtUpRowWaitsForTheNextEpisode() {
        let finished = show(episode: 5, position: 1400)
        let tomorrow = now.addingTimeInterval(86_400)
        let upcoming: ContinueVisibility.Upcoming = [7: [6: tomorrow]]
        #expect(ContinueVisibility.returnsAt(finished, upcoming: upcoming, now: now) == tomorrow.addingTimeInterval(2 * 3600))
        #expect(ContinueVisibility.visible([finished], upcoming: upcoming, now: now).isEmpty)
    }

    @Test func justAiredStaysHiddenUntilTheServersHaveIt() {
        let finished = show(episode: 5, position: 1400)
        let anHourAgo = now.addingTimeInterval(-3600)
        #expect(ContinueVisibility.returnsAt(finished, upcoming: [7: [6: anHourAgo]], now: now) != nil)
        let threeHoursAgo = now.addingTimeInterval(-3 * 3600)
        #expect(ContinueVisibility.returnsAt(finished, upcoming: [7: [6: threeHoursAgo]], now: now) == nil)
    }

    @Test func somethingToPlayKeepsTheRow() {
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(ContinueVisibility.returnsAt(show(episode: 5, position: 300), upcoming: [7: [6: tomorrow]], now: now) == nil, "part-way")
        #expect(ContinueVisibility.returnsAt(show(episode: 3, position: 1400), upcoming: [7: [6: tomorrow]], now: now) == nil, "episodes 4 and 5 are out")
        #expect(ContinueVisibility.returnsAt(show(episode: 5, position: 1400), upcoming: [:], now: now) == nil, "nothing scheduled")
        #expect(ContinueVisibility.returnsAt(show(episode: 5, position: 1400), upcoming: [8: [6: tomorrow]], now: now) == nil, "another title's episode")
    }
}

struct DiagnosticsTests {
    @Test func reportsLeaveSecretsBehind() {
        let line = #"GET https://x/cb?code=abc123&state=s → 200; Authorization: Bearer eyJ.a-b_c; {"access_token":"tok","name":"lili"} errorCode=5 #access_token=zzz&expires_in=1"#
        let redacted = Log.redact(line)
        for secret in ["abc123", "eyJ.a-b_c", "\"tok\"", "zzz"] { #expect(!redacted.contains(secret), "\(secret)") }
        #expect(redacted.contains("state=s"))
        #expect(redacted.contains("errorCode=5"), "a word merely ending in code is not a code")
        #expect(redacted.contains("\"name\":\"lili\""))
        #expect(redacted.contains("expires_in=1"))
    }
}
