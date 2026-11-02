#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Speed, quality, screen size, subtitles and audio (Android's `PlayerSettingsSheet`).
struct PlayerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @AppStorage(Setting.playerContentScale) private var screenSize = ScreenSize.fit.rawValue
    @AppStorage("caption_text_scale") private var captionScale = 100
    let engine: PlayerEngine
    let request: PlayRequest
    let onAudio: (AudioTrack) -> Void

    static let speeds: [Float] = PlayerLimits.speeds.map { Float($0) }

    var body: some View {
        NavigationStack {
            List {
                Section("Playback speed") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.speeds, id: \.self) { rate in
                                FilterChip(label: PlayerOverlay.speedLabel(rate), selected: engine.speed == rate) {
                                    engine.setSpeed(rate)
                                    UserDefaults.standard.set(Double(rate), forKey: PlayerLimits.defaultSpeedKey)
                                }
                            }
                        }
                    }
                }
                Section("Quality") {
                    choice("Auto", selected: engine.maxHeight == nil) { engine.setQuality(nil) }
                    ForEach(engine.variants.compactMap(\.height), id: \.self) { height in
                        choice("\(height)p", selected: engine.maxHeight == height) { engine.setQuality(height) }
                    }
                    if engine.variants.isEmpty {
                        Text("This server sends one quality.").foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                Section("Screen size") {
                    Picker("Screen size", selection: Binding(get: { ScreenSize.stored(screenSize).rawValue }, set: { screenSize = $0 })) {
                        ForEach(ScreenSize.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Audio") {
                    ForEach(AudioTrack.allCases) { audio in
                        let has = (audio == .sub ? request.listing.subbed : request.listing.dubbed).contains(request.episode)
                        choice(audio.label, selected: request.audio == audio) {
                            onAudio(audio)
                            dismiss()
                        }
                        .disabled(!has)
                    }
                }
                if !engine.subtitleTracks.isEmpty {
                    Section("Subtitles") {
                        Stepper("Delay \(String(format: "%+.1f", engine.subtitleDelay)) s", onIncrement: {
                            engine.nudgeSubtitles(by: 0.1)
                        }, onDecrement: {
                            engine.nudgeSubtitles(by: -0.1)
                        })
                        Stepper("Size \(captionScale)%", value: $captionScale, in: 60...200, step: 10)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Player settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(palette.onSurface)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(palette.primary) }
            }
        }
    }
}

/// The server picker, after Android's (`MobileServerPickerContent`, `SourceFilterRow`,
/// `ServerChoiceRows`): Sub or Dub, and the languages found across the servers, as filters; then
/// one row per server saying on its second line what a viewer chooses by: whether it's playing,
/// how its subtitles come, its languages, whether it can be saved, and why it failed if it did.
/// The one playing leads. The same sheet opens from the player and from the page under it.
struct ServersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let engine: PlayerEngine
    let request: PlayRequest
    /// Switches the episode to the other audio; its servers are looked up afresh.
    let onAudio: (AudioTrack) -> Void
    @State private var language: String?

    var body: some View {
        let audio = request.audio
        let languages = ServerSummary.languages(of: engine.sources, audio: audio)
        let shown = ordered(ServerSummary.filter(engine.sources, language: language, audio: audio))
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        audioRow(audio)
                        if languages.count > 1 || language != nil {
                            languageRow(languages)
                        }
                        Text(status(count: shown.count))
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(palette.primary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }
                Section("Server") {
                    if engine.sources.isEmpty {
                        Text(engine.phase == .resolving ? "Looking for servers that carry this episode…" : "No servers yet.")
                            .foregroundStyle(palette.onSurfaceVariant)
                    } else if shown.isEmpty {
                        Text("No server matches these filters.").foregroundStyle(palette.onSurfaceVariant)
                    }
                    ForEach(shown) { source in row(source, audio: audio) }
                }
                if let current = engine.current {
                    Section {
                        ForEach(ExternalPlayer.chosen.map { [$0] } ?? ExternalPlayer.allCases) { app in
                            Button("Open in \(app.name)") {
                                engine.player.pause()
                                app.open(current.url)
                            }
                            .foregroundStyle(palette.onSurface)
                        }
                    } header: {
                        Text("Another player")
                    } footer: {
                        Text(current.headers.isEmpty ? "Plays the current server's stream in that app."
                             : "This server checks where requests come from, which other apps can't say, so it may refuse to play there.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Server for this episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
        .onChange(of: languages) { _, found in
            // A language no server here carries any more would filter everything away unseen.
            if let language, !found.contains(language) { self.language = nil }
        }
    }

    /// Sub and Dub, the one not on offer for this episode dimmed. Choosing the other reloads the
    /// episode in it.
    private func audioRow(_ audio: AudioTrack) -> some View {
        HStack(spacing: 8) {
            ForEach(AudioTrack.allCases) { track in
                let has = request.listing.isEmpty || (track == .sub ? request.listing.subbed : request.listing.dubbed).contains(request.episode)
                FilterChip(label: track == .sub ? "Subtitled" : "Dubbed", systemImage: track == .sub ? "captions.bubble" : "waveform", selected: audio == track) {
                    guard track != audio else { return }
                    onAudio(track)
                    dismiss()
                }
                .disabled(!has)
                .opacity(has ? 1 : 0.4)
            }
        }
    }

    private func languageRow(_ languages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Language")
                .font(AppFont.labelSmall.weight(.medium))
                .foregroundStyle(palette.onSurfaceVariant)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "Any", selected: language == nil) { language = nil }
                    ForEach(languages, id: \.self) { option in
                        FilterChip(label: option, selected: language == option) {
                            language = language == option ? nil : option
                        }
                    }
                }
            }
        }
    }

    private func status(count: Int) -> String {
        if engine.phase == .resolving { return "Finding servers…" }
        return "Applies to this episode only · \(count) choice\(count == 1 ? "" : "s")"
    }

    /// The server playing first; the rest in the order they were found.
    private func ordered(_ sources: [VideoSource]) -> [VideoSource] {
        guard let current = engine.current, let index = sources.firstIndex(of: current) else { return sources }
        var rest = sources
        rest.remove(at: index)
        return [current] + rest
    }

    private func failure(_ source: VideoSource) -> String? {
        guard let outcome = engine.attempts.last(where: { $0.source == source })?.outcome,
              outcome != "played", outcome != "loading" else { return nil }
        return outcome
    }

    private func row(_ source: VideoSource, audio: AudioTrack) -> some View {
        let playing = source == engine.current
        let failed = failure(source)
        return HStack(alignment: .top, spacing: 4) {
            Button {
                if !playing { engine.switchTo(source) }
                dismiss()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: playing ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(playing ? palette.primary : palette.onSurfaceVariant)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("\(source.provider) · \(source.server)")
                                .font(AppFont.titleSmall)
                                .foregroundStyle(palette.onSurface)
                                .lineLimit(1)
                            PosterTag(text: tag(source, audio: audio), outlined: false)
                        }
                        Text(ServerSummary.description(of: source, audio: audio, playing: playing, failure: failed))
                            .font(AppFont.labelMedium)
                            .foregroundStyle(failed != nil && !playing ? palette.error : palette.onSurfaceVariant)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Its own button beside the row, not inside it: a tap there saves, and never switches.
            if ServerSummary.canDownload(source) {
                ServerDownloadButton(request: request, source: source)
            }
        }
        // Faded, not removed: a server that just failed may well work on a second try.
        .opacity(failed != nil && !playing ? 0.6 : 1)
    }

    /// The short tag beside a server's name: how it carries the episode.
    private func tag(_ source: VideoSource, audio: AudioTrack) -> String {
        if source.kind == .embed { return "WEB" }
        if audio == .dub { return "DUB" }
        return source.softSub ? "SOFT SUB" : "SUB"
    }
}

/// A server row's save button: saves this episode from this server, then shows how that is going.
/// The episode has one download per audio, so while it is saving or saved the other servers'
/// buttons step back; after a failure or a pause any of them can pick it up.
private struct ServerDownloadButton: View {
    @Environment(\.palette) private var palette
    let request: PlayRequest
    let source: VideoSource

    private var store: DownloadStore { .shared }

    var body: some View {
        let record = store.record(mediaID: request.media.id, episode: request.episode, audio: request.audio)
        // A saved copy belongs to the server it came from, which is another one when the pick failed.
        let owner = record.flatMap { $0.isDone ? $0.source : ($0.preferredSource ?? $0.source) }
        let mine = owner == source.label
        let taken = record.map { $0.isDone || $0.state.isActive } ?? false
        Button {
            store.enqueue(request.media, episode: request.episode, audio: request.audio,
                          title: request.info?.title, thumbnail: request.info?.thumbnail, from: source.label)
        } label: {
            ZStack {
                switch mine ? record?.state : nil {
                case .downloading(let fraction)?:
                    Circle().stroke(palette.line2, lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.03, fraction)).stroke(palette.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                case .queued?:
                    Image(systemName: "clock").font(.system(size: 16)).foregroundStyle(palette.onSurfaceVariant)
                case .paused?:
                    Image(systemName: "play.circle").font(.system(size: 18)).foregroundStyle(palette.primary)
                case .done?:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(palette.primary)
                case .failed?:
                    Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 17)).foregroundStyle(palette.error)
                case nil:
                    Image(systemName: "arrow.down.circle").font(.system(size: 18, weight: .semibold)).foregroundStyle(palette.primary)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(taken)
        .opacity(taken && !mine ? 0.35 : 1)
        .accessibilityLabel(label(record, mine: mine))
    }

    private func label(_ record: DownloadRecord?, mine: Bool) -> String {
        let episode = "episode \(request.episode)"
        guard let record else { return "Save \(episode) from \(source.label)" }
        guard mine else {
            return record.isDone ? "Episode \(request.episode) is already saved" : record.state.isActive
                ? "Episode \(request.episode) is already saving from another server" : "Save \(episode) from \(source.label)"
        }
        switch record.state {
        case .downloading(let fraction): return "Saving \(episode) from this server, \(Int(fraction * 100)) percent"
        case .queued: return "Episode \(request.episode) is waiting to save from this server"
        case .paused: return "Saving \(episode) is paused; tap to resume"
        case .done: return "Episode \(request.episode) is saved from this server"
        case .failed: return "Saving \(episode) failed; tap to try this server again"
        }
    }
}

/// Other iOS players that take a stream URL through their URL scheme (Android hands the stream to
/// an external-player intent instead).
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case vlc, infuse
    var id: String { rawValue }
    var name: String { self == .vlc ? "VLC" : "Infuse" }

    /// Settings → Player → External player, under Android's `external_player_package`: VLC by
    /// its Android package, so a backup means the same app on either phone.
    var storedValue: String { self == .vlc ? "org.videolan.vlc" : "infuse" }

    init?(stored: String) {
        switch stored {
        case "org.videolan.vlc", "vlc": self = .vlc
        case "infuse": self = .infuse
        default: return nil
        }
    }

    /// The app Settings named, or nil for "Ask every time".
    static var chosen: ExternalPlayer? {
        ExternalPlayer(stored: UserDefaults.standard.string(forKey: Setting.externalPlayer) ?? "")
    }

    func link(for stream: URL) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = stream.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        switch self {
        case .vlc: return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
        case .infuse: return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
        }
    }

    @MainActor func open(_ stream: URL) {
        guard let link = link(for: stream) else { return }
        Log.info("player", "handing \(Log.short(stream)) to \(name)")
        UIApplication.shared.open(link) { opened in
            if !opened { Log.warning("player", "\(name) isn't installed (or refused \(link.scheme ?? "the link"))") }
        }
    }
}

/// The server's subtitle files, or off.
struct SubtitlesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let engine: PlayerEngine

    var body: some View {
        NavigationStack {
            List {
                row("Off", selected: engine.selectedSubtitle == nil) { engine.selectSubtitle(nil) }
                ForEach(engine.subtitleTracks) { track in
                    row(track.label, selected: engine.selectedSubtitle == track) { engine.selectSubtitle(track) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(palette.onSurface)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(palette.primary) }
            }
        }
    }
}
#endif
