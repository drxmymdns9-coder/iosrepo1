#if canImport(UIKit)
import AnililiCore
import Observation
import SwiftUI
import UIKit

extension Color {
    /// An `0xAARRGGBB` value, as `AppPalette` produces them.
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}

/// The theme's colours as SwiftUI values: Material 3's roles plus the Android app's extras
/// (`Midnight` tokens). Read through `@Environment(\.palette)`, so a show page can re-seed it.
struct Palette: Equatable {
    let primary: Color
    let onPrimary: Color
    let secondaryContainer: Color
    let onSecondaryContainer: Color
    let background: Color
    let surface: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let error: Color
    let onError: Color
    let outline: Color
    let outlineVariant: Color
    let containerLowest: Color
    let containerLow: Color
    let container: Color
    let containerHigh: Color
    let containerHighest: Color
    let text3: Color
    let line: Color
    let line2: Color
    let radioRing: Color
    let barTrack: Color
    let disabledFill: Color
    let disabledContent: Color
    let playerAccent: Color
    let onPlayerAccent: Color
    let isAmoled: Bool

    init(_ palette: AppPalette, amoled: Bool) {
        primary = Color(argb: palette.primary)
        onPrimary = Color(argb: palette.onPrimary)
        secondaryContainer = Color(argb: palette.secondaryContainer)
        onSecondaryContainer = Color(argb: palette.onSecondaryContainer)
        background = Color(argb: palette.background)
        surface = Color(argb: palette.surface)
        onSurface = Color(argb: palette.onSurface)
        onSurfaceVariant = Color(argb: palette.onSurfaceVariant)
        error = Color(argb: palette.error)
        onError = Color(argb: palette.onError)
        outline = Color(argb: palette.outline)
        outlineVariant = Color(argb: palette.outlineVariant)
        containerLowest = Color(argb: palette.surfaceContainerLowest)
        containerLow = Color(argb: palette.surfaceContainerLow)
        container = Color(argb: palette.surfaceContainer)
        containerHigh = Color(argb: palette.surfaceContainerHigh)
        containerHighest = Color(argb: palette.surfaceContainerHighest)
        text3 = Color(argb: palette.text3)
        line = Color(argb: palette.line)
        line2 = Color(argb: palette.line2)
        radioRing = Color(argb: palette.radioRing)
        barTrack = Color(argb: palette.barTrack)
        disabledFill = Color(argb: palette.disabledFill)
        disabledContent = Color(argb: palette.disabledContent)
        playerAccent = Color(argb: palette.playerAccent)
        onPlayerAccent = Color(argb: palette.onPlayerAccent)
        isAmoled = amoled
    }

    init(_ spec: ThemeSpec) {
        self.init(AppPalette(spec), amoled: spec.background == .amoled)
    }

    /// Android's `Midnight.Panel` and friends, named the way its dialogs use them.
    var panel: Color { containerLow }
    var panel2: Color { container }
    var hover: Color { containerHigh }
    var text2: Color { onSurfaceVariant }
    /// `surfaceVariant` is `surfaceContainerHigh`, as on Android.
    var surfaceVariant: Color { containerHigh }

    /// A switch's "on" colour. iOS draws the knob white whatever the track, so a light accent
    /// (the default white one) would leave a white knob on a white track; that becomes gray.
    /// Android avoids it by darkening the knob instead (`MidnightSwitch`).
    var switchTint: Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(primary).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return primary }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.6 ? Color(uiColor: .systemGray) : primary
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(ThemeSpec())
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// The parts of the interface that draw live frosted glass, each switchable on its own (Android's
/// `GlassSection`; the stored key is `glass_<raw value>`).
enum GlassSection: String, CaseIterable, Identifiable {
    case navigation, home, details, browse, popups, refresh

    var id: String { rawValue }
    var label: String {
        switch self {
        case .navigation: return "Navigation bar"
        case .home: return "Home"
        case .details: return "Details"
        case .browse: return "Browse"
        case .popups: return "Popups"
        case .refresh: return "Refresh spinner"
        }
    }
    var detail: String {
        switch self {
        case .navigation: return "Home's random-pick button over the tab bar"
        case .home: return "Genre pills, spotlight tags, card buttons and the header"
        case .details: return "The header once you scroll down a title"
        case .browse: return "The search header over the results"
        case .popups: return "Blur the screen behind popups and sheets"
        case .refresh: return "The circle you pull down to reload a page"
        }
    }
}

/// A poster's badges and captions, each switchable (Android's `PosterElement`).
enum PosterElement: String, CaseIterable, Identifiable {
    case score, dub
    case newEpisodes = "new_episodes"
    case progress, adult, title, details

    var id: String { rawValue }
    var label: String {
        switch self {
        case .score: return "Score"
        case .dub: return "Dub marker"
        case .newEpisodes: return "New episodes"
        case .progress: return "Episode progress"
        case .adult: return "Adult marker"
        case .title: return "Title"
        case .details: return "Details line"
        }
    }
    var detail: String {
        switch self {
        case .score: return "The star rating, and your own score in My library"
        case .dub: return "The DUB tag on titles with an English dub"
        case .newEpisodes: return "The \"3 NEW\" count on a library title that has aired past you"
        case .progress: return "How far into a library title you are, as 5/12"
        case .adult: return "The 18+ tag on adult titles"
        case .title: return "The name under the artwork"
        case .details: return "Format, year and episode count under the title"
        }
    }
}

enum ClockFormat: String, CaseIterable, Identifiable {
    case system
    case twelveHour = "12"
    case twentyFourHour = "24"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }
}

/// Everything the Appearance section decides, persisted under the Android app's setting keys so a
/// backup moves a look between the two apps.
@MainActor
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    private(set) var spec: ThemeSpec
    private(set) var palette: Palette
    private var storedShowColourPages: Bool
    private var storedSeriesLogos: Bool
    private var storedBlurEpisodeImages: Bool
    private var storedStaticChrome: Bool
    private var storedClockFormat: ClockFormat

    var showColourPages: Bool {
        get { storedShowColourPages }
        set { storedShowColourPages = newValue; defaults.set(newValue, forKey: Key.showColourPages) }
    }
    var seriesLogos: Bool {
        get { storedSeriesLogos }
        set { storedSeriesLogos = newValue; defaults.set(newValue, forKey: Key.seriesLogos) }
    }
    var blurEpisodeImages: Bool {
        get { storedBlurEpisodeImages }
        set { storedBlurEpisodeImages = newValue; defaults.set(newValue, forKey: Key.blurEpisodeImages) }
    }
    var staticChrome: Bool {
        get { storedStaticChrome }
        set { storedStaticChrome = newValue; defaults.set(newValue, forKey: Key.staticChrome) }
    }
    var clockFormat: ClockFormat {
        get { storedClockFormat }
        set { storedClockFormat = newValue; defaults.set(newValue.rawValue, forKey: Key.clockFormat) }
    }
    private(set) var glass: Set<GlassSection>
    private(set) var hiddenPosterElements: Set<PosterElement>
    private(set) var homeLayout: HomeLayout

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let background = "theme_background"
        static let accent = "theme_accent"
        static let style = "theme_style"
        static let contrast = "theme_contrast"
        static let playerAccent = "player_accent"
        static let customSeed = "theme_custom_seed"
        static let showColourPages = "show_colour_pages"
        static let seriesLogos = "show_series_logos"
        static let blurEpisodeImages = "blur_episode_images"
        static let staticChrome = "static_app_chrome"
        static let clockFormat = "clock_format"
        static let hiddenPosterElements = "hidden_poster_elements"
        static let homeLayout = "home_layout"
        static func glass(_ section: GlassSection) -> String { "glass_\(section.rawValue)" }
    }

    private init() {
        let defaults = UserDefaults.standard
        var spec = ThemeSpec()
        spec.background = defaults.string(forKey: Key.background).flatMap(ThemeBackground.init(rawValue:)) ?? .amoled
        spec.accent = defaults.string(forKey: Key.accent).flatMap(ThemeAccent.init(rawValue:)) ?? .monochrome
        spec.style = defaults.string(forKey: Key.style).flatMap(ThemeStyle.init(rawValue:)) ?? .vivid
        spec.contrast = defaults.string(forKey: Key.contrast).flatMap(ThemeContrast.init(rawValue:)) ?? .standard
        spec.playerAccent = defaults.bool(forKey: Key.playerAccent)
        if let seed = defaults.object(forKey: Key.customSeed) as? Int { spec.customSeed = UInt32(truncatingIfNeeded: seed) }
        self.spec = spec
        palette = Palette(spec)
        storedShowColourPages = defaults.object(forKey: Key.showColourPages) as? Bool ?? true
        storedSeriesLogos = defaults.object(forKey: Key.seriesLogos) as? Bool ?? true
        storedBlurEpisodeImages = defaults.bool(forKey: Key.blurEpisodeImages)
        storedStaticChrome = defaults.bool(forKey: Key.staticChrome)
        storedClockFormat = defaults.string(forKey: Key.clockFormat).flatMap(ClockFormat.init(rawValue:)) ?? .system
        glass = Set(GlassSection.allCases.filter { defaults.object(forKey: Key.glass($0)) as? Bool ?? true })
        hiddenPosterElements = Set(
            (defaults.string(forKey: Key.hiddenPosterElements) ?? "").split(separator: ",").compactMap { PosterElement(rawValue: String($0)) }
        )
        homeLayout = HomeLayout.decode(defaults.string(forKey: Key.homeLayout))
        Log.info("theme", "loaded \(spec.background.rawValue)/\(spec.accent.rawValue)/\(spec.style.rawValue)/\(spec.contrast.rawValue)")
    }

    /// Every key this store keeps, for backups (Android's names).
    static var keys: [String] {
        [Key.background, Key.accent, Key.style, Key.contrast, Key.playerAccent, Key.customSeed, Key.showColourPages,
         Key.seriesLogos, Key.blurEpisodeImages, Key.staticChrome, Key.clockFormat, Key.hiddenPosterElements, Key.homeLayout]
            + GlassSection.allCases.map(Key.glass)
    }

    /// Reads everything again after a restore wrote new values underneath.
    func reload() {
        let fresh = AppearanceStore()
        spec = fresh.spec
        palette = fresh.palette
        storedShowColourPages = fresh.storedShowColourPages
        storedSeriesLogos = fresh.storedSeriesLogos
        storedBlurEpisodeImages = fresh.storedBlurEpisodeImages
        storedStaticChrome = fresh.storedStaticChrome
        storedClockFormat = fresh.storedClockFormat
        glass = fresh.glass
        hiddenPosterElements = fresh.hiddenPosterElements
        homeLayout = fresh.homeLayout
    }

    func update(_ change: (inout ThemeSpec) -> Void) {
        var next = spec
        change(&next)
        guard next != spec else { return }
        spec = next
        palette = Palette(next)
        defaults.set(next.background.rawValue, forKey: Key.background)
        defaults.set(next.accent.rawValue, forKey: Key.accent)
        defaults.set(next.style.rawValue, forKey: Key.style)
        defaults.set(next.contrast.rawValue, forKey: Key.contrast)
        defaults.set(next.playerAccent, forKey: Key.playerAccent)
        defaults.set(Int(Int32(bitPattern: next.customSeed)), forKey: Key.customSeed)
        Log.info("theme", "now \(next.background.rawValue)/\(next.accent.rawValue)/\(next.style.rawValue)/\(next.contrast.rawValue)")
        AppIconSync.sync()
    }

    func apply(_ preset: ThemePreset) {
        update { $0 = $0.applying(preset) }
    }

    /// Back to AMOLED black and monochrome, keeping the custom colour the viewer mixed.
    func resetTheme() {
        update { spec in
            let seed = spec.customSeed
            spec = ThemeSpec()
            spec.customSeed = seed
        }
    }

    func glassEnabled(_ section: GlassSection) -> Bool { glass.contains(section) }

    func setGlass(_ section: GlassSection, _ on: Bool) {
        if on { glass.insert(section) } else { glass.remove(section) }
        defaults.set(on, forKey: Key.glass(section))
    }

    func setAllGlass(_ on: Bool) {
        for section in GlassSection.allCases { setGlass(section, on) }
    }

    func shows(_ element: PosterElement) -> Bool { !hiddenPosterElements.contains(element) }

    func setShows(_ element: PosterElement, _ shown: Bool) {
        if shown { hiddenPosterElements.remove(element) } else { hiddenPosterElements.insert(element) }
        // Stored as what is off, so elements added later start visible.
        let stored = PosterElement.allCases.filter(hiddenPosterElements.contains).map(\.rawValue).joined(separator: ",")
        defaults.set(stored, forKey: Key.hiddenPosterElements)
    }

    func setHomeLayout(_ layout: HomeLayout) {
        homeLayout = layout
        defaults.set(layout.encode(), forKey: Key.homeLayout)
    }

    /// The palette for a show's own page: its cover colour as the seed, the viewer's canvas,
    /// style and contrast kept. Nil when the setting is off or the colour is too grey to use.
    func showPalette(_ coverColour: String?) -> Palette? {
        guard showColourPages, let seed = AppPalette.showSeed(coverColour) else { return nil }
        return Palette(spec.seeded(by: seed))
    }

    func uses24Hour() -> Bool {
        switch clockFormat {
        case .twelveHour: return false
        case .twentyFourHour: return true
        case .system:
            let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
            return !format.contains("a")
        }
    }
}
#endif
