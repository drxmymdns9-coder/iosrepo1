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

    private var store: DownloadStore { .shared }

    var body: some View {
        let record = store.record(mediaID: media.id, episode: episode.number, audio: audio)
        Button {
            switch record?.state {
            case nil: store.enqueue(media, episode: episode.number, audio: audio, title: episode.title, thumbnail: episode.thumbnail)
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
#endif
