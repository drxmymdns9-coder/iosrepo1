#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UIKit

/// Settings → Appearance, after the Android app's: a live preview of the theme, the presets, and a
/// row for each choice a preset is made of, so a preset is a starting point.
struct AppearanceSettings: View {
    @Environment(\.palette) private var palette
    @AppStorage(Setting.searchAsYouType) private var searchAsYouType = true
    @AppStorage(AppIconSync.key) private var iconMatchesTheme = true
    @State private var arranging = false
    @State private var editingCardDetails = false

    var body: some View {
        let store = AppearanceStore.shared
        let spec = store.spec

        Group {
            ThemePreviewCard()
                .padding(.bottom, 6)

        SettingsSectionHeader(title: "Theme presets")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ThemePreset.allCases) { preset in
                    PresetTile(preset: preset, selected: preset.matches(spec)) { store.apply(preset) }
                }
            }
            .padding(.vertical, 4)
        }

        }
        Group {
        ChoiceRow(
            title: "Background",
            detail: "AMOLED black or Material's dark grey",
            options: ThemeBackground.allCases,
            label: \.label,
            selection: Binding(get: { spec.background }, set: { value in store.update { $0.background = value } }),
            kicker: "Appearance",
            explanation: "The canvas behind everything. AMOLED black switches an OLED screen's pixels off entirely and keeps raised cards and sheets just above it; Dark is Material's own dark grey. Takes effect as you choose.",
            optionDetail: { $0.detail },
            keepsOpen: true
        )
        ChoiceRow(
            title: "Accent colour",
            detail: "Buttons, selections and focus, and the seed for the theme",
            options: ThemeAccent.allCases,
            label: \.label,
            selection: Binding(get: { spec.accent }, set: { value in store.update { $0.accent = value } }),
            kicker: "Appearance",
            explanation: "The colour every button, selection, switch and focus highlight is drawn in, and the seed Material 3 generates the rest of the theme from. Monochrome keeps the app black and white.",
            keepsOpen: true,
            leading: AnyView(Circle().fill(palette.primary).frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(palette.line2, lineWidth: 1)))
        )
        SettingsRowShell(title: "Custom colour", detail: "Mix your own accent, or pick from anywhere on screen") {
            ColorPicker("", selection: Binding(
                get: { Color(argb: spec.customSeed) },
                set: { colour in
                    guard let argb = colour.argb else { return }
                    store.update {
                        $0.customSeed = argb
                        $0.accent = .custom
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
        }
        ChoiceRow(
            title: "Colour style",
            detail: spec.accent == .monochrome ? "Pick an accent colour to choose a style" : spec.style.detail,
            options: ThemeStyle.allCases,
            label: \.label,
            selection: Binding(get: { spec.style }, set: { value in store.update { $0.style = value } }),
            disabled: spec.accent == .monochrome,
            kicker: "Appearance",
            explanation: "How Material 3 spreads the accent across the theme. Vivid keeps the exact colour you picked; the others are Material You's own styles, which soften it for dark screens.",
            optionDetail: { $0.detail },
            keepsOpen: true
        )
        ChoiceRow(
            title: "Contrast",
            detail: "How far apart text, outlines and surfaces sit",
            options: ThemeContrast.allCases,
            label: \.label,
            selection: Binding(get: { spec.contrast }, set: { value in store.update { $0.contrast = value } }),
            kicker: "Appearance",
            explanation: "Moves text, outlines and surfaces further apart. Higher contrast helps in glare, on a dim panel, or with low vision.",
            optionDetail: { $0.detail },
            keepsOpen: true
        )
        ToggleRow(
            title: "Accent in the player",
            detail: "Colour the seek bar and selections; off keeps the player white",
            isOn: Binding(get: { spec.playerAccent }, set: { value in store.update { $0.playerAccent = value } })
        )
        ToggleRow(
            title: "Colour anime pages by the show",
            detail: "Each title's page takes its colour from the poster",
            isOn: Binding(get: { store.showColourPages }, set: { store.showColourPages = $0 })
        )
        ToggleRow(
            title: "Match app icon to theme",
            detail: "The home-screen icon takes the accent colour (iOS confirms each change)",
            isOn: $iconMatchesTheme
        )
        .onChange(of: iconMatchesTheme) { _, _ in AppIconSync.sync() }

        }
        Group {
        SettingsSectionHeader(title: "Liquid glass")
        ToggleRow(
            title: "All glass effects",
            detail: "Every part below blurs what is behind it",
            isOn: Binding(get: { store.glass.count == GlassSection.allCases.count }, set: { store.setAllGlass($0) })
        )
        ForEach(GlassSection.allCases) { section in
            ToggleRow(
                title: section.label,
                detail: section.detail,
                isOn: Binding(get: { store.glassEnabled(section) }, set: { store.setGlass(section, $0) })
            )
        }
        ActionRow(title: "Reset theme", detail: "Back to AMOLED black and monochrome", chevron: false) { store.resetTheme() }

        }
        Group {
        SettingsSectionHeader(title: "Layout")
        ToggleRow(
            title: "Keep the bars on screen",
            detail: "Stop the top bar and bottom menu tucking away as you scroll",
            isOn: Binding(get: { store.staticChrome }, set: { store.staticChrome = $0 })
        )
        ToggleRow(title: "Search as you type", detail: "Off: no suggestions, results wait for the search key", isOn: $searchAsYouType)
        ActionRow(title: "Arrange Home", detail: "Reorder Home's rows and choose which to show", value: store.homeLayout == .standard ? "Default" : "Custom") {
            arranging = true
        }
        ActionRow(
            title: "Card details",
            detail: "Which badges and captions posters draw around their artwork",
            value: Self.cardDetailsSummary(store.hiddenPosterElements)
        ) {
            editingCardDetails = true
        }
        ToggleRow(
            title: "Blur episode images",
            detail: "Hide possible spoilers in episode thumbnails",
            isOn: Binding(get: { store.blurEpisodeImages }, set: { store.blurEpisodeImages = $0 })
        )
        ToggleRow(
            title: "Series logos",
            detail: "Show a series' logo instead of its name on its page and in the player",
            isOn: Binding(get: { store.seriesLogos }, set: { store.seriesLogos = $0 })
        )
        ChoiceRow(
            title: "Time format",
            detail: "How clocks and air times are written",
            options: ClockFormat.allCases,
            label: \.label,
            selection: Binding(get: { store.clockFormat }, set: { store.clockFormat = $0 }),
            kicker: "App",
            explanation: "Applies to Schedule's air times and the player's clock. System follows the iPhone's own 12/24-hour setting, which is what most people want.",
            value: store.clockFormat == .system ? "System · \(store.uses24Hour() ? "24-hour" : "12-hour")" : store.clockFormat.label
        )
        }
        .sheet(isPresented: $arranging) { ArrangeHomeSheet() }
        .sheet(isPresented: $editingCardDetails) { CardDetailsSheet() }
    }

    /// Android's value for the row: the one element that is off, by name, while only one is.
    static func cardDetailsSummary(_ hidden: Set<PosterElement>) -> String {
        let total = PosterElement.allCases.count
        switch hidden.count {
        case 0: return "All \(total)"
        case total: return "Artwork only"
        case 1: return "\(PosterElement.allCases.first { hidden.contains($0) }?.label ?? "One") off"
        default: return "\(total - hidden.count) of \(total)"
        }
    }
}

/// The Appearance preview: the parts of the app a theme changes, drawn in the live palette.
private struct ThemePreviewCard: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Play").font(AppFont.labelLarge.weight(.bold)).foregroundStyle(palette.onPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(palette.primary, in: Capsule())
                Text("Save").font(AppFont.labelLarge.weight(.bold)).foregroundStyle(palette.onSecondaryContainer)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(palette.secondaryContainer, in: Capsule())
                Text("Sub").font(AppFont.labelLarge.weight(.bold)).foregroundStyle(palette.onSurface)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(palette.containerHighest, in: Capsule())
                Text("Dub").font(AppFont.labelLarge.weight(.bold)).foregroundStyle(palette.onSurface)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Episode 12 · The Journey Continues").font(AppFont.titleMedium).foregroundStyle(palette.onSurface)
                Text("24 min · Sub and dub").font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                Text("Aired 2 days ago").font(AppFont.bodySmall).foregroundStyle(palette.text3)
            }
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.barTrack)
                    Capsule().fill(palette.primary).frame(width: bar.size.width * 0.6)
                }
            }
            .frame(height: 4)
            HStack(spacing: 8) {
                ForEach([palette.containerLowest, palette.containerLow, palette.container, palette.containerHigh, palette.containerHighest].indices, id: \.self) { index in
                    let colour = [palette.containerLowest, palette.containerLow, palette.container, palette.containerHigh, palette.containerHighest][index]
                    RoundedRectangle(cornerRadius: 6).fill(colour)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line, lineWidth: 1))
                        .frame(height: 26)
                }
                ForEach([palette.primary, palette.onSurfaceVariant, palette.onSurface, palette.error].indices, id: \.self) { index in
                    Circle().fill([palette.primary, palette.onSurfaceVariant, palette.onSurface, palette.error][index]).frame(width: 20, height: 20)
                }
            }
        }
        .padding(16)
        .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
    }
}

/// One preset: a miniature of the canvas with its accent bar, and its name.
private struct PresetTile: View {
    @Environment(\.palette) private var palette
    let preset: ThemePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let look = Palette(ThemeSpec().applying(preset))
        Button(action: action) {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(look.primary).frame(width: 52, height: 12)
                    Capsule().fill(look.containerHigh).frame(height: 7)
                    Capsule().fill(look.container).frame(width: 70, height: 7)
                }
                .padding(12)
                .frame(width: 128, height: 80, alignment: .topLeading)
                .background(look.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? palette.onSurface : palette.line2, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(palette.onSurface, palette.background)
                            .padding(8)
                    }
                }
                Text(preset.label)
                    .font(AppFont.labelLarge)
                    .foregroundStyle(selected ? palette.onSurface : palette.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Card details: which badges and captions posters draw.
private struct CardDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        let store = AppearanceStore.shared
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(PosterElement.allCases) { element in
                        ToggleRow(
                            title: element.label,
                            detail: element.detail,
                            isOn: Binding(get: { store.shows(element) }, set: { store.setShows(element, $0) })
                        )
                    }
                }
                .padding(Metrics.pagePadding)
            }
            .background(palette.background)
            .navigationTitle("Card details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
    }
}

extension Color {
    /// The colour as `0xFFRRGGBB`, for storing a picked custom accent.
    var argb: UInt32? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return 0xFF00_0000 | byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
#endif
