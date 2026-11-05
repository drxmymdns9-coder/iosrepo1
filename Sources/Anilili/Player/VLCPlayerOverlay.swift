#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftVLC

struct VLCPlayerOverlay: View {
    let player: SwiftVLC.Player
    let fullscreen: Bool
    let onBack: () -> Void
    @State private var controlsVisible = true
    @State private var showSubtitles = false
    @State private var showTracks = false

    private var arabic: Bool { MenuLanguage.usesArabic }
    private var currentSeconds: Double {
        let c = player.currentTime.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
    private var durationSeconds: Double {
        guard let duration = player.duration else { return 0 }
        let c = duration.components
        return max(0, Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000)
    }
    private var isPlaying: Bool { player.state == .playing || player.state == .buffering }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() } }
            if controlsVisible {
                LinearGradient(
                    colors: [.black.opacity(0.72), .clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button(action: onBack) {
                            Image(systemName: fullscreen ? "chevron.down" : "chevron.left")
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                        }
                        Text("VLC")
                            .font(AppFont.labelMedium.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        if player.state == .error {
                            Text(arabic ? "تعذر تشغيل المصدر" : "Playback failed")
                                .font(AppFont.labelSmall)
                                .foregroundStyle(.red.opacity(0.95))
                        } else if player.state == .opening || player.state == .buffering {
                            ProgressView().tint(.white)
                            Text(arabic ? "جاري التحميل…" : "Loading…")
                                .font(AppFont.labelSmall)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, fullscreen ? 8 : 2)
                    Spacer()
                    HStack(spacing: 22) {
                        Button { seek(-10) } label: { Image(systemName: "gobackward.10") }
                        Button { togglePlay() } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 25, weight: .bold))
                        }
                        Button { seek(10) } label: { Image(systemName: "goforward.10") }
                    }
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    Spacer()
                    VStack(spacing: 6) {
                        Slider(value: Binding(get: { durationSeconds > 0 ? min(max(currentSeconds, 0), durationSeconds) : 0 }, set: { value in
                            try? player.seek(to: .seconds(value))
                        }), in: 0...max(durationSeconds, 1))
                        HStack {
                            Text(formatTime(currentSeconds))
                            Spacer()
                            Text(formatTime(durationSeconds))
                        }
                        .font(AppFont.labelSmall.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        HStack(spacing: 8) {
                            Menu {
                                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map(String.init), id: \.self) { value in
                                    let rate = Float(value) ?? 1
                                    Button("\(value)x") { try? player.setPlaybackRate(rate) }
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
                            if !player.videoTracks.isEmpty {
                                Menu {
                                    ForEach(player.videoTracks) { track in
                                        Text(track.name + (track.height.map { " · \($0)p" } ?? ""))
                                    }
                                } label: {
                                    Label(arabic ? "الجودة" : "Quality", systemImage: "film")
                                }
                            }
                        }
                        .font(AppFont.labelSmall)
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, fullscreen ? 12 : 6)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: player.state) { _, state in
            if state == .error { controlsVisible = true }
        }
    }

    private func togglePlay() {
        if isPlaying { player.pause() } else { try? player.play() }
    }

    private func seek(_ offset: Double) {
        try? player.seek(to: .seconds(max(0, currentSeconds + offset)))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
