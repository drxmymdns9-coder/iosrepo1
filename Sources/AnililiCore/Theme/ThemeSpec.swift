import Foundation
import MaterialColorUtilities

// The Appearance choices, ported from the Android app's `data/settings/ThemeSettings.kt`. The
// stored values are Android's, so a backup moves a look between the two apps unchanged.

/// The canvas: what shows where nothing else is drawn.
public enum ThemeBackground: String, CaseIterable, Codable, Sendable, Identifiable {
    case amoled
    case dark

    public var id: String { rawValue }
    public var label: String { self == .amoled ? "AMOLED black" : "Dark" }
    public var detail: String {
        self == .amoled ? "Pure black; OLED screens switch those pixels off" : "Material's dark grey, a little softer in a lit room"
    }
}

/// The seed every colour in the scheme is generated from. Monochrome is the default and the app's
/// long-standing look: white is the accent. Android's "From wallpaper" has no iOS equivalent.
public enum ThemeAccent: String, CaseIterable, Codable, Sendable, Identifiable {
    case monochrome
    case custom
    case purple
    case neonGreen = "neon_green"
    case bloodRed = "blood_red"
    case oceanBlue = "ocean_blue"
    case cyan
    case sakuraPink = "sakura_pink"
    case sunsetOrange = "sunset_orange"
    case gold
    case emerald

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .monochrome: return "Monochrome"
        case .custom: return "Custom"
        case .purple: return "Purple"
        case .neonGreen: return "Neon green"
        case .bloodRed: return "Blood red"
        case .oceanBlue: return "Ocean blue"
        case .cyan: return "Cyan"
        case .sakuraPink: return "Sakura pink"
        case .sunsetOrange: return "Sunset orange"
        case .gold: return "Gold"
        case .emerald: return "Emerald"
        }
    }

    public var seed: UInt32? {
        switch self {
        case .monochrome, .custom: return nil
        case .purple: return 0xFF8B5CF6
        case .neonGreen: return 0xFF39FF14
        case .bloodRed: return 0xFFD1102B
        case .oceanBlue: return 0xFF3B82F6
        case .cyan: return 0xFF22D3EE
        case .sakuraPink: return 0xFFF472B6
        case .sunsetOrange: return 0xFFF97316
        case .gold: return 0xFFFACC15
        case .emerald: return 0xFF10B981
        }
    }

    /// The colour a picker swatch shows.
    public func swatch(customSeed: UInt32) -> UInt32 {
        switch self {
        case .monochrome: return 0xFFFFFFFF
        case .custom: return customSeed | 0xFF00_0000
        default: return seed ?? 0xFFFFFFFF
        }
    }
}

/// How Material 3 spreads the seed. Vivid is the default because it keeps the exact colour picked.
public enum ThemeStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case vivid, tonal, neutral, vibrant

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var detail: String {
        switch self {
        case .vivid: return "The exact colour you picked, surfaces lightly tinted"
        case .tonal: return "Material You's default: a softer, pastel accent"
        case .neutral: return "Mostly grey, with the accent used sparingly"
        case .vibrant: return "Saturated colour on surfaces as well as controls"
        }
    }
}

/// Material 3's contrast level, which moves every tone pair further apart as it rises.
public enum ThemeContrast: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard, medium, high

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var level: Double {
        switch self {
        case .standard: return 0
        case .medium: return 0.5
        case .high: return 1
        }
    }
    public var detail: String {
        switch self {
        case .standard: return "Material's default contrast"
        case .medium: return "Brighter text and firmer outlines"
        case .high: return "The strongest separation, for glare or low vision"
        }
    }
}

/// The custom accent a fresh install starts from: the purple the app used to be.
public let defaultCustomSeed: UInt32 = 0xFF8B5CF6

/// A named look: canvas, accent, style and contrast chosen together.
public enum ThemePreset: String, CaseIterable, Sendable, Identifiable {
    case midnight, crimsonNight, toxic, royal, deepSea, cyber, sakura, ember, gilded, forest, highContrast

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .midnight: return "Midnight"
        case .crimsonNight: return "Crimson Night"
        case .toxic: return "Toxic"
        case .royal: return "Royal"
        case .deepSea: return "Deep Sea"
        case .cyber: return "Cyber"
        case .sakura: return "Sakura"
        case .ember: return "Ember"
        case .gilded: return "Gilded"
        case .forest: return "Forest"
        case .highContrast: return "High contrast"
        }
    }

    public var spec: (background: ThemeBackground, accent: ThemeAccent, style: ThemeStyle, contrast: ThemeContrast) {
        switch self {
        case .midnight: return (.amoled, .monochrome, .vivid, .standard)
        case .crimsonNight: return (.amoled, .bloodRed, .vivid, .standard)
        case .toxic: return (.amoled, .neonGreen, .vibrant, .standard)
        case .royal: return (.amoled, .purple, .vivid, .standard)
        case .deepSea: return (.amoled, .oceanBlue, .vivid, .standard)
        case .cyber: return (.amoled, .cyan, .vibrant, .standard)
        case .sakura: return (.dark, .sakuraPink, .tonal, .standard)
        case .ember: return (.amoled, .sunsetOrange, .vivid, .standard)
        case .gilded: return (.amoled, .gold, .neutral, .standard)
        case .forest: return (.dark, .emerald, .tonal, .standard)
        case .highContrast: return (.amoled, .monochrome, .vivid, .high)
        }
    }

    /// Monochrome has no hue for a style to spread, so the style doesn't stop it matching.
    public func matches(_ theme: ThemeSpec) -> Bool {
        let spec = spec
        return spec.background == theme.background && spec.accent == theme.accent && spec.contrast == theme.contrast
            && (theme.accent == .monochrome || spec.style == theme.style)
    }
}

/// Everything the Appearance section decides, as one value the theme is a pure function of.
public struct ThemeSpec: Equatable, Hashable, Sendable {
    public var background: ThemeBackground = .amoled
    public var accent: ThemeAccent = .monochrome
    public var style: ThemeStyle = .vivid
    public var contrast: ThemeContrast = .standard
    public var playerAccent = false
    public var customSeed: UInt32 = defaultCustomSeed

    public init(
        background: ThemeBackground = .amoled,
        accent: ThemeAccent = .monochrome,
        style: ThemeStyle = .vivid,
        contrast: ThemeContrast = .standard,
        playerAccent: Bool = false,
        customSeed: UInt32 = defaultCustomSeed
    ) {
        self.background = background
        self.accent = accent
        self.style = style
        self.contrast = contrast
        self.playerAccent = playerAccent
        self.customSeed = customSeed
    }

    public func applying(_ preset: ThemePreset) -> ThemeSpec {
        var copy = self
        (copy.background, copy.accent, copy.style, copy.contrast) = preset.spec
        return copy
    }

    /// The same look seeded from a show's colour, for pages coloured by the show.
    public func seeded(by showSeed: UInt32) -> ThemeSpec {
        var copy = self
        copy.accent = .custom
        copy.customSeed = showSeed
        return copy
    }
}
