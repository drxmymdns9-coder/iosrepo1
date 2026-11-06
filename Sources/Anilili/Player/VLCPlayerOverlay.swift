#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftVLC

/// Controls for the VLC path. VLC owns buffering and adaptive quality; this view owns the
/// interaction chrome so a transient buffering state cannot keep the controls permanently stuck.
struct VLCPlayerOverlay: View {
    let player: SwiftVLC.Player
    let fullscreen: Bool
    let onBack: () -> Void
    let onRetry: () -> Void

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var bufferingTask: Task<Void, Never>?
    @State private var bufferingFor: TimeInterval = 0
    @State private var isRetrying = false

    private var arabic: Bool { MenuLanguage.usesArabic }
    private var isPlaying: Bool { player.state == .playing }
    private var isBuffering: Bool { player.state == .buffering || player.state == .opening }
    private var hasFailed: Bool { player.state == .error }
    private var durationSeconds: Double {
        guard let duration = player.duration else { return 0 }
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
    private var positionSeconds: Double { player.position }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if controlsVisible {
                LinearGradient(
                    colors: [.black.opacity(0.72), .clear, .black.opacity(0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomControls
                }
                .transition(.opacity)
            }

            if isBuffering || hasFailed {
                statusCard
            }
        }
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .animation(.easeOut(duration: 0.2), value: player.state)
        .onAppear {
            scheduleHide()
            updateBufferTimer(for: player.state)
        }
        .onChange(of: player.state) { _, state in
            updateBufferTimer(for: state)
            switch state {
            case .playing:
                scheduleHide()
            case .buffering, .opening:
                // Keep the status visible briefly, then allow the video to remain unobstructed.
                scheduleHide()
            case .error, .paused, .stopped, .stopping, .idle:
                showControls(autoHide: false)
            }
        }
        .onDisappear {
            hideTask?.cancel()
            bufferingTask?.cancel()
            hideTask = nil
            bufferingTask = nil
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
            if isBuffering {
                ProgressView().tint(.white)
                Text(arabic ? "جاري التحميل…" : "Buffering…")
                    .font(AppFont.labelSmall)
                    .foregroundStyle(.white.opacity(0.85))
            } else if hasFailed {
                Text(arabic ? "توقف التشغيل" : "Playback stopped")
                    .font(AppFont.labelSmall)
                    .foregroundStyle(.red)
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
            if durationSeconds > 0 {
                ProgressView(value: min(max(positionSeconds / durationSeconds, 0), 1))
                    .tint(.white)
            } else {
                ProgressView().tint(.white.opacity(0.7))
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate)x") { try? player.setPlaybackRate(PlaybackRate(Float(rate))) }
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
                // VLC chooses the stream/variant adaptively. The package revision used by this app
                // does not expose a manual HLS variant setter, so do not present a misleading menu.
                Label(arabic ? "الجودة تلقائية" : "Auto quality", systemImage: "wand.and.stars")
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
            }
            .font(AppFont.labelSmall)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, fullscreen ? 12 : 6)
    }

    private var statusCard: some View {
        VStack(spacing: 10) {
            if isBuffering {
                ProgressView().tint(.white)
                Text(bufferingFor >= 8
                     ? (arabic ? "الاتصال بطيء أو متوقف" : "The connection appears stalled")
                     : (arabic ? "جاري تحميل الفيديو…" : "Buffering video…"))
                    .font(AppFont.labelMedium)
                    .foregroundStyle(.white)
                if bufferingFor >= 8 {
                    retryButton
                }
            } else if hasFailed {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 25))
                    .foregroundStyle(.white)
                Text(arabic ? "توقف البث بسبب الاتصال" : "The stream stopped")
                    .font(AppFont.labelMedium)
                    .foregroundStyle(.white)
                retryButton
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(true)
    }

    private var retryButton: some View {
        Button {
            guard !isRetrying else { return }
            isRetrying = true
            onRetry()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                isRetrying = false
            }
        } label: {
            Label(isRetrying ? (arabic ? "إعادة المحاولة…" : "Retrying…") : (arabic ? "إعادة المحاولة" : "Retry"),
                  systemImage: "arrow.clockwise")
                .font(AppFont.labelMedium.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRetrying)
    }

    private func togglePlay() {
        if isPlaying { player.pause() } else { try? player.play() }
        showControls(autoHide: true)
    }

    private func seek(_ seconds: Double) {
        try? player.seek(by: .seconds(seconds))
        showControls(autoHide: true)
    }

    private func showControls(autoHide: Bool) {
        hideTask?.cancel()
        controlsVisible = true
        guard autoHide else { return }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            guard player.state == .playing || player.state == .buffering || player.state == .opening else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls(autoHide: true)
        }
    }

    private func updateBufferTimer(for state: SwiftVLC.PlayerState) {
        bufferingTask?.cancel()
        bufferingFor = 0
        guard state == .buffering || state == .opening else { return }
        bufferingTask = Task { @MainActor in
            let started = Date()
            while !Task.isCancelled {
                bufferingFor = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
#endif
