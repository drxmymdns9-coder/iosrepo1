import Foundation
import Testing
@testable import AnililiCore

struct SVGPathTests {
    private typealias P = SVGPath.Point

    @Test func absoluteAndRelativeLinesAndRepeats() {
        #expect(SVGPath.parse("M0 0h512v512H0") == [.move(P(0, 0)), .line(P(512, 0)), .line(P(512, 512)), .line(P(0, 512))])
        // Pairs after a move are lines, relative after a relative move.
        #expect(SVGPath.parse("m 10,10 5,0 0,5 z") == [.move(P(10, 10)), .line(P(15, 10)), .line(P(15, 15)), .close])
        // After Z the pen is back at the subpath's start.
        #expect(SVGPath.parse("M1 1L3 1zl2 2") == [.move(P(1, 1)), .line(P(3, 1)), .close, .line(P(3, 3))])
    }

    @Test func minifiedNumbersSplitWhereTheyShould() {
        // ".31.317" is two numbers, "-5.887-16.602" two more, as Android's AniList logo writes them.
        #expect(SVGPath.parse("M0 0c0-10.698-5.887-16.602-16.558-16.602") ==
            [.move(P(0, 0)), .cubic(P(0, -10.698), P(-5.887, -16.602), P(-16.558, -16.602))])
        #expect(SVGPath.parse("M0 0l.31.317") == [.move(P(0, 0)), .line(P(0.31, 0.317))])
        #expect(SVGPath.parse("M1e2 0") == [.move(P(100, 0))])
    }

    @Test func smoothCurvesReflectTheLastHandle() {
        #expect(SVGPath.parse("M0 0C0 10 10 10 10 0S20 -10 20 0") ==
            [.move(P(0, 0)), .cubic(P(0, 10), P(10, 10), P(10, 0)), .cubic(P(10, -10), P(20, -10), P(20, 0))])
        #expect(SVGPath.parse("M0 0Q5 5 10 0T20 0") == [.move(P(0, 0)), .quad(P(5, 5), P(10, 0)), .quad(P(15, -5), P(20, 0))])
    }

    @Test func androidsLogosParseWhole() {
        let anilist = "M170.68 120 74.999 393h74.338l16.192-47.222h80.96L262.315 393h73.968l-95.314-273zm11.776 165.28 23.183-75.629 25.393 75.629z"
        let segments = SVGPath.parse(anilist)
        #expect(segments.count == 13)
        #expect(segments[1] == .line(P(74.999, 393)))
        #expect(segments[8] == .close)
        guard case .move(let next) = segments[9] else { Issue.record("no second subpath"); return }
        #expect(abs(next.x - 182.456) < 1e-9 && abs(next.y - 285.28) < 1e-9)
        let mal = "m 182.49799,88.40918 v 68.70703 h 39.07974 l 3.78365,-14.65739 H 200.25775 V 88.40918 Z"
        #expect(SVGPath.parse(mal).last == .close)
        // An arc isn't drawn; the path stops there rather than misreading its flags.
        #expect(SVGPath.parse("M0 0A5 5 0 0 1 10 0L20 0") == [.move(P(0, 0))])
    }
}
