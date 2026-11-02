#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// A cover image, filled with AniList's dominant colour until it loads.
struct CoverImage: View {
    @Environment(\.palette) private var palette
    let media: Media

    var body: some View {
        let placeholder = Color(hex: media.coverImage?.color) ?? palette.surfaceVariant
        Color.clear
            .overlay {
                RemoteImage(url: media.coverImage?.best) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder.opacity(0.5)
                    }
                }
            }
            .clipped()
    }
}

/// Something went wrong loading a page: what, and a way to try again (Android's `ErrorNotice`).
struct ErrorState: View {
    @Environment(\.palette) private var palette
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(palette.onSurfaceVariant)
            Text(message)
                .font(AppFont.bodyMedium)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.onSurfaceVariant)
            Button {
                Task { await retry() }
            } label: {
                Text("Try again")
                    .font(AppFont.labelLarge.weight(.bold))
                    .foregroundStyle(palette.onPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(palette.primary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// A thin bar for how far into an episode the viewer got.
struct ProgressLine: View {
    @Environment(\.palette) private var palette
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(palette.primary).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}
#endif
