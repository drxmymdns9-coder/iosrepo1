import Foundation
import Testing
@testable import AnililiCore

/// `parity-titles.json` is the Android app's `parity/titles.json`, the corpus the desktop app also
/// checks itself against. A provider picks the same site entry on every platform only while all
/// three agree with it.
struct TitleParityTests {
    private struct Corpus: Decodable {
        struct SeasonCase: Decodable { var title: String; var expected: Int? }
        struct BaseCase: Decodable { var title: String; var expected: String }
        struct ScoreCase: Decodable { var query: String; var candidate: String; var exactly: Double?; var above: Double? }
        struct OrderCase: Decodable { var query: String; var better: String; var worse: String }

        var seasonNumber: [SeasonCase]
        var baseSeriesTitle: [BaseCase]
        var titleScore: [ScoreCase]
        var selectionOrder: [OrderCase]
    }

    private let corpus: Corpus

    init() throws {
        corpus = try JSONDecoder().decode(Corpus.self, from: Fixture.data("parity-titles.json"))
    }

    @Test func seasonNumbers() {
        for testCase in corpus.seasonNumber {
            #expect(TitleMatching.seasonNumber(testCase.title) == testCase.expected, "\(testCase.title)")
        }
    }

    @Test func baseSeriesTitles() {
        for testCase in corpus.baseSeriesTitle {
            #expect(TitleMatching.baseSeriesTitle(testCase.title) == testCase.expected, "\(testCase.title)")
        }
    }

    @Test func titleScores() {
        for testCase in corpus.titleScore {
            let score = TitleMatching.titleScore(testCase.query, testCase.candidate)
            if let exactly = testCase.exactly {
                #expect(abs(score - exactly) <= 1e-9, "\(testCase.query) vs \(testCase.candidate): \(score)")
            } else if let above = testCase.above {
                #expect(score > above, "\(testCase.query) vs \(testCase.candidate): \(score)")
            } else {
                Issue.record("case says neither exactly nor above: \(testCase.query)")
            }
        }
    }

    @Test func selectionOrder() {
        for testCase in corpus.selectionOrder {
            let better = TitleMatching.selectionScore(testCase.query, testCase.better)
            let worse = TitleMatching.selectionScore(testCase.query, testCase.worse)
            #expect(better > worse, "\(testCase.query): \(testCase.better) \(better) vs \(testCase.worse) \(worse)")
        }
    }

    /// The numbers the Android provider's season-ranking comment quotes.
    @Test func tanyaScoresMatchAndroid() {
        let query = "Saga of Tanya the Evil Season 2"
        let plain = [query, TitleMatching.baseSeriesTitle(query)].map { TitleMatching.selectionScore($0, "Saga of Tanya the Evil") }.max()!
        let sequel = [query, TitleMatching.baseSeriesTitle(query)].map { TitleMatching.selectionScore($0, "Saga of Tanya the Evil II") }.max()!
        #expect(plain > sequel)
    }
}
