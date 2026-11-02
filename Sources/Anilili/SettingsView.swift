#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Settings' sections, in the Android app's grid order.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case player, subtitles, downloads, servers, accounts, notifications, content, appearance, data, app, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "Player"
        case .subtitles: return "Subtitles"
        case .downloads: return "Downloads"
        case .servers: return "Servers"
        case .accounts: return "Accounts & sync"
        case .notifications: return "Notifications"
        case .content: return "Content"
        case .appearance: return "Appearance"
        case .data: return "Data"
        case .app: return MenuLanguage.usesSpanish ? "Aplicación" : "App"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .player: return "play.circle"
        case .subtitles: return "captions.bubble"
        case .downloads: return "arrow.down.to.line"
        case .servers: return "server.rack"
        case .accounts: return "arrow.left.arrow.right"
        case .notifications: return "bell"
        case .content: return "eye.slash"
        case .appearance: return "paintpalette"
        case .data: return "externaldrive"
        case .app: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

/// Android's `MenuLanguage`: Spanish relabels the main navigation and Settings' own heading.
enum MenuLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case spanish = "es"

    static let key = "menu_language"

    var id: String { rawValue }

    static var current: MenuLanguage {
        MenuLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    static var usesSpanish: Bool {
        switch current {
        case .spanish: return true
        case .english: return false
        case .system: return Locale.current.language.languageCode?.identifier == "es"
        }
    }

    /// Named in whichever language is on screen.
    func label(spanish: Bool) -> String {
        switch self {
        case .system: return spanish ? "Sistema" : "System"
        case .english: return spanish ? "Inglés" : "English"
        case .spanish: return "Español"
        }
    }
}

/// What this person has looked for in Settings, most recent first (Android's
/// `SettingsSearchHistory`). Kept apart from anime searches, and out of backups.
enum SettingsSearchHistory {
    static let key = "settings_search_history"

    static var entries: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func record(_ query: String) {
        UserDefaults.standard.set(SettingsSearch.recording(query, in: entries), forKey: key)
    }

    static func remove(_ query: String) {
        UserDefaults.standard.set(entries.filter { $0.caseInsensitiveCompare(query) != .orderedSame }, forKey: key)
    }
}

/// The Settings tab: a search over every setting above the grid of sections (Android's index).
struct SettingsView: View {
    @Environment(\.palette) private var palette
    @Environment(AppRouter.self) private var router
    @AppStorage(MenuLanguage.key) private var menuLanguage = MenuLanguage.system.rawValue
    @State private var query = ""
    @State private var history = SettingsSearchHistory.entries
    @FocusState private var searching: Bool

    private var spanish: Bool { MenuLanguage.usesSpanish }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: spanish ? "Ajustes" : "Settings")
                searchField
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(SettingsPage.allCases) { page in
                            NavigationLink(value: Route.settings(page)) { SettingsTile(page: page) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                } else {
                    results
                        .padding(.horizontal, Metrics.pagePadding)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .statusBarShade()
        .background(palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { history = SettingsSearchHistory.entries }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.onSurfaceVariant)
            TextField(spanish ? "Buscar ajustes" : "Search settings", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searching)
                .onSubmit {
                    if let first = SettingsSearch.search(query).first { open(first) }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spanish ? "Borrar búsqueda" : "Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(palette.onSurface.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var results: some View {
        let matches = SettingsSearch.search(query)
        VStack(spacing: 6) {
            ForEach(SettingsSearch.completions(query, history: history), id: \.self) { term in
                SearchResultRow(title: term, subtitle: spanish ? "Búsqueda reciente" : "Recent search", systemImage: "clock.arrow.circlepath") {
                    query = term
                } onRemove: {
                    SettingsSearchHistory.remove(term)
                    history = SettingsSearchHistory.entries
                }
            }
            ForEach(matches) { entry in
                SearchResultRow(title: entry.title, subtitle: entry.sectionTitle, systemImage: nil) { open(entry) }
            }
            if matches.isEmpty {
                Text(spanish ? "Ningún ajuste coincide." : "No setting matches that.")
                    .font(AppFont.bodySmall)
                    .foregroundStyle(palette.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
        }
    }

    /// Opens the section holding `entry` and marks its row (Android's spotlight).
    private func open(_ entry: SettingsSearchEntry) {
        guard let page = SettingsPage(rawValue: entry.sectionID) else { return }
        SettingsSearchHistory.record(query)
        history = SettingsSearchHistory.entries
        query = ""
        searching = false
        router.push(Route.settingsRow(page, entry.title))
    }
}

/// One section on the index: its glyph in the accent, with its name underneath.
private struct SettingsTile: View {
    @Environment(\.palette) private var palette
    let page: SettingsPage

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: page.systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(palette.primary)
                .frame(height: 28)
            Text(page.title)
                .font(AppFont.labelMedium.weight(.semibold))
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // An update waiting, dismissed or quiet, shows on the section that offers it.
            if page == .app, UpdateCenter.shared.pending != nil {
                Circle().fill(palette.primary).frame(width: 10, height: 10).padding(10)
                    .accessibilityLabel("Update available")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A search result or a past search, under the field.
private struct SearchResultRow: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    let systemImage: String?
    let action: () -> Void
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 15)).foregroundStyle(palette.text3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(AppFont.bodyMedium.weight(.semibold)).foregroundStyle(palette.onSurface)
                        Text(subtitle).font(AppFont.labelSmall).foregroundStyle(palette.text3)
                    }
                    Spacer(minLength: 8)
                    if onRemove == nil {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
        .background(palette.onSurface.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Pages

struct SettingsPageView: View {
    @Environment(\.palette) private var palette
    let page: SettingsPage
    /// The row a search asked for: scrolled to and marked for a few seconds.
    var spotlight: String?
    @State private var marked: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch page {
                    case .player: PlayerSettings()
                    case .subtitles: SubtitleSettings()
                    case .downloads: DownloadSettings()
                    case .servers: ServerSettings()
                    case .accounts: AccountSettings()
                    case .notifications: NotificationSettings()
                    case .content: ContentSettingsPage()
                    case .appearance: AppearanceSettings()
                    case .data: DataSettings()
                    case .app: AppSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .environment(\.settingsSpotlight, marked)
            .task(id: spotlight) {
                guard let spotlight else { return }
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(spotlight, anchor: .center) }
                marked = spotlight
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 0.4)) { marked = nil }
            }
        }
        .background(palette.background)
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Settings → Player, in Android's order.
private struct PlayerSettings: View {
    @AppStorage(Setting.playOnOpen) private var playOnOpen = true
    @AppStorage(Setting.openInExternalPlayer) private var openExternally = false
    @AppStorage(Setting.externalPlayer) private var externalPlayer = ""
    @AppStorage(Setting.autoplay) private var autoplay = true
    @AppStorage(Setting.pictureInPicture) private var pictureInPicture = true
    @AppStorage(Setting.pauseDetailsOverlay) private var pauseDetails = true
    @AppStorage(Setting.autoSkipIntroOutro) private var autoSkip = false
    @AppStorage(Setting.showSkipButton) private var skipButton = true
    @AppStorage(PlayerLimits.skipButtonKey) private var skipSeconds = PlayerLimits.skipButtonDefault
    @AppStorage(PlayerLimits.watchedThresholdKey) private var watchedPercent = PlayerLimits.watchedThresholdDefault
    @AppStorage(DefaultQuality.key) private var quality = DefaultQuality.fallback.rawValue
    @AppStorage(PlaybackBufferSize.key) private var buffer = PlaybackBufferSize.automatic.rawValue
    @AppStorage(PlayerLimits.defaultSpeedKey) private var speed = 1.0
    @AppStorage(TrackLanguage.audioKey) private var audio = ""
    @AppStorage(TrackLanguage.secondaryAudioKey) private var secondAudio = ""
    @AppStorage(Setting.playerContentScale) private var screenSize = ScreenSize.fit.rawValue
    @AppStorage(Setting.preferDub) private var preferDub = false
    @AppStorage(Setting.playerClock) private var clock = true
    @AppStorage(Setting.holdToSpeed) private var holdToSpeed = true
    @AppStorage(PlayerLimits.holdSpeedKey) private var holdSpeed = 2.0
    @AppStorage(Setting.playerGestures) private var gestures = true
    @AppStorage(Setting.playerSeekGesture) private var dragToSeek = true
    @AppStorage(Setting.playerStatusBar) private var statusBar = true
    @AppStorage(Setting.showPlayerDebug) private var debugOverlay = false

    var body: some View {
        ToggleRow(title: "Play when an episode opens", detail: "Off: the player waits for you to press play", isOn: $playOnOpen)
        ToggleRow(title: "Open episodes in external player", detail: "Skip Anilili's player and open another installed video app", isOn: $openExternally)
        ChoiceRow(
            title: "External player",
            detail: "Which app receives an episode sent to another player",
            options: [""] + ExternalPlayer.allCases.map(\.storedValue),
            label: { ExternalPlayer(stored: $0)?.name ?? "Ask every time" },
            selection: $externalPlayer,
            kicker: "Player",
            explanation: "Which app receives an episode handed to another player. Naming one skips the question each time. The app has to be installed, and servers that check where a request comes from may refuse to play there.",
            optionDetail: { value in
                switch ExternalPlayer(stored: value) {
                case .vlc: return "VLC for Mobile"
                case .infuse: return "Infuse"
                case nil: return "Asks which app opens each episode"
                }
            }
        )
        ToggleRow(title: "Autoplay next episode", detail: "Continue automatically after the credits", isOn: $autoplay)
        ToggleRow(title: "Keep playing in a mini player", detail: "Off: leaving the app pauses the episode instead of shrinking it into a floating window", isOn: $pictureInPicture)
        ToggleRow(title: "Show details when paused", detail: "After 15s paused. Off: pausing leaves the picture alone", isOn: $pauseDetails)
        ToggleRow(title: "Auto-skip intro, recap and outro", detail: "Use provider or AniSkip timings when available", isOn: $autoSkip)
        ToggleRow(title: "Skip button", detail: "A one-press jump on the controls when a show has no skip timings", isOn: $skipButton)
        if skipButton {
            ChoiceRow(
                title: "Skip button length",
                detail: "How far one press jumps",
                options: PlayerLimits.skipButtonPresets,
                label: { "\($0)s" },
                selection: $skipSeconds,
                kicker: "Player",
                explanation: "How far the player's skip button jumps. A standard TV anime opening is 85 seconds.",
                keepsOpen: true,
                value: "\(PlayerLimits.skipSeconds(skipSeconds))s",
                fineTune: AnyView(SkipLengthStepper())
            )
        }
        ChoiceRow(
            title: "Watched at",
            detail: "When an episode counts as watched",
            options: PlayerLimits.watchedThresholdPresets,
            label: { "\($0)%" },
            selection: $watchedPercent,
            kicker: "Player",
            explanation: "How much of an episode has to play before it counts as watched. Moves Continue Watching on and syncs progress to AniList or MyAnimeList.",
            keepsOpen: true,
            value: "\(PlayerLimits.watchedPercent(watchedPercent))%",
            fineTune: AnyView(WatchedThresholdStepper())
        )
        ChoiceRow(
            title: "Default quality",
            detail: "Picked automatically when an episode starts",
            options: DefaultQuality.allCases.map(\.rawValue),
            label: { DefaultQuality.stored($0).label },
            selection: $quality,
            kicker: "Player",
            explanation: "Picked automatically when an episode starts. Data Saver caps playback at 360p when possible and otherwise uses the closest available low resolution. Auto leaves it to the stream."
        )
        ChoiceRow(
            title: "Buffer size",
            detail: "How far ahead the player downloads, held in memory",
            options: PlaybackBufferSize.allCases.map(\.rawValue),
            label: { PlaybackBufferSize.stored($0).label },
            selection: $buffer,
            kicker: "Player",
            explanation: "How far ahead of the picture the player downloads. A larger buffer rides out an unsteady connection (a distant router, a slow server, a busy evening), so one interruption does not become a stutter. It costs memory, and iOS may stop short of it on a device that is low on it. Automatic leaves it to iOS. Takes effect from the next episode.",
            optionDetail: { PlaybackBufferSize.stored($0).detail }
        )
        ChoiceRow(
            title: "Playback speed",
            detail: "Kept between episodes, and by the player's own speed control",
            options: PlayerLimits.speeds,
            label: { PlayerLimits.speedLabel($0) },
            selection: $speed,
            kicker: "Player",
            explanation: "Every episode starts at this speed. Changing the speed inside the player changes this too, so a speed you pick once carries into the next episode. Past about 2x, time-stretched audio gets hard to follow.",
            optionDetail: { $0 == 1 ? "Normal" : nil }
        )
        ChoiceRow(
            title: "Preferred audio language",
            detail: "Chosen when a stream carries several dubs",
            options: TrackLanguage.audio.map(\.code),
            label: { TrackLanguage.stored($0, in: TrackLanguage.audio).label },
            selection: $audio,
            kicker: "Player",
            explanation: "Some servers carry several dubs in one stream. Your pick is chosen whenever an episode offers it; episodes that do not are left alone."
        )
        ChoiceRow(
            title: "Second choice audio",
            detail: "Used when the first choice is not in the stream",
            options: TrackLanguage.audio.map(\.code),
            label: { TrackLanguage.stored($0, in: TrackLanguage.audio).label },
            selection: $secondAudio,
            kicker: "Player",
            explanation: "Used only when a stream does not carry your first choice. Leave it on Automatic to have no second choice at all."
        )
        ChoiceRow(
            title: "Default screen size",
            detail: "How the picture fits the screen",
            options: ScreenSize.allCases.map(\.rawValue),
            label: { ScreenSize.stored($0).label },
            selection: $screenSize,
            kicker: "Player",
            explanation: "Used every time the player opens. Crop fills the screen without stretching; Fill stretches the picture to the screen edges."
        )
        ToggleRow(title: "Prefer dubbed audio", detail: "Use dub first when available", isOn: $preferDub)
        ToggleRow(title: "Clock and finishing time", detail: "Show the time now and when the episode ends", isOn: $clock)
        ToggleRow(title: "Hold to change speed", detail: "Press and hold the picture to play at \(PlayerLimits.speedLabel(holdSpeed))", isOn: $holdToSpeed)
        if holdToSpeed {
            ChoiceRow(
                title: "Hold speed",
                detail: "Temporary speed while the picture is held",
                options: PlayerLimits.speeds,
                label: { PlayerLimits.speedLabel($0) },
                selection: $holdSpeed,
                kicker: "Player",
                explanation: "The player temporarily uses this speed while you press and hold the picture, then restores the speed you were watching at. This is independent of brightness, volume and seek gestures."
            )
        }
        ToggleRow(title: "Brightness and volume gestures", detail: "Swipe up and down over the picture", isOn: $gestures)
        ToggleRow(title: "Drag to seek", detail: "Swipe left and right to move through the episode", isOn: $dragToSeek)
        ToggleRow(title: "Status bar over the player", detail: "Show the clock and battery with the player's controls (iPhones hide it in landscape)", isOn: $statusBar)
        ToggleRow(title: "Player debug overlay", detail: "Show the server, its state and AVFoundation's last error over the video", isOn: $debugOverlay)
    }
}

/// "Fine tune" under the skip length presets: ±5 s within Android's bounds.
private struct SkipLengthStepper: View {
    @AppStorage(PlayerLimits.skipButtonKey) private var seconds = PlayerLimits.skipButtonDefault

    var body: some View {
        let value = PlayerLimits.skipSeconds(seconds)
        StepperRow(label: "Fine tune", value: "\(value)s", decrease: "−5s", increase: "+5s",
                   canDecrease: value > PlayerLimits.skipButtonRange.lowerBound,
                   canIncrease: value < PlayerLimits.skipButtonRange.upperBound,
                   onDecrease: { seconds = PlayerLimits.skipSeconds(value - 5) },
                   onIncrease: { seconds = PlayerLimits.skipSeconds(value + 5) })
    }
}

/// "Fine tune" under the Watched at presets: ±5% within Android's bounds.
private struct WatchedThresholdStepper: View {
    @AppStorage(PlayerLimits.watchedThresholdKey) private var percent = PlayerLimits.watchedThresholdDefault

    var body: some View {
        let value = PlayerLimits.watchedPercent(percent)
        StepperRow(label: "Fine tune", value: "\(value)%", decrease: "−5%", increase: "+5%",
                   canDecrease: value > PlayerLimits.watchedThresholdRange.lowerBound,
                   canIncrease: value < PlayerLimits.watchedThresholdRange.upperBound,
                   onDecrease: { percent = PlayerLimits.watchedPercent(value - 5) },
                   onIncrease: { percent = PlayerLimits.watchedPercent(value + 5) })
    }
}

/// Settings → Content.
private struct ContentSettingsPage: View {
    @AppStorage(Setting.hideAdult) private var hideAdult = true
    @AppStorage(ContinueVisibility.key) private var onlyWatchable = false

    var body: some View {
        ToggleRow(title: "Hide adult content", detail: "Keep hentai out of Home, Search, Browse and Schedule", isOn: $hideAdult)
        ToggleRow(title: "Only episodes you can watch", detail: "Drop a title from Continue Watching until its next episode is out", isOn: $onlyWatchable)
    }
}

/// Settings → App: the menu language, the layout (on an iPad), the installed version, and what
/// to send when something goes wrong.
private struct AppSettings: View {
    @Environment(\.palette) private var palette
    @AppStorage(MenuLanguage.key) private var menuLanguage = MenuLanguage.system.rawValue
    @AppStorage(FormFactorPreference.key) private var formFactor = FormFactorPreference.automatic.rawValue
    @AppStorage(UpdateCenter.checkOnLaunchKey) private var checkOnLaunch = true
    private var television = TelevisionLayout()
    @State private var diagnostics = false
    @State private var message: String?

    private var updates: UpdateCenter { .shared }

    /// What the check row says under its title (Android's states).
    private var updateDetail: String {
        switch updates.state {
        case .upToDate(let latest):
            return latest == UpdateCenter.installedVersion
                ? "You have the newest version"
                : "You have v\(UpdateCenter.installedVersion); the newest published is v\(latest)"
        case .failed(let message):
            return message
        case .checking, .idle:
            if let quiet = updates.quiet {
                return "Build \(quiet.build.map(String.init) ?? "?") of v\(quiet.version) is ready · tap to install"
            }
            if let waiting = updates.pending {
                return "v\(waiting.version) is ready · tap to install"
            }
            return "Installed v\(UpdateCenter.installedVersion) (build \(UpdateCenter.installedBuild))"
        }
    }

    var body: some View {
        let spanish = MenuLanguage.usesSpanish
        ChoiceRow(
            title: "Menu language",
            detail: spanish ? "Cambia las etiquetas de navegación" : "Changes the main navigation labels",
            options: MenuLanguage.allCases.map(\.rawValue),
            label: { (MenuLanguage(rawValue: $0) ?? .system).label(spanish: spanish) },
            selection: $menuLanguage,
            kicker: spanish ? "Aplicación" : "App",
            explanation: spanish ? "Cambia las etiquetas de navegación principales." : "Changes the main navigation labels."
        )
        // Android's Layout row. Only an iPad has a choice: a phone always gets the phone layout.
        if TelevisionLayout.isPad {
            ChoiceRow(
                title: "Layout",
                detail: "The TV layout's top menu and wide cards, or the phone's tab bar",
                options: FormFactorPreference.allCases.map(\.rawValue),
                label: { FormFactorPreference.stored($0).label },
                selection: $formFactor,
                kicker: spanish ? "Aplicación" : "App",
                explanation: "Automatic gives an iPad the TV layout, as Android TV draws it: a menu across the top, "
                    + "a full-width spotlight, large rows and the player always fullscreen. Phone or tablet keeps the "
                    + "phone's tab bar and pages. Slide Over and narrow Split View windows use the phone layout either way.",
                optionDetail: { value in
                    switch FormFactorPreference.stored(value) {
                    case .automatic: return "TV on this iPad"
                    case .television: return "Menu across the top, player fullscreen"
                    case .handheld: return "Tab bar, as on iPhone"
                    }
                },
                value: FormFactorPreference.stored(formFactor) == .automatic
                    ? "Automatic · \(television.isOn ? "TV" : "tablet")"
                    : FormFactorPreference.stored(formFactor).label
            )
        }
        // Android's update rows: the pop-up's switch, then the check itself.
        ToggleRow(title: "Check for updates on launch", detail: "Show a new version when the app opens", isOn: $checkOnLaunch)
        ActionRow(
            title: updates.state == .checking ? "Checking for updates…" : "Check for updates",
            detail: updateDetail,
            value: "v\(AppInfo.shortVersion)",
            busy: updates.state == .checking,
            disabled: updates.state == .checking
        ) {
            if let waiting = updates.pending {
                updates.showing = waiting
            } else {
                updates.check(manual: true)
            }
        }
        InfoRow(title: "Version", detail: "Installed \(AppInfo.version)", value: "v\(AppInfo.shortVersion)")
        if let profile = SigningReminder.profile {
            InfoRow(title: "Signature", detail: "\(SigningExpiry.remaining(profile, now: Date())) · refresh in SideStore or Sideloadly",
                    value: profile.expires.formatted(date: .abbreviated, time: .omitted))
        }
        ActionRow(title: "Send diagnostics", detail: "Creates a redacted debugging report and lets you send it") {
            message = nil
            diagnostics = true
        }
        if let message { SettingsNotice(text: message, tone: .success) }
        NavigationLink(value: Route.debugLog) {
            SettingsRowShell(title: "Debug log", detail: "Every request and player event; copy it to share") {
                SettingValue()
            }
        }
        .buttonStyle(.plain)
        Color.clear.frame(height: 0)
            .sheet(isPresented: $diagnostics) {
                DiagnosticsSheet { message = $0 }.settingsSheet(palette)
            }
    }
}

/// Android's diagnostics dialog: a description of the problem, required, then a redacted report
/// for the share sheet.
private struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let onShared: (String) -> Void
    @State private var problem = ""
    @State private var report: URL?
    @State private var failure: String?

    var body: some View {
        SettingsSheet(kicker: "App", title: "Send diagnostics",
                      explanation: "Describe the problem so the report has useful context. The app writes a report with sign-in tokens and codes taken out, then you choose where to send it.") {
            TextEditor(text: $problem)
                .scrollContentBackground(.hidden)
                .font(AppFont.bodyMedium)
                .frame(minHeight: 120)
                .padding(10)
                .background(palette.onSurface.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if problem.isEmpty {
                        Text("What happened, and what were you doing?")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(palette.text3)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
            if let failure { SettingsNotice(text: failure, tone: .error) }
            if let report {
                ShareLink(item: report) {
                    Label("Share the report", systemImage: "square.and.arrow.up")
                        .font(AppFont.labelLarge.weight(.bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.primary, in: Capsule())
                }
                .simultaneousGesture(TapGesture().onEnded { onShared("Diagnostic report ready: \(report.lastPathComponent)") })
                .padding(.top, 8)
            }
        } footer: {
            Button("Cancel") { dismiss() }.foregroundStyle(palette.onSurfaceVariant)
            Button(report == nil ? "Create report" : "Create again") { create() }
                .disabled(problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func create() {
        let text = """
        \(AppInfo.summary)

        Problem:
        \(problem.trimmingCharacters(in: .whitespacesAndNewlines))

        Log:
        \(Log.export())
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anilili-diagnostics-\(stamp).txt")
        do {
            try Log.redact(text).write(to: url, atomically: true, encoding: .utf8)
            report = url
            failure = nil
            Log.info("diagnostics", "report written: \(url.lastPathComponent)")
        } catch {
            failure = "Couldn't write the report: \(error.localizedDescription)"
        }
    }
}

/// Settings → About: the community, and the sign-off.
private struct AboutSettings: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        ActionRow(title: "Discord server", detail: "Questions, source problems and release news",
                  leading: AnyView(DiscordMark().fill(style: FillStyle(eoFill: true)).frame(width: 22, height: 22))) {
            if let url = URL(string: "https://discord.gg/Anilili") { openURL(url) }
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("Anilili is a one-person project: an anime app that finds an episode across dozens of sources, remembers where you stopped, and keeps your list in step with AniList or MyAnimeList. No adverts, and no account of its own.")
                .font(AppFont.bodyMedium)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "heart").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.primary)
                Text("Made with love by lili").font(AppFont.bodyMedium.weight(.bold)).foregroundStyle(palette.onSurface)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

/// The Discord mark as Android draws it: a disc with the glyph knocked out, in the row's ink
/// (`ic_brand_discord.xml`, its shallow arcs drawn as straight segments).
private struct DiscordMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 512
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        var path = Path()
        path.move(to: p(256, 0))
        path.addCurve(to: p(512, 256), control1: p(397.385, 0), control2: p(512, 114.615))
        path.addCurve(to: p(256, 512), control1: p(512, 397.385), control2: p(397.385, 512))
        path.addCurve(to: p(0, 256), control1: p(114.615, 512), control2: p(0, 397.385))
        path.addCurve(to: p(256, 0), control1: p(0, 114.615), control2: p(114.615, 0))
        path.closeSubpath()
        path.move(to: p(360.932, 160.621))
        path.addLine(to: p(298.549, 141.439))
        path.addLine(to: p(290.583, 157.682))
        path.addLine(to: p(255.964, 155.079))
        path.addCurve(to: p(221.342, 157.659), control1: p(244.395, 155.079), control2: p(232.769, 155.958))
        path.addCurve(to: p(213.356, 141.436), control1: p(219.008, 152.15), control2: p(216.298, 146.688))
        path.addLine(to: p(150.959, 160.658))
        path.addCurve(to: p(106.126, 332.155), control1: p(111.476, 219.066), control2: p(100.776, 276.015))
        path.addLine(to: p(182.628, 370.553))
        path.addCurve(to: p(199.014, 344.136), control1: p(188.797, 362.226), control2: p(194.323, 353.361))
        path.addLine(to: p(173.201, 331.817))
        path.addCurve(to: p(179.526, 327.061), control1: p(175.365, 330.248), control2: p(177.482, 328.631))
        path.addCurve(to: p(255.999, 344.149), control1: p(203.438, 338.292), control2: p(229.565, 344.149))
        path.addCurve(to: p(332.474, 327.06), control1: p(282.435, 344.149), control2: p(308.561, 338.292))
        path.addCurve(to: p(338.799, 331.815), control1: p(334.543, 328.748), control2: p(336.66, 330.365))
        path.addLine(to: p(312.939, 344.167))
        path.addLine(to: p(329.326, 370.564))
        path.addLine(to: p(405.879, 332.172))
        path.addCurve(to: p(360.932, 160.621), control1: p(412.15, 267.075), control2: p(395.148, 210.649))
        path.closeSubpath()
        path.move(to: p(205.78, 297.63))
        path.addCurve(to: p(178.554, 267.455), control1: p(190.872, 297.63), control2: p(178.554, 284.1))
        path.addCurve(to: p(205.732, 237.162), control1: p(178.554, 250.81), control2: p(190.443, 237.162))
        path.addCurve(to: p(232.982, 267.455), control1: p(221.022, 237.162), control2: p(233.243, 250.81))
        path.addCurve(to: p(205.78, 297.63), control1: p(232.72, 284.1), control2: p(220.974, 297.63))
        path.closeSubpath()
        path.move(to: p(306.219, 297.63))
        path.addCurve(to: p(279.017, 267.455), control1: p(291.286, 297.63), control2: p(279.017, 284.1))
        path.addCurve(to: p(306.219, 237.162), control1: p(279.017, 250.81), control2: p(290.906, 237.162))
        path.addCurve(to: p(333.397, 267.455), control1: p(321.532, 237.162), control2: p(333.659, 250.81))
        path.addCurve(to: p(306.219, 297.63), control1: p(333.136, 284.1), control2: p(321.413, 297.63))
        path.closeSubpath()
        return path
    }
}
#endif
