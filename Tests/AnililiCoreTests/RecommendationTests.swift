import Foundation
import Testing
@testable import AnililiCore

/// The desktop's `recs.rs` tests, ported.
struct RecommendationTests {
    private func graph() throws -> NeighbourGraph {
        try NeighbourGraph(Data("""
        #anilili-neighbours\t1\t2026-10-04
        1\t1\t0\t10:90,11:60,2:80,99:95,98:85
        2\t1\t0\t10:50,12:40
        5\t5\t0\t11:90,12:70
        10\t10\t0\t1:90
        11\t11\t0\t5:80
        12\t12\t0\t
        99\t99\t1\t1:50
        98\t98\t2\t1:50

        """.utf8))
    }

    @Test func parsesThePublishedFormat() throws {
        let g = try graph()
        #expect(g.count == 8)
        #expect(g.generated == "2026-10-04")
        #expect(g.root(of: 2) == 1)
        #expect(g.root(of: 777) == 777)
        #expect(g.isAdult(99) && g.isUnreleased(98) && !g.isAdult(1))
        #expect(g.neighbours(1).first?.id == 10)
        #expect(throws: NeighbourGraph.Failure.unsupportedVersion(2)) { try NeighbourGraph(Data("#anilili-neighbours\t2\nx".utf8)) }
        #expect(throws: NeighbourGraph.Failure.notNeighbours) { try NeighbourGraph(Data("<html>".utf8)) }
    }

    @Test func recommendsNeighboursOfWhatWasLiked() throws {
        let g = try graph()
        let liked = [Recommendations.Signal(id: 1, weight: 1)]
        let recs = Recommendations.recommend(g, signals: liked, exclude: [], hideAdult: true, limit: 10)
        #expect(recs.map(\.id) == [10, 11])
        #expect(recs.allSatisfy { $0.because == 1 })
        let mixed = [Recommendations.Signal(id: 1, weight: 1), Recommendations.Signal(id: 5, weight: -0.8)]
        #expect(Recommendations.recommend(g, signals: mixed, exclude: [], hideAdult: true, limit: 10).map(\.id) == [10])
        #expect(Recommendations.recommend(g, signals: liked, exclude: [10], hideAdult: true, limit: 10).map(\.id) == [11])
    }

    @Test func weighsTheListAgainstTheViewersOwnScale() {
        let now = 2_000_000_000
        let list = [
            Recommendations.Rating(id: 1, status: .completed, score: 9, updatedAt: now),
            Recommendations.Rating(id: 2, status: .completed, score: 7, updatedAt: now),
            Recommendations.Rating(id: 3, status: .dropped, score: 0, updatedAt: now),
            Recommendations.Rating(id: 4, status: .completed, score: 3, updatedAt: now),
        ]
        let played = [Recommendations.Played(id: 1, episodesWatched: 12, updatedAt: now),
                      Recommendations.Played(id: 8, episodesWatched: 5, updatedAt: now)]
        let s = Recommendations.signals(list: list, played: played, feedback: [(9, Recommendations.diceOpened), (1, Recommendations.diceSkipped)], now: now)
        func w(_ id: Int) -> Double? { s.first { $0.id == id }?.weight }
        #expect(w(1)! > w(2)!)
        #expect(w(3) == -0.8)
        #expect(w(4) == -0.6)
        #expect(w(8) == 0.9)
        #expect(w(9) == Recommendations.diceOpened)
        let old = [Recommendations.Rating(id: 1, status: .completed, score: 0, updatedAt: now - Int(Recommendations.yearSeconds))]
        #expect(abs(Recommendations.signals(list: old, played: [], now: now)[0].weight - 0.5) < 1e-9)
    }

    @Test func featuresTheLatestFinishedTitle() throws {
        let g = try graph()
        let list = [
            Recommendations.Rating(id: 10, status: .completed, score: 0, updatedAt: 100),
            Recommendations.Rating(id: 5, status: .completed, score: 0, updatedAt: 200),
            Recommendations.Rating(id: 1, status: .current, score: 0, updatedAt: 300),
        ]
        #expect(Recommendations.featuredSeed(g, list: list, played: [], now: 400) == 5)
        #expect(Recommendations.featuredSeed(g, list: [], played: [.init(id: 11, episodesWatched: 4, updatedAt: 50)], now: 400) == 11)
    }

    @Test func oneFavouriteDoesNotFillTheRow() {
        let ranked = [Recommendations.Pick(id: 1, score: 1, because: 7), Recommendations.Pick(id: 2, score: 0.95, because: 7),
                      Recommendations.Pick(id: 3, score: 0.9, because: 8)]
        #expect(Recommendations.diversify(ranked, limit: 3).map(\.id) == [1, 3, 2])
    }
}
