#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// The Downloads tab (Android's `DownloadsScreen`): saved shows with their episode counts and
/// sizes, each opening to its episodes, which play offline.
struct DownloadsView: View {
    @Environment(\.palette) private var palette
    @State private var query = ""

    private var store: DownloadStore { .shared }

    struct SeriesRoute: Hashable { var mediaID: Int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Downloads")
                let series = store.series.filter { query.isEmpty || $0.media.title.all.joined(separator: " ").localizedCaseInsensitiveContains(query) }
                if store.records.isEmpty {
                    Text("Nothing downloaded yet. Save an episode from its show page (the arrow beside it) to keep it here.")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .padding(.horizontal, Metrics.pagePadding + 4)
                        .padding(.top, 120)
                } else {
                    Text("\(store.records.filter(\.isDone).count) episodes · \(DownloadQueue.size(store.totalBytes)) on this device")
                        .font(AppFont.labelMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .padding(.horizontal, Metrics.pagePadding)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(palette.onSurfaceVariant)
                        TextField("Search downloads", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, Metrics.pagePadding + 4)
                    .frame(height: 48)
                    LazyVStack(spacing: 10) {
                        ForEach(series) { item in
                            NavigationLink(value: SeriesRoute(mediaID: item.id)) { seriesRow(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                }
            }
            .padding(.bottom, 24)
        }
        .tucksChrome()
        .statusBarShade()
        .scrollDismissesKeyboard(.immediately)
        .background(palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: SeriesRoute.self) { DownloadSeriesView(mediaID: $0.mediaID) }
    }

    private func seriesRow(_ series: DownloadQueue.Series) -> some View {
        HStack(spacing: 14) {
            CoverImage(media: series.media)
                .frame(width: 62, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(series.media.title.preferred).font(AppFont.titleMedium).foregroundStyle(palette.onSurface).lineLimit(2)
                Text("\(series.doneCount) episode\(series.doneCount == 1 ? "" : "s") · \(DownloadQueue.size(series.bytes))")
                    .font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                if series.activeCount > 0 {
                    Text("↓ \(series.activeCount) saving").font(AppFont.labelMedium).foregroundStyle(palette.primary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(10)
        .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One show's saved episodes.
struct DownloadSeriesView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let mediaID: Int
    @State private var playing: PlayRequest?
    @State private var confirmRemoveAll = false

    private var store: DownloadStore { .shared }
    private var series: DownloadQueue.Series? { store.series.first { $0.id == mediaID } }

    var body: some View {
        ScrollView {
            if let series {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: series.media) {
                        HStack(spacing: 6) {
                            Text("\(series.episodes.count) episodes · \(DownloadQueue.size(series.bytes))")
                            Spacer()
                            Text("Show page").foregroundStyle(palette.primary)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.primary)
                        }
                        .font(AppFont.labelLarge)
                        .foregroundStyle(palette.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                    ForEach(series.episodes) { record in row(record) }
                    Button(role: .destructive) { confirmRemoveAll = true } label: {
                        Label("Remove all episodes", systemImage: "trash")
                            .font(AppFont.labelLarge)
                            .foregroundStyle(palette.error)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
            }
        }
        .background(palette.background)
        .navigationTitle(series?.media.title.preferred ?? "Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { WatchView(request: $0) }
        .confirmationDialog("Remove all episodes?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) {
                store.removeAll(mediaID: mediaID)
                dismiss()
            }
        } message: {
            Text("Every saved episode of \(series?.media.title.preferred ?? "this anime") goes from this device.")
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 120, height: 68)
                .overlay {
                    RemoteImage(url: record.thumbnail ?? record.media.heroImage) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { palette.surfaceVariant }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .bottomTrailing) { PosterTag(text: "EP \(record.episode)").padding(5) }
                .overlay {
                    if record.isDone { Image(systemName: "play.fill").foregroundStyle(.white).shadow(radius: 3) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.episodeTitle ?? "Episode \(record.episode)")
                    .font(AppFont.titleSmall).foregroundStyle(palette.onSurface).lineLimit(2)
                Text(status(record)).font(AppFont.bodySmall).foregroundStyle(statusColor(record)).lineLimit(2)
                if case .downloading(let fraction) = record.state {
                    ProgressView(value: fraction).tint(palette.primary)
                }
            }
            Spacer(minLength: 0)
            if record.state.isActive || record.state == .paused {
                let paused = record.state == .paused
                Button {
                    if paused { store.retry(record.id) } else { store.pause(record.id) }
                } label: {
                    Image(systemName: paused ? "play.circle" : "pause.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.primary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(paused ? "Resume episode \(record.episode)" : "Pause episode \(record.episode)")
            }
        }
        .padding(8)
        .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if record.isDone {
                playing = PlayRequest(media: record.media, episode: record.episode, audio: record.audio, listing: .empty)
            } else if case .failed = record.state {
                store.retry(record.id)
            } else if record.state == .paused {
                store.retry(record.id)
            }
        }
        .contextMenu {
            if case .failed = record.state {
                Button("Try again", systemImage: "arrow.clockwise") { store.retry(record.id) }
            }
            if record.state.isActive {
                Button("Pause", systemImage: "pause") { store.pause(record.id) }
            }
            if record.state == .paused {
                Button("Resume", systemImage: "play") { store.retry(record.id) }
            }
            Button(record.isDone ? "Remove download" : "Cancel", systemImage: "trash", role: .destructive) { store.remove(record.id) }
        }
    }

    private func status(_ record: DownloadRecord) -> String {
        let audio = record.audio.label
        switch record.state {
        case .done: return "\(audio) · \(DownloadQueue.size(record.bytes))" + (record.source.map { " · \($0)" } ?? "")
        case .downloading(let fraction): return "\(audio) · Saving \(Int(fraction * 100))%"
        case .queued: return "\(audio) · Waiting"
        case .paused: return "\(audio) · Paused · tap to resume"
        case .failed(let reason): return "Failed: \(reason) · tap to retry"
        }
    }

    private func statusColor(_ record: DownloadRecord) -> Color {
        if case .failed = record.state { return palette.error }
        return palette.onSurfaceVariant
    }
}
#endif
