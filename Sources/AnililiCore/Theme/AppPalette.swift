import Foundation
import MaterialColorUtilities

/// The app's design tokens as ARGB values: a Material 3 dark scheme plus the roles M3 doesn't name
/// but the Android app's dialogs, player and focus treatment are built on. A port of the Android
/// app's `appColors` (ui/theme/AppColorScheme.kt), generated with the same library, so one seed
/// gives the same colours on both.
public struct AppPalette: Equatable, Sendable {
    public var primary: UInt32
    public var onPrimary: UInt32
    public var primaryContainer: UInt32
    public var onPrimaryContainer: UInt32
    public var secondary: UInt32
    public var onSecondary: UInt32
    public var secondaryContainer: UInt32
    public var onSecondaryContainer: UInt32
    public var tertiary: UInt32
    public var onTertiary: UInt32
    public var tertiaryContainer: UInt32
    public var onTertiaryContainer: UInt32
    public var background: UInt32
    public var onBackground: UInt32
    public var surface: UInt32
    public var onSurface: UInt32
    public var onSurfaceVariant: UInt32
    public var inverseSurface: UInt32
    public var inverseOnSurface: UInt32
    public var error: UInt32
    public var onError: UInt32
    public var errorContainer: UInt32
    public var onErrorContainer: UInt32
    public var outline: UInt32
    public var outlineVariant: UInt32
    public var surfaceBright: UInt32
    public var surfaceContainerLowest: UInt32
    public var surfaceContainerLow: UInt32
    public var surfaceContainer: UInt32
    public var surfaceContainerHigh: UInt32
    public var surfaceContainerHighest: UInt32

    /// The quietest legible text: captions, timestamps, the third line of a row.
    public var text3: UInt32
    /// A hairline inside a container.
    public var line: UInt32
    /// A hairline at a container's own edge.
    public var line2: UInt32
    public var radioRing: UInt32
    public var barTrack: UInt32
    public var disabledFill: UInt32
    public var disabledContent: UInt32
    /// The player's selection colour: the accent when the viewer opted in, white otherwise.
    public var playerAccent: UInt32
    public var onPlayerAccent: UInt32

    /// `surfaceVariant` points at `surfaceContainerHigh`, as on Android (M3 retired the role).
    public var surfaceVariant: UInt32 { surfaceContainerHigh }

    /// Below this tone a pinned `primary` stops reading against AMOLED black.
    static let minPrimaryTone = 40.0

    /// Generates the whole token set with Material 3's dynamic colour rules, with the Android
    /// app's three departures: Vivid pins `primary` to the seed itself, AMOLED black is real black
    /// with the container ladder rebuilt above it (4 / 6 / 10 / 14), and both outlines stay
    /// hairline-dark rather than M3's tone-60 text-field border.
    public init(_ spec: ThemeSpec) {
        self = Self.generation.withLock { AppPalette(unlocked: spec) }
    }

    /// The library's shared `DynamicColor` roles keep an unsynchronised per-scheme cache, so two
    /// palettes generated at once (a show page opening while Settings previews a preset) can
    /// corrupt it. One at a time; each takes well under a millisecond.
    private static let generation = NSLock()

    private init(unlocked spec: ThemeSpec) {
        let monochrome = spec.accent == .monochrome
        let seedArgb: UInt32
        switch spec.accent {
        case .monochrome: seedArgb = 0xFF80_8080
        case .custom: seedArgb = spec.customSeed | 0xFF00_0000
        default: seedArgb = spec.accent.seed ?? 0xFF80_8080
        }
        let source = Hct.fromInt(Int(seedArgb))
        let contrast = spec.contrast.level
        let scheme: DynamicScheme
        if monochrome {
            scheme = SchemeMonochrome(sourceColorHct: source, isDark: true, contrastLevel: contrast)
        } else {
            switch spec.style {
            case .vivid: scheme = SchemeFidelity(sourceColorHct: source, isDark: true, contrastLevel: contrast)
            case .tonal: scheme = SchemeTonalSpot(sourceColorHct: source, isDark: true, contrastLevel: contrast)
            case .neutral: scheme = SchemeNeutral(sourceColorHct: source, isDark: true, contrastLevel: contrast)
            case .vibrant: scheme = SchemeVibrant(sourceColorHct: source, isDark: true, contrastLevel: contrast)
            }
        }
        func role(_ color: DynamicColor) -> UInt32 { UInt32(truncatingIfNeeded: color.getArgb(scheme)) | 0xFF00_0000 }
        func tone(_ palette: TonalPalette, _ value: Double) -> UInt32 {
            UInt32(truncatingIfNeeded: palette.tone(Double(Int(value).clamped(0, 100)))) | 0xFF00_0000
        }
        let neutral = scheme.neutralPalette
        let neutralVariant = scheme.neutralVariantPalette
        // How far the fixed tones below move as contrast rises: 0 at standard, 1 at high.
        let lift = min(max(contrast, 0), 1)
        typealias M = MaterialDynamicColors

        var primary = role(M.primary)
        var onPrimary = role(M.onPrimary)
        if !monochrome, spec.style == .vivid {
            // The seed itself, unless it is too dark to read on black, which only a custom colour
            // can be. Then its own hue, lifted to tone 50.
            primary = source.tone >= Self.minPrimaryTone
                ? seedArgb
                : tone(TonalPalette.of(source.hue, source.chroma), 50)
            onPrimary = Self.luminance(primary) > 0.3 ? tone(scheme.primaryPalette, 10) : 0xFFFF_FFFF
        }

        let amoled = spec.background == .amoled
        let black: UInt32 = 0xFF00_0000
        self.primary = primary
        self.onPrimary = onPrimary
        primaryContainer = role(M.primaryContainer)
        onPrimaryContainer = role(M.onPrimaryContainer)
        secondary = role(M.secondary)
        onSecondary = role(M.onSecondary)
        secondaryContainer = role(M.secondaryContainer)
        onSecondaryContainer = role(M.onSecondaryContainer)
        tertiary = role(M.tertiary)
        onTertiary = role(M.onTertiary)
        tertiaryContainer = role(M.tertiaryContainer)
        onTertiaryContainer = role(M.onTertiaryContainer)
        background = amoled ? black : role(M.background)
        onBackground = role(M.onBackground)
        surface = amoled ? black : role(M.surface)
        onSurface = role(M.onSurface)
        onSurfaceVariant = role(M.onSurfaceVariant)
        inverseSurface = role(M.inverseSurface)
        inverseOnSurface = role(M.inverseOnSurface)
        error = role(M.error)
        onError = role(M.onError)
        errorContainer = role(M.errorContainer)
        onErrorContainer = role(M.onErrorContainer)
        surfaceBright = amoled ? tone(neutral, 18) : role(M.surfaceBright)
        surfaceContainerLowest = amoled ? black : role(M.surfaceContainerLowest)
        surfaceContainerLow = amoled ? tone(neutral, 4) : role(M.surfaceContainerLow)
        surfaceContainer = amoled ? tone(neutral, 6) : role(M.surfaceContainer)
        surfaceContainerHigh = amoled ? tone(neutral, 10) : role(M.surfaceContainerHigh)
        surfaceContainerHighest = amoled ? tone(neutral, 14) : role(M.surfaceContainerHighest)
        outline = tone(neutralVariant, 24 + 18 * lift)
        outlineVariant = tone(neutralVariant, 15 + 12 * lift)

        text3 = tone(neutralVariant, 58 + 14 * lift)
        line = outlineVariant
        line2 = outline
        radioRing = tone(neutralVariant, 40 + 15 * lift)
        barTrack = surfaceContainerHighest
        disabledFill = surfaceContainerHigh
        disabledContent = tone(neutralVariant, 40 + 10 * lift)
        playerAccent = spec.playerAccent ? primary : 0xFFFF_FFFF
        onPlayerAccent = spec.playerAccent ? onPrimary : black
    }

    /// Relative luminance, as Compose's `Color.luminance()` computes it.
    static func luminance(_ argb: UInt32) -> Double {
        func linear(_ component: UInt32) -> Double {
            let value = Double(component & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(argb >> 16) + 0.7152 * linear(argb >> 8) + 0.0722 * linear(argb)
    }

    /// Below this chroma a cover colour is a grey, and a grey has no hue to theme a page with.
    static let minShowChroma = 16.0

    /// AniList's `coverImage.color` (`#RRGGBB`) as a seed worth theming a show's page with, or nil
    /// for a missing, unparseable or near-grey colour.
    public static func showSeed(_ colour: String?) -> UInt32? {
        guard var hex = colour?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        let argb = rgb | 0xFF00_0000
        return Hct.fromInt(Int(argb)).chroma >= minShowChroma ? argb : nil
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
