import Foundation
import Testing
@testable import AnililiCore

/// The Android app's `AppColorSchemeTest`, case for case, so both apps hold the theme engine to
/// the same rules.
struct AppPaletteTests {
    private let black: UInt32 = 0xFF00_0000
    private let white: UInt32 = 0xFFFF_FFFF

    private func luminance(_ argb: UInt32) -> Double { AppPalette.luminance(argb) }

    @Test func theDefaultIsAmoledBlackAndMonochrome() {
        let palette = AppPalette(ThemeSpec())
        #expect(palette.background == black)
        #expect(palette.surface == black)
        #expect(palette.primary == white)
        #expect(luminance(palette.onPrimary) < 0.1)
    }

    @Test func vividKeepsTheExactColourThatWasPicked() {
        let red = AppPalette(ThemeSpec(accent: .bloodRed))
        #expect(red.primary == ThemeAccent.bloodRed.seed)
        #expect(red.onPrimary == white)
        let green = AppPalette(ThemeSpec(accent: .neonGreen))
        #expect(green.primary == ThemeAccent.neonGreen.seed)
        #expect(luminance(green.onPrimary) < 0.2, "dark copy on neon green")
    }

    @Test func theMaterialYouStylesSoftenTheAccent() {
        let tonal = AppPalette(ThemeSpec(accent: .bloodRed, style: .tonal))
        #expect(tonal.primary != ThemeAccent.bloodRed.seed)
    }

    @Test func amoledKeepsAContainerLadderAbovePureBlack() {
        let palette = AppPalette(ThemeSpec(accent: .purple))
        let ladder = [
            palette.surfaceContainerLowest, palette.surfaceContainerLow, palette.surfaceContainer,
            palette.surfaceContainerHigh, palette.surfaceContainerHighest,
        ].map(luminance)
        #expect(ladder.first == 0)
        #expect(ladder == ladder.sorted())
        #expect(ladder.last! > ladder.first!)
    }

    @Test func darkUsesMaterialsOwnToneRatherThanBlack() {
        #expect(AppPalette(ThemeSpec(background: .dark)).background != black)
    }

    @Test func higherContrastPullsQuietTextFurtherFromTheCanvas() {
        let standard = AppPalette(ThemeSpec(accent: .oceanBlue))
        let high = AppPalette(ThemeSpec(accent: .oceanBlue, contrast: .high))
        #expect(luminance(high.text3) > luminance(standard.text3))
        #expect(luminance(high.line2) > luminance(standard.line2))
    }

    @Test func thePlayerStaysWhiteUnlessTheViewerOptsIn() {
        #expect(AppPalette(ThemeSpec(accent: .purple)).playerAccent == white)
        let on = AppPalette(ThemeSpec(accent: .purple, playerAccent: true))
        #expect(on.playerAccent == on.primary)
    }

    @Test func aCustomAccentIsLiftedOnlyWhenTooDarkToRead() {
        let teal: UInt32 = 0xFF14_B8A6
        #expect(AppPalette(ThemeSpec(accent: .custom, customSeed: teal)).primary == teal)
        let nearBlack: UInt32 = 0xFF10_1820
        let dark = AppPalette(ThemeSpec(accent: .custom, customSeed: nearBlack))
        #expect(dark.primary != nearBlack)
        #expect(luminance(dark.primary) > 0.1, "lifted primary reads on black")
    }

    @Test func everyPresetMatchesItsOwnSettingsAndOnlyItsOwn() {
        for preset in ThemePreset.allCases {
            let spec = ThemeSpec().applying(preset)
            #expect(ThemePreset.allCases.filter { $0.matches(spec) } == [preset])
        }
        // Monochrome ignores the style the viewer cannot see.
        #expect(ThemePreset.midnight.matches(ThemeSpec(style: .vibrant)))
    }

    @Test func showSeedsSkipGreysAndBadInput() {
        #expect(AppPalette.showSeed("#e4a15d") == 0xFFE4_A15D)
        #expect(AppPalette.showSeed("#1a1a1a") == nil)
        #expect(AppPalette.showSeed("nope") == nil)
        #expect(AppPalette.showSeed(nil) == nil)
    }
}
