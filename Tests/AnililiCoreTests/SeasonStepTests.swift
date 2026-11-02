import Foundation
import Testing
@testable import AnililiCore

/// Android's season stepper (`stepSeasonDate`, `stepSeasonWithinBounds`, `seasonLabel`).
struct SeasonStepTests {
    private let today = SeasonStep(season: "FALL", year: 2026)

    @Test func stepsCrossYearsAtWinter() {
        #expect(SeasonStep(season: "WINTER", year: 2026).stepped(-1, today: today) == SeasonStep(season: "FALL", year: 2025))
        #expect(SeasonStep(season: "FALL", year: 2025).stepped(1, today: today) == SeasonStep(season: "WINTER", year: 2026))
        #expect(SeasonStep(season: "SPRING", year: 2026).stepped(1, today: today) == SeasonStep(season: "SUMMER", year: 2026))
    }

    @Test func stopsTwoSeasonsAheadAndAt1900() {
        #expect(today.stepped(1, today: today) == SeasonStep(season: "WINTER", year: 2027))
        #expect(today.stepped(2, today: today) == SeasonStep(season: "SPRING", year: 2027))
        #expect(today.stepped(3, today: today) == nil)
        #expect(SeasonStep(season: "WINTER", year: 1900).stepped(-1, today: today) == nil)
        #expect(SeasonStep(season: "SPRING", year: 1900).stepped(-1, today: today) == SeasonStep(season: "WINTER", year: 1900))
    }

    @Test func labels() {
        #expect(SeasonStep.label("SUMMER", year: 2024) == "Summer 2024")
        #expect(SeasonStep.label("FALL", year: nil) == "Fall")
    }
}
