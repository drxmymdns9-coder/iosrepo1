#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Settings → Downloads (Android's section): the resolution to save at and the space downloads
/// take. Android's "Where downloads go" and "Save location" pick a folder on the phone; an iPhone
/// keeps an app's files to itself, so episodes stay in the app's library.
struct DownloadSettings: View {
    @AppStorage(DownloadStore.qualityKey) private var quality = "best"
    @State private var confirmRemove = false

    /// Android's `DownloadQuality`.
    static let qualities: [(value: String, label: String)] = [
        ("best", "Best available"), ("1080", "1080p"), ("720", "720p"), ("480", "480p"), ("360", "360p"),
    ]

    private var store: DownloadStore { .shared }

    var body: some View {
        ChoiceRow(title: "Download resolution", detail: "Limits the rendition saved for offline playback",
                  options: Self.qualities.map(\.value),
                  label: { value in Self.qualities.first { $0.value == value }?.label ?? value },
                  selection: $quality,
                  kicker: "Downloads",
                  explanation: "Limits the saved HLS rendition; direct video files keep their source resolution.")
        InfoRow(title: "Space used", detail: "\(store.records.filter(\.isDone).count) saved episodes", value: DownloadQueue.size(store.totalBytes))
        ActionRow(title: "Remove all downloads", detail: "Frees the space; the episodes stay on your lists", destructive: true,
                  disabled: store.records.isEmpty, chevron: false) { confirmRemove = true }
            .confirmationDialog("Remove every download?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove all", role: .destructive) { store.removeAll() }
            }
        SettingsNotice(text: "Episodes save two at a time while Anilili is open, into the app's own library; one that's interrupted carries on next time. Subbed episodes are always saved with hard subs, burned into the picture, so only hard-sub servers are used.")
    }
}
#endif
