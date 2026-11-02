#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UserNotifications

/// Settings → Subtitles (Android's section): when subtitles come on, which language, and how they
/// look, the last in a sheet of its own with a live preview.
struct SubtitleSettings: View {
    @Environment(\.palette) private var palette
    @AppStorage("subtitles_by_default") private var byDefault = true
    @AppStorage("subtitles_with_dub") private var withDub = false
    @AppStorage(TrackLanguage.subtitleKey) private var language = ""
    @AppStorage(TrackLanguage.secondarySubtitleKey) private var secondLanguage = ""
    @State private var captions = false

    var body: some View {
        ToggleRow(title: "Show subtitles by default", detail: "Text baked into the video cannot be hidden", isOn: $byDefault)
        if byDefault {
            ToggleRow(title: "Also on dubbed audio", detail: "Applies from the next episode", isOn: $withDub)
        }
        ChoiceRow(
            title: "Preferred subtitle language",
            detail: "Which track to take when a source carries several",
            options: TrackLanguage.subtitles.map(\.code),
            label: { TrackLanguage.stored($0, in: TrackLanguage.subtitles).label },
            selection: Self.normalised($language),
            kicker: "Subtitles",
            explanation: "Chosen among the subtitle tracks a source already carries, whenever it offers your language; sources that do not are left on their own first track. It does not turn subtitles on, and the player's subtitle button still overrides it for that episode."
        )
        ChoiceRow(
            title: "Second choice subtitles",
            detail: "Used when the first choice is not in the stream",
            options: TrackLanguage.subtitles.map(\.code),
            label: { TrackLanguage.stored($0, in: TrackLanguage.subtitles).label },
            selection: Self.normalised($secondLanguage),
            kicker: "Subtitles",
            explanation: "Used only when a stream does not carry your first choice. Leave it on Automatic to have no second choice at all."
        )
        ActionRow(title: "Caption appearance", detail: "Font, size, colour, background and position") { captions = true }
        // As on an Android build made without an OpenSubtitles key: the rows are there, switched off.
        ActionRow(title: "OpenSubtitles", detail: "Not configured in this build", value: "Sign in", disabled: true) {}
        ActionRow(title: "Subtitle search language", detail: "Which language the player's subtitle search asks for", value: "Follow device", disabled: true) {}
        Color.clear.frame(height: 0)
            .sheet(isPresented: $captions) { CaptionAppearanceSheet().settingsSheet(palette) }
    }

    /// The stored code as one of the list's, so a two-letter code an earlier build wrote shows as
    /// selected, and is rewritten in Android's form the next time it changes.
    private static func normalised(_ stored: Binding<String>) -> Binding<String> {
        Binding(get: { TrackLanguage.stored(stored.wrappedValue, in: TrackLanguage.subtitles).code }, set: { stored.wrappedValue = $0 })
    }
}

/// Android's `CaptionAppearanceDialog`: every part of the caption, over a preview of it.
private struct CaptionAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @AppStorage(CaptionKey.textScale) private var scale = 100
    @AppStorage(CaptionKey.textOpacity) private var textOpacity = 100
    @AppStorage(CaptionKey.textColor) private var textColor = "white"
    @AppStorage(CaptionKey.bold) private var bold = true
    @AppStorage(CaptionKey.edge) private var edge = "none"
    @AppStorage(CaptionKey.font) private var font = "sans"
    @AppStorage(CaptionKey.backgroundColor) private var backgroundColor = "black"
    @AppStorage(CaptionKey.backgroundOpacity) private var backgroundOpacity = 60
    @AppStorage(CaptionKey.position) private var position = "bottom"
    @AppStorage(CaptionKey.margin) private var margin = 12
    @AppStorage(CaptionKey.horizontalAnchor) private var anchor = 50

    var body: some View {
        SettingsSheet(kicker: "Subtitles", title: "Caption appearance") {
            preview
            SettingsSectionHeader(title: "Text")
            ChoiceRow(title: "Font", options: CaptionOptions.fonts.map(\.value),
                      label: { value in CaptionOptions.fonts.first { $0.value == value }?.label ?? value }, selection: $font, keepsOpen: true)
            stepper("Size", value: $scale, range: 50...200, step: 5, suffix: "%")
            stepper("Opacity", value: $textOpacity, range: 20...100, step: 10, suffix: "%")
            ChoiceRow(title: "Colour", options: CaptionOptions.textColors.map(\.value),
                      label: { value in CaptionOptions.textColors.first { $0.value == value }?.label ?? value }, selection: $textColor, keepsOpen: true)
            ToggleRow(title: "Bold", isOn: $bold)
            ChoiceRow(title: "Edge", options: CaptionOptions.edges.map(\.value),
                      label: { value in CaptionOptions.edges.first { $0.value == value }?.label ?? value }, selection: $edge, keepsOpen: true)
            SettingsSectionHeader(title: "Background")
            ChoiceRow(title: "Background colour", options: CaptionOptions.backgroundColors.map(\.value),
                      label: { value in CaptionOptions.backgroundColors.first { $0.value == value }?.label ?? value }, selection: $backgroundColor, keepsOpen: true)
            stepper("Background opacity", value: $backgroundOpacity, range: 0...100, step: 10, suffix: "%")
            SettingsSectionHeader(title: "Position")
            ChoiceRow(title: "Where", options: CaptionOptions.positions.map(\.value),
                      label: { value in CaptionOptions.positions.first { $0.value == value }?.label ?? value }, selection: $position)
            stepper("Distance from the edge", value: $margin, range: 0...40, step: 2, suffix: "%")
            stepper("Across the picture", value: $anchor, range: 0...100, step: 5, suffix: "%")
            Text("Applies to the built-in player and to subtitle files a server sends. Text burned into the video can't change.")
                .font(AppFont.labelSmall)
                .foregroundStyle(palette.text3)
                .padding(.top, 8)
        } footer: {
            Button("Reset") {
                for key in CaptionKey.all { UserDefaults.standard.removeObject(forKey: key) }
            }
            .foregroundStyle(palette.error)
            Button("Done") { dismiss() }
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack(alignment: position == "top" ? .top : .bottom) {
                LinearGradient(colors: [Color(argb: 0xFF3A4A5E), Color(argb: 0xFF1B2230)], startPoint: .topLeading, endPoint: .bottomTrailing)
                let room = proxy.size.width - 32
                CaptionText(text: "This is how subtitles look.", baseSize: 15)
                    .alignmentGuide(.leading) { caption in -max(0, room - caption.width) * CGFloat(min(max(anchor, 0), 100)) / 100 }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(position == "top" ? .top : .bottom, max(8, CGFloat(margin) / 100 * 170))
            }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 4)
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, suffix: String) -> some View {
        StepperRow(label: title, value: "\(value.wrappedValue)\(suffix)", decrease: "−", increase: "+",
                   canDecrease: value.wrappedValue > range.lowerBound, canIncrease: value.wrappedValue < range.upperBound,
                   onDecrease: { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) },
                   onIncrease: { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) })
    }
}

/// Settings → Servers (Android's section): which servers are asked, and which are tried first.
/// Stored as Android stores them: the ones switched off, and up to three picked in order.
struct ServerSettings: View {
    @Environment(\.palette) private var palette
    @AppStorage("disabled_providers") private var disabledRaw = ""
    @AppStorage("server_priority") private var priorityRaw = ""
    @State private var editingEnabled = false
    @State private var editingPriority = false

    private var disabled: Set<String> { Set(disabledRaw.split(separator: ",").map(String.init)) }
    private var priority: [String] { priorityRaw.split(separator: ",").map(String.init).filter { id in Self.servers.contains { $0.id == id } } }

    /// The servers Settings lists: the adult-only ones only while adult content is shown.
    static var servers: [any StreamProvider] { SourceHub.selectable(hideAdult: ContentSettings.hideAdult) }

    var body: some View {
        let all = Self.servers
        let on = all.filter { !disabled.contains($0.id) }.count
        ActionRow(title: "Enabled servers", detail: "Servers switched off are never tried",
                  value: on == all.count ? "All \(all.count)" : "\(on) of \(all.count)") { editingEnabled = true }
        ActionRow(title: "Server priority", detail: "The order sources are tried in",
                  value: priority.first.flatMap(Self.name).map { $0 + (priority.count > 1 ? " +\(priority.count - 1)" : "") } ?? "Automatic") {
            editingPriority = true
        }
        Color.clear.frame(height: 0)
            .sheet(isPresented: $editingEnabled) {
                EnabledServersSheet(disabledRaw: $disabledRaw, priorityRaw: $priorityRaw).settingsSheet(palette)
            }
            .sheet(isPresented: $editingPriority) {
                ServerPrioritySheet(disabledRaw: disabledRaw, priorityRaw: $priorityRaw).settingsSheet(palette)
            }
    }

    static func name(_ id: String) -> String? { SourceHub.all.first { $0.id == id }?.name }

    static func detail(_ id: String) -> String? {
        switch id {
        case "miruro": return "Sub, dub and soft subtitles across several servers; episode titles, stills and skip times"
        case "anichan": return "Its own 1080p server, sub and dub, subtitles in a dozen languages"
        case "xfdm": return "Header-free MP4 with Chinese subtitles burned in"
        case "anikoto": return "MegaPlay, sub and dub, subtitles in many languages; its web player as a fallback"
        case "anidbapp": return "AniDB's player API: header-free HLS, sub and dub"
        case "anipm": return "Sub and dub through Settlar, with soft subtitles"
        case "zoko": return "1080p sub and dub with soft subtitles; slow on uncached episodes"
        case "animeheaven": return "Hard-subbed MP4; a fallback"
        case "kaa": return "KickAssAnime's own CDN: 1080p, sub and dub on one stream, soft subtitles"
        case "anizone": return "1080p sub with subtitles in many languages"
        case "animegg": return "MP4 mirrors, sub and dub"
        case "uniquestream": return "A Crunchyroll mirror: sub and dub, many subtitle languages"
        case "animeav1": return "Spanish subtitles and dub; plays first only when Spanish is your language"
        case "animekai": return "Embed servers, the ones that name their stream (else their web players); sub and dub"
        case "rareanimes": return "Hindi, Tamil and Telugu dubs in a web player; first only when Hindi is your language"
        case "animedekho": return "Hindi dubs in web players; first only when Hindi is your language"
        case "toonhub": return "Hindi dubs in web players; first only when Hindi is your language"
        case "animekhor": return "Donghua only, subtitled, in web players (Dailymotion, ok.ru …)"
        case "hentaihaven": return "Adult titles only: HLS with subtitles in about twenty languages"
        case "hstream": return "Adult titles only: 720p MP4 with English subtitles on every episode"
        case "hanime": return "Adult titles only: 720p and lower, resolved through its own page in a hidden web view"
        default: return nil
        }
    }
}

/// Which servers may be used at all (Android's `EnabledServersPicker`). The last one on stays on.
private struct EnabledServersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var disabledRaw: String
    @Binding var priorityRaw: String

    var body: some View {
        let all = ServerSettings.servers
        let disabled = Set(disabledRaw.split(separator: ",").map(String.init))
        let on = all.filter { !disabled.contains($0.id) }.count
        SettingsSheet(kicker: "Servers", title: "Enabled servers", metadata: "\(on) of \(all.count) on",
                      explanation: "A server that is off is never asked for episodes and never offered in the player. At least one has to stay on.") {
            ForEach(all, id: \.id) { provider in
                let enabled = !disabled.contains(provider.id)
                SelectionOptionRow(title: provider.name, subtitle: ServerSettings.detail(provider.id), selected: enabled,
                                   enabled: !enabled || on > 1) {
                    var next = disabled
                    if enabled { next.insert(provider.id) } else { next.remove(provider.id) }
                    disabledRaw = next.sorted().joined(separator: ",")
                    // A rank on a server that is never asked is a preference nothing can honour.
                    priorityRaw = priorityRaw.split(separator: ",").map(String.init).filter { !next.contains($0) }.joined(separator: ",")
                    Log.info("settings", "servers off → \(disabledRaw.isEmpty ? "none" : disabledRaw)")
                }
            }
        } footer: {
            if on < all.count {
                Button("Turn all on") { disabledRaw = "" }
            }
            Button("Done") { dismiss() }
        }
    }
}

/// Server priority as a ranked pick (Android's `ServerPriorityPicker`): tapping a server gives it
/// the next number, tapping it again takes it out and closes the gap. Up to three.
private struct ServerPrioritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let disabledRaw: String
    @Binding var priorityRaw: String

    static let maximum = 3

    var body: some View {
        let disabled = Set(disabledRaw.split(separator: ",").map(String.init))
        let servers = ServerSettings.servers.filter { !disabled.contains($0.id) }
        let priority = priorityRaw.split(separator: ",").map(String.init)
        SettingsSheet(kicker: "Servers", title: "Server priority", metadata: "Up to \(Self.maximum), tried in the order you pick them",
                      explanation: "With none picked, the built-in order is used. Servers are asked together either way; this decides which one plays first.") {
            ForEach(servers, id: \.id) { provider in
                let rank = priority.firstIndex(of: provider.id)
                ChoiceOptionRow(title: provider.name, subtitle: ServerSettings.detail(provider.id), trailing: rank.map { "#\($0 + 1)" },
                                selected: rank != nil, enabled: rank != nil || priority.count < Self.maximum) {
                    let next = rank == nil ? priority + [provider.id] : priority.filter { $0 != provider.id }
                    priorityRaw = next.joined(separator: ",")
                    Log.info("settings", "server order → \(priorityRaw.isEmpty ? "automatic" : priorityRaw)")
                }
            }
        } footer: {
            if !priority.isEmpty {
                Button("Clear") { priorityRaw = "" }.foregroundStyle(palette.error)
            }
            Button("Done") { dismiss() }
        }
    }
}

/// Settings → Notifications (Android's section).
struct NotificationSettings: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette
    @AppStorage(ReleaseAlerts.key) private var releases = true
    @AppStorage(AnnouncementCenter.key) private var announcements = true
    @AppStorage(SigningReminder.key) private var signing = true
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        ToggleRow(title: "Notification alerts", detail: "New episodes of the shows you saved, are watching or plan to watch", isOn: $releases)
            .onChange(of: releases) { _, _ in Task { await ReleaseAlerts.refresh(library: library) } }
        ToggleRow(title: "Announcements", detail: "Rare notices from the developer, like an outage or a moved download", isOn: $announcements)
        if SigningReminder.profile != nil {
            ToggleRow(title: "Signature expiry reminder", detail: "The morning before Anilili's signature runs out, so you can refresh it in SideStore or Sideloadly", isOn: $signing)
                .onChange(of: signing) { _, _ in Task { await SigningReminder.schedule() } }
        }
        if status == .denied {
            ActionRow(title: "Notifications are off for Anilili", detail: "Turn them on in iOS Settings to get alerts") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        SettingsNotice(text: AccountStore.shared.service == .anilist
                       ? "AniList's own notifications are on the bell on Home (\(AccountStore.shared.unreadNotifications) unread). New-episode alerts are scheduled whenever Anilili opens, two weeks ahead, and Schedule reminders arrive 10 minutes before air time."
                       : "New-episode alerts for the shows you saved are scheduled whenever Anilili opens, two weeks ahead, and Schedule reminders arrive 10 minutes before air time.")
            .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}
#endif
