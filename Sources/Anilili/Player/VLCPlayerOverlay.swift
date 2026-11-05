#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftVLC

struct VLCPlayerOverlay: View {
    let player: SwiftVLC.Player
    let fullscreen: Bool
    let onBack: () -> Void
    @State private var controlsVisible = true

    private var arabic: Bool { MenuLanguage.usesArabic }
    private var isPlaying: Bool { player.state == .playing || player.state == .buffering }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() } }
            if controlsVisible {
                LinearGradient(
                    colors: [.black.opacity(0.72), .clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomControls
                }
                .transition(.opacity)
            }
        }
        .onChange(of: player.state) { _, state in
            if state == .error { controlsVisible = true }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: fullscreen ? "chevron.down" : "chevron.left")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Text("VLC")
                .font(AppFont.labelMedium.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            if player.state == .error {
                Text(arabic ? "تعذر تشغيل المصدر" : "Playback failed")
                    .font(AppFont.labelSmall)
                    .foregroundStyle(.red)
            } else if player.state == .opening || player.state == .buffering {
                ProgressView().tint(.white)
                Text(arabic ? "جاري التحميل…" : "Loading…")
                    .font(AppFont.labelSmall)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, fullscreen ? 8 : 2)
    }

    private var centerControls: some View {
        HStack(spacing: 26) {
            Button { seek(-10) } label: { Image(systemName: "gobackward.10") }
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
            }
            Button { seek(10) } label: { Image(systemName: "goforward.10") }
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
    }

    private var bottomControls: some View {
        VStack(spacing: 7) {
            ProgressView(value: min(max(player.position, 0), 1))
                .tint(.white)
            HStack(spacing: 8) {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate)x") { try? player.setPlaybackRate(Float(rate)) }
                    }
                } label: {
                    Label(arabic ? "السرعة" : "Speed", systemImage: "speedometer")
                }
                Menu {
                    Button(arabic ? "إيقاف الترجمة" : "Subtitles off") { player.selectedSubtitleTrack = nil }
                    ForEach(player.subtitleTracks) { track in
                        Button(track.name) { player.selectedSubtitleTrack = track }
                    }
                } label: {
                    Label(arabic ? "الترجمة" : "Subtitles", systemImage: "captions.bubble")
                }
                Menu {
                    ForEach(player.audioTracks) { track in
                        Button(track.name) { player.selectedAudioTrack = track }
                    }
                } label: {
                    Label(arabic ? "الصوت" : "Audio", systemImage: "waveform")
                }
                Spacer()
            }
            .font(AppFont.labelSmall)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, fullscreen ? 12 : 6)
    }

    private func togglePlay() {
        if isPlaying { player.pause() } else { try? player.play() }
    }

    private func seek(_ seconds: Double) {
        let offset = Duration.seconds(seconds)
        try? player.seek(by: offset)
    }
}
#endif
