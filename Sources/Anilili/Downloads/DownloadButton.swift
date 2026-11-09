#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// An episode row's download control (Android's per-episode button): save, progress ring while
/// saving (a tap offers pause or stop), a check when saved, a warning to retry after a failure.
struct DownloadButton: View {
    @Environment(\.palette) private var palette
    let media: Media
    let episode: EpisodeInfo
    let audio: AudioTrack
    @State private var askingStop = false
    @State private var showingOptions = false

    private var store: DownloadStore { .shared }

    var body: some View {
        let record = store.record(mediaID: media.id, episode: episode.number, audio: audio)
        Button {
            switch record?.state {
            case nil: showingOptions = true
            case .failed?, .paused?: if let record { store.retry(record.id) }
            case .downloading?, .queued?: askingStop = true
            case .done?: break
            }
        } label: {
            ZStack {
                switch record?.state {
                case .downloading(let fraction)?:
                    Circle().stroke(palette.line2, lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.03, fraction)).stroke(palette.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                    Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(palette.primary)
                case .queued?:
                    Image(systemName: "clock").font(.system(size: 15)).foregroundStyle(palette.onSurfaceVariant)
                case .paused?:
                    Image(systemName: "play.circle").font(.system(size: 17)).foregroundStyle(palette.primary)
                case .done?:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(palette.primary)
                case .failed?:
                    Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 16)).foregroundStyle(palette.error)
                case nil:
                    Image(systemName: "arrow.down.circle").font(.system(size: 17)).foregroundStyle(palette.onSurfaceVariant)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(record))
        .confirmationDialog("Episode \(episode.number)", isPresented: $askingStop, titleVisibility: .visible) {
            // Asked again rather than captured: the episode may have finished while the dialog was up.
            Button("Pause") {
                if let id = store.record(mediaID: media.id, episode: episode.number, audio: audio)?.id { store.pause(id) }
            }
            Button("Stop and delete", role: .destructive) {
                if let record = store.record(mediaID: media.id, episode: episode.number, audio: audio), !record.isDone { store.remove(record.id) }
            }
        } message: {
            Text("Paused, it picks up where it stopped. Stopped, the part already fetched is discarded.")
        }
        .sheet(isPresented: $showingOptions) {
            DownloadOptionsSheet(media: media, episode: episode, audio: audio)
        }
    }

    private func label(_ record: DownloadRecord?) -> String {
        switch record?.state {
        case .downloading(let fraction)?: return "Saving episode \(episode.number), \(Int(fraction * 100)) percent; tap to pause or stop"
        case .queued?: return "Episode \(episode.number) is waiting to save; tap to pause or stop"
        case .paused?: return "Saving episode \(episode.number) is paused; tap to resume"
        case .done?: return "Episode \(episode.number) is saved on this device"
        case .failed?: return "Saving episode \(episode.number) failed; try again"
        case nil: return "Save episode \(episode.number) on this device"
        }
    }
}

/// Download choices are made before queueing so the record is deterministic even when several
/// episodes are downloaded at once.
struct DownloadOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let media: Media
    let episode: EpisodeInfo
    let audio: AudioTrack
    var preferredSource: String?
    @AppStorage(DownloadStore.qualityKey) private var quality = "best"
    @State private var sources: [VideoSource] = []
    @State private var selectedServer: String?
    @State private var selectedSubtitle = "ar"
    @State private var loading = true
    @State private var error: String?

    init(media: Media, episode: EpisodeInfo, audio: AudioTrack, preferredSource: String? = nil) {
        self.media = media; self.episode = episode; self.audio = audio; self.preferredSource = preferredSource
    }

    private var selected: VideoSource? { sources.first { $0.label == selectedServer } }
    private var subtitleChoices: [(String, String)] {
        var choices = [("ar", "العربية"), ("en", "English")]
        for track in selected?.subtitles ?? [] where !choices.contains(where: { $0.0 == track.language }) {
            choices.append((track.language, track.label))
        }
        return choices
    }

    var body: some View {
        NavigationStack {
            List {
                Section("السيرفر") {
                    if loading { ProgressView("جاري جلب السيرفرات…") }
                    else if sources.isEmpty { Text(error ?? "لا توجد مصادر قابلة للتحميل").foregroundStyle(palette.error) }
                    else {
                        ForEach(sources) { source in
                            Button { selectedServer = source.label } label: {
                                HStack { Text(source.label).foregroundStyle(palette.onSurface); Spacer(); if selectedServer == source.label { Image(systemName: "checkmark").foregroundStyle(palette.primary) } }
                            }
                        }
                    }
                }
                Section("الجودة") {
                    Picker("جودة التحميل", selection: $quality) {
                        ForEach(DownloadSettings.qualities, id: \.0) { Text($0.label).tag($0.value) }
                    }
                }
                Section("الترجمة") {
                    Picker("لغة الترجمة", selection: $selectedSubtitle) {
                        ForEach(subtitleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if selected?.softSub != true { Text("هذا المصدر قد يحتوي ترجمة مدمجة داخل الفيديو.").foregroundStyle(palette.onSurfaceVariant) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("خيارات التحميل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("تحميل") { start() }.disabled(loading || selectedServer == nil) }
            }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
        .task { await loadSources() }
        .onChange(of: selectedServer) { _, _ in if !subtitleChoices.contains(where: { $0.0 == selectedSubtitle }) { selectedSubtitle = "ar" } }
    }

    private func loadSources() async {
        do {
            let found = try await SourceHub.shared.sources(for: media, episode: episode.number, audio: audio)
            sources = found.filter { $0.kind != .embed }
            selectedServer = preferredSource.flatMap { value in sources.first { $0.label == value }?.label } ?? sources.first?.label
        } catch { error = error.localizedDescription }
        loading = false
    }

    private func start() {
        DownloadStore.shared.enqueue(media, episode: episode.number, audio: audio, title: episode.title,
                                     thumbnail: episode.thumbnail, from: selectedServer,
                                     subtitleLanguage: selectedSubtitle)
        dismiss()
    }
}

/// Batch choices are based on the intersection of sources resolved for every episode, so one
/// selected server can be used consistently for the whole season.
struct BatchDownloadOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let media: Media
    let episodes: [EpisodeInfo]
    let audio: AudioTrack
    @AppStorage(DownloadStore.qualityKey) private var quality = "best"
    @State private var sourceSets: [[VideoSource]] = []
    @State private var selectedServer: String?
    @State private var selectedSubtitle = "ar"
    @State private var loading = true
    @State private var error: String?

    private var commonServers: [String] {
        guard let first = sourceSets.first else { return [] }
        let initial = Set(first.map(\.label))
        return sourceSets.dropFirst().reduce(initial) { partial, sources in partial.intersection(Set(sources.map(\.label))) }.sorted()
    }

    private var subtitleChoices: [(String, String)] {
        let perEpisode = sourceSets.compactMap { set in
            guard let server = selectedServer, let source = set.first(where: { $0.label == server }) else { return nil }
            return Set(source.subtitles.map { $0.language.lowercased() })
        }
        let common = perEpisode.dropFirst().reduce(perEpisode.first ?? []) { $0.intersection($1) }
        var result: [(String, String)] = []
        if common.contains(where: { $0.hasPrefix("ar") }) { result.append(("ar", "العربية")) }
        if common.contains(where: { $0.hasPrefix("en") }) { result.append(("en", "English")) }
        return result.isEmpty ? [("ar", "العربية")] : result
    }

    var body: some View {
        NavigationStack {
            List {
                Section("السيرفر المشترك") {
                    if loading { ProgressView("جاري فحص جميع الحلقات…") }
                    else if commonServers.isEmpty { Text(error ?? "لا يوجد سيرفر مشترك قابل للتحميل في جميع الحلقات").foregroundStyle(palette.error) }
                    else {
                        ForEach(commonServers, id: \.self) { server in
                            Button { selectedServer = server } label: {
                                HStack { Text(server).foregroundStyle(palette.onSurface); Spacer(); if selectedServer == server { Image(systemName: "checkmark").foregroundStyle(palette.primary) } }
                            }
                        }
                    }
                }
                Section("الجودة") {
                    Picker("جودة التحميل", selection: $quality) {
                        ForEach(DownloadSettings.qualities, id: \.0) { Text($0.label).tag($0.value) }
                    }
                }
                Section("الترجمة المشتركة") {
                    Picker("لغة الترجمة", selection: $selectedSubtitle) {
                        ForEach(subtitleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                if !loading && !commonServers.isEmpty {
                    Section { Text("سيتم تنزيل \(episodes.count) حلقة من السيرفر المحدد فقط.").foregroundStyle(palette.onSurfaceVariant) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("تحميل الكل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("تحميل") { start() }.disabled(loading || selectedServer == nil) }
            }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
        .task { await loadSources() }
        .onChange(of: selectedServer) { _, _ in if !subtitleChoices.contains(where: { $0.0 == selectedSubtitle }) { selectedSubtitle = subtitleChoices.first?.0 ?? "ar" } }
    }

    private func loadSources() async {
        var found: [[VideoSource]] = []
        for episode in episodes {
            do {
                let sources = try await SourceHub.shared.sources(for: media, episode: episode.number, audio: audio)
                found.append(sources.filter { $0.kind != .embed })
            } catch {
                self.error = error.localizedDescription
                found.append([])
            }
        }
        sourceSets = found
        selectedServer = commonServers.first
        loading = false
    }

    private func start() {
        for episode in episodes {
            DownloadStore.shared.enqueue(media, episode: episode.number, audio: audio, title: episode.title,
                                         thumbnail: episode.thumbnail, from: selectedServer,
                                         subtitleLanguage: selectedSubtitle)
        }
        dismiss()
    }
}

#endif
