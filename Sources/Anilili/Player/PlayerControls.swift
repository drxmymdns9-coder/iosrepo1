#if canImport(UIKit)
import AVFoundation
import AnililiCore
import MediaPlayer
import SwiftUI
import UIKit

/// Android's player chrome over the picture (`PlayerControlsScaffold`), its gestures
/// (`PlayerGestureControls`), the skip button and auto-skip countdown, the Up Next card, the screen
/// lock, the subtitle layer and the loading and failure states.
struct PlayerOverlay: View {
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("player_clock") private var showClock = true
    @AppStorage("player_gestures") private var gestures = true
    @AppStorage("player_seek_gesture") private var seekGesture = true
    @AppStorage("hold_to_speed_enabled") private var holdToSpeed = true
    @AppStorage("hold_playback_speed") private var holdSpeed = 2.0
    @AppStorage(Setting.showSkipButton) private var showSkipButton = true
    @AppStorage(Setting.showPlayerDebug) private var showDebug = false
    @AppStorage(Setting.pauseDetailsOverlay) private var pauseDetails = true
    let engine: PlayerEngine
    let seriesTitle: String
    let episodeTitle: String
    let fullscreen: Bool
    /// Whether the back button leaves fullscreen (a chevron down) rather than closing the player.
    var backLeavesFullscreen: Bool = false
    /// False where the player is always fullscreen (the TV layout), which drops the toggle.
    var canToggleFullscreen: Bool = true
    let pictureInPicture: PictureInPictureHandle
    let onBack: () -> Void
    let onToggleFullscreen: () -> Void
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    let onSettings: () -> Void
    let onSources: () -> Void
    let onSubtitles: () -> Void
    let onEpisodes: (() -> Void)?
    let onRetry: () -> Void
    var logo: URL?
    var synopsis: String?
    /// Told when the controls come and go, for the status bar that shows with them.
    var onControlsVisible: ((Bool) -> Void)?

    @State private var controlsVisible = true
    @State private var pausedLong = false
    @State private var pauseTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var locked = false
    @State private var scrub: Double?
    @State private var flash: String?
    @State private var flashTask: Task<Void, Never>?
    @State private var holding = false
    @State private var pressing = false
    @State private var dragKind: DragKind?
    @State private var startValue: Double = 0
    /// The brightness or volume level being dragged, shown beside the picture.
    @State private var level: GestureLevel?
    @State private var levelTask: Task<Void, Never>?
    /// True while a drag is in progress. A `GestureState` resets itself when the system cancels the
    /// drag (swiping home, Picture in Picture), which `onEnded` never hears about: that's how the
    /// level used to stay stuck in the middle of the picture.
    @GestureState private var dragging = false

    /// `ignored` is a vertical drag that began in a system-gesture strip, which claims nothing.
    enum DragKind { case seek, brightness, volume, ignored }

    enum GestureLevel: Equatable {
        case brightness(Double)
        case volume(Double)

        var fraction: Double {
            switch self {
            case .brightness(let value), .volume(let value): value
            }
        }

        var isBrightness: Bool {
            if case .brightness = self { return true }
            return false
        }
    }

    /// The strips along the top and bottom edges a swipe is pulled from to reach the system: the
    /// home indicator, Control Center and the notifications. Android keeps a strip clear for its
    /// shade; here a swipe up to go home kept turning the volume up. Vertical drags starting in them
    /// change neither brightness nor volume; taps and the sideways seek are untouched.
    static let systemGestureStrip: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                gestureLayer(size: proxy.size)
                if pauseDetails, pausedLong, !controlsVisible, !locked, engine.phase == .ready {
                    PauseOverlay(seriesTitle: seriesTitle, episodeTitle: episodeTitle, provider: engine.current?.provider ?? "",
                                 synopsis: synopsis ?? "", logo: logo, fullscreen: fullscreen)
                        .transition(.opacity)
                }
                if let text = engine.subtitleText {
                    SubtitleLayer(text: text, raised: controlsVisible && !locked, fullscreen: fullscreen)
                }
                stateLayer
                if locked {
                    lockedLayer
                } else if controlsVisible {
                    controls
                        .transition(.opacity)
                }
                if !locked { floatingActions }
                if let level {
                    LevelIndicator(level: level)
                        .padding(.horizontal, fullscreen ? 36 : 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: level.isBrightness ? .trailing : .leading)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let flash {
                    Text(flash)
                        .font(AppFont.titleSmall.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if showDebug { debugPanel }
            }
            .animation(.easeOut(duration: 0.2), value: controlsVisible)
            .animation(.easeOut(duration: 0.2), value: flash)
            .animation(.easeOut(duration: 0.2), value: level == nil)
            .animation(.easeOut(duration: 0.4), value: pausedLong)
        }
        .onAppear { scheduleHide() }
        .onDisappear {
            finishDrag(commit: false)
            SystemVolume.release(after: .zero)
        }
        .onChange(of: dragging) { _, active in
            if !active { finishDrag(commit: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving for the home screen or Picture in Picture cancels a drag mid-way; nothing of
            // it may be left on screen for the way back.
            if phase != .active { finishDrag(commit: false) }
        }
        .onChange(of: engine.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls(autoHide: false) }
        }
        .onChange(of: controlsVisible) { _, visible in onControlsVisible?(visible) }
        .onChange(of: engine.pausedSince) { _, since in
            pauseTask?.cancel()
            pausedLong = false
            guard since != nil else { return }
            pauseTask = Task {
                try? await Task.sleep(for: PauseOverlay.delay)
                if !Task.isCancelled, engine.pausedSince != nil { pausedLong = true }
            }
        }
    }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                guard !locked, gestures else { return }
                let forward = point.x > size.width / 2
                engine.seek(by: forward ? 10 : -10)
                showFlash(forward ? "+10s" : "−10s")
            }
            .onTapGesture {
                if locked { showFlash("Locked") } else if controlsVisible { controlsVisible = false } else { showControls(autoHide: true) }
            }
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 30) {
            } onPressingChanged: { isPressing in
                pressing = isPressing
                guard !locked, holdToSpeed, engine.isPlaying || holding else { return }
                if isPressing {
                    // onPressingChanged fires on touch-down; wait for a real hold before speeding up,
                    // and only if the finger is still down by then.
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard pressing, !holding, dragKind == nil else { return }
                        holding = true
                        engine.holdSpeed(Float(holdSpeed))
                        flash = "\(Self.speedLabel(Float(holdSpeed))) ▶▶"
                    }
                } else if holding {
                    holding = false
                    engine.holdSpeed(nil)
                    flash = nil
                }
            }
            .gesture(dragGesture(size: size))
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in
                guard !locked, gestures else { return }
                if dragKind == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    let y = value.startLocation.y
                    let inSystemStrip = y < Self.systemGestureStrip || y > size.height - Self.systemGestureStrip
                    if horizontal {
                        guard seekGesture else { return }
                        dragKind = .seek
                        startValue = engine.position
                    } else if inSystemStrip {
                        dragKind = .ignored
                    } else if value.startLocation.x < size.width / 2 {
                        dragKind = .brightness
                        startValue = Double(UIScreen.main.brightness)
                    } else {
                        dragKind = .volume
                        startValue = Double(SystemVolume.current)
                        SystemVolume.prepare()
                    }
                }
                switch dragKind {
                case .seek:
                    let span = max(90, min(engine.duration, 600))
                    let target = min(max(0, startValue + Double(value.translation.width / size.width) * span), engine.duration)
                    scrub = target
                    flash = "\(PlayerEngine.clock(target)) / \(PlayerEngine.clock(engine.duration))"
                case .brightness:
                    let next = min(max(0, startValue - Double(value.translation.height / (size.height * 0.8))), 1)
                    UIScreen.main.brightness = CGFloat(next)
                    showLevel(.brightness(next))
                case .volume:
                    let next = min(max(0, startValue - Double(value.translation.height / (size.height * 0.8))), 1)
                    SystemVolume.set(Float(next))
                    showLevel(.volume(next))
                case .ignored, nil:
                    break
                }
            }
    }

    /// Shows a level and keeps it up while it keeps changing; it goes by itself a moment after the
    /// last change, whatever became of the drag.
    private func showLevel(_ value: GestureLevel) {
        level = value
        levelTask?.cancel()
        levelTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { level = nil }
        }
    }

    /// The end of a drag, whether the finger lifted (`commit`: a seek lands) or the system took it.
    private func finishDrag(commit: Bool) {
        if commit, dragKind == .seek, let scrub { engine.seek(to: scrub, why: "drag") }
        if dragKind == .volume || !commit { SystemVolume.release() }
        dragKind = nil
        scrub = nil
        levelTask?.cancel()
        levelTask = Task {
            if commit { try? await Task.sleep(for: .milliseconds(600)) }
            if !Task.isCancelled { level = nil }
        }
        flashTask?.cancel()
        if commit {
            flashTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { flash = nil }
            }
        } else {
            flash = nil
            if holding {
                holding = false
                engine.holdSpeed(nil)
            }
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: fullscreen ? 132 : 84)
                Spacer()
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.68), location: 0.32), .init(color: .black.opacity(0.94), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: fullscreen ? 150 : 110)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                // Until a stream is playing, the middle belongs to the loader or the failure (the
                // state layer): a play button over the logo reads as a second, broken control.
                if engine.phase == .ready {
                    transport
                    Spacer()
                }
                bottomBar
            }
            .padding(.horizontal, fullscreen ? 28 : 12)
            .padding(.vertical, fullscreen ? 12 : 6)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onBack) {
                Image(systemName: backLeavesFullscreen ? "chevron.down" : "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(backLeavesFullscreen ? "Leave fullscreen" : "Close player")
            if fullscreen {
                VStack(alignment: .leading, spacing: 2) {
                    Text(seriesTitle).font(AppFont.titleSmall).lineLimit(1)
                    Text(episodeTitle).font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                .padding(.top, 4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if showClock && fullscreen {
                    PlayerClock(position: scrub ?? engine.position, duration: engine.duration, speed: engine.speed)
                }
                HStack(spacing: 4) {
                    if pictureInPicture.isPossible {
                        iconButton("pip.enter", label: "Picture in Picture") { pictureInPicture.toggle() }
                    }
                    AirPlayButton().frame(width: 36, height: 36)
                    iconButton("lock", label: "Lock the screen") {
                        locked = true
                        controlsVisible = false
                    }
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: fullscreen ? 44 : 26) {
            iconButton("backward.end.fill", label: "Previous episode", size: 22) { onPrevious?() }
                .opacity(onPrevious == nil ? 0.35 : 1)
                .disabled(onPrevious == nil)
            iconButton("gobackward.10", label: "Rewind 10 seconds", size: 24) {
                engine.seek(by: -10)
                showControls(autoHide: true)
            }
            Button {
                engine.togglePlay()
                showControls(autoHide: true)
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: fullscreen ? 30 : 24, weight: .bold))
                    .frame(width: fullscreen ? 72 : 58, height: fullscreen ? 72 : 58)
                    .background(palette.playerAccent.opacity(0.24), in: Circle())
                    .overlay(Circle().strokeBorder(palette.playerAccent, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            iconButton("goforward.10", label: "Forward 10 seconds", size: 24) {
                engine.seek(by: 10)
                showControls(autoHide: true)
            }
            iconButton("forward.end.fill", label: "Next episode", size: 22) { onNext?() }
                .opacity(onNext == nil ? 0.35 : 1)
                .disabled(onNext == nil)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if engine.phase == .ready { seekRow }
            HStack(spacing: 2) {
                if let onEpisodes {
                    iconButton("list.bullet.rectangle", label: "Episodes") { onEpisodes() }
                }
                Spacer(minLength: 8)
                // See skipRidesBar. The first that fits the gap: the countdown keeps its Cancel
                // for as long as there is room for one.
                if skipRidesBar, let offer = shownSkipOffer {
                    ViewThatFits(in: .horizontal) {
                        skipButton(offer)
                        skipButton(offer, compact: true)
                        skipButton(offer, compact: true, showsCancel: false)
                    }
                    .layoutPriority(1)
                    .padding(.trailing, 6)
                }
                // Keep this visible even for hard-sub or downloaded videos with no sidecar track:
                // the subtitle sheet is also where the viewer imports an SRT/VTT/ASS file.
                iconButton(engine.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill", label: "Subtitles") { onSubtitles() }
                iconButton("server.rack", label: "Servers") { onSources() }
                if canToggleFullscreen {
                    iconButton(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: fullscreen ? "Exit fullscreen" : "Fullscreen") { onToggleFullscreen() }
                }
                iconButton("gearshape.fill", label: "Player settings") { onSettings() }
            }
        }
    }

    /// The seek bar and the times either side of it, once there's a stream to seek in.
    private var seekRow: some View {
        VStack(spacing: 4) {
            SeekBar(
                position: scrub ?? engine.position,
                duration: engine.duration,
                buffered: engine.buffered,
                skip: engine.skipTimes,
                accent: palette.playerAccent,
                onScrub: { value in
                    scrub = value
                    showControls(autoHide: false)
                },
                onCommit: { value in
                    engine.seek(to: value, why: "seek bar")
                    scrub = nil
                    showControls(autoHide: true)
                }
            )
            HStack {
                Text(PlayerEngine.clock(scrub ?? engine.position)).font(AppFont.labelMedium.monospacedDigit())
                Spacer()
                Text("-" + PlayerEngine.clock(max(0, engine.duration - (scrub ?? engine.position))))
                    .font(AppFont.labelMedium.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }

    /// The skip offer on screen, if any: none while the Up Next card has the corner. The skip
    /// button setting is the timing-less "+85s" only: it used to hide Skip Intro and Skip Outro too.
    private var shownSkipOffer: PlayerEngine.SkipOffer? {
        if engine.nextCountdown != nil, onNext != nil { return nil }
        guard let offer = engine.skipOffer else { return nil }
        let shown = offer.isWindow
            ? (offer.floats || engine.autoSkipCountdown != nil || controlsVisible)
            : (showSkipButton && controlsVisible)
        return shown ? offer : nil
    }

    /// Whether the skip button sits in the bottom bar's row instead of floating above the bar.
    ///
    /// The inline player is 211-247pt tall on an iPhone, and the top bar, the transport and the
    /// two-line bottom bar leave no band between the transport and the seek bar for a button to
    /// float in: at 96pt up it covered "Next episode" on every iPhone (reported from Android, where
    /// the same layout did the same). The bottom row has a gap between Episodes and the icons on the
    /// right that is wide enough for it, and taller than the button, so nothing moves to make room.
    /// Fullscreen has the height to float it, and with the controls hidden there is nothing to cover.
    private var skipRidesBar: Bool { !fullscreen && controlsVisible }

    private func skipButton(_ offer: PlayerEngine.SkipOffer, compact: Bool = false, showsCancel: Bool = true) -> some View {
        SkipButton(offer: offer, countdown: engine.autoSkipCountdown, compact: compact, showsCancel: showsCancel) {
            engine.takeSkip()
        } onCancel: {
            engine.cancelAutoSkip()
        }
    }

    /// The skip button (or its auto-skip countdown) and the Up Next card, which ride above the
    /// controls whether or not they're showing; the skip button moves into the bar inline (see
    /// skipRidesBar).
    private var floatingActions: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Spacer()
            if let countdown = engine.nextCountdown, let onNext {
                UpNextCard(seconds: countdown, label: "Episode \((engineNext ?? 0))", onPlay: { onNext() }, onStay: { engine.refuseNext() })
            } else if !skipRidesBar, let offer = shownSkipOffer {
                skipButton(offer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, fullscreen ? 32 : 14)
        .padding(.bottom, controlsVisible ? (fullscreen ? 128 : 96) : (fullscreen ? 36 : 18))
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
    }

    private var engineNext: Int? { engine.request?.nextEpisode }

    @ViewBuilder
    private var stateLayer: some View {
        switch engine.phase {
        case .resolving, .loading:
            VStack(spacing: 14) {
                WaterFillLoader(size: fullscreen ? 72 : 56, color: .white)
                Text(engine.status).font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.8))
            }
            .allowsHitTesting(false)
        case .failed(let message):
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.yellow)
                    Text(message).font(AppFont.bodyMedium).multilineTextAlignment(.center).foregroundStyle(.white)
                    ForEach(engine.attempts) { attempt in
                        Text("• \(attempt.source.label): \(attempt.outcome)")
                            .font(AppFont.labelSmall.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Try again", action: onRetry)
                        .font(AppFont.labelLarge.weight(.bold))
                        .foregroundStyle(palette.onPlayerAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(palette.playerAccent, in: Capsule())
                    Text("Settings → App → Debug log has the full story.").font(AppFont.labelSmall).foregroundStyle(.white.opacity(0.6))
                }
                .padding(24)
            }
        case .ready:
            if engine.isBuffering {
                ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
            }
        }
    }

    private var lockedLayer: some View {
        VStack {
            Spacer()
            Button {
                locked = false
                showControls(autoHide: true)
            } label: {
                Label("Unlock", systemImage: "lock.open.fill")
                    .font(AppFont.labelLarge.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .padding(.bottom, fullscreen ? 40 : 16)
        }
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(engine.current.map { "\($0.label) [\($0.kind.rawValue)]" } ?? "no source")
            Text(engine.status)
            Text("t=\(String(format: "%.1f", engine.position)) buf=\(String(format: "%.1f", engine.buffered)) dur=\(String(format: "%.0f", engine.duration))")
            if let line = engine.lastEvent { Text(line).lineLimit(3) }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.green)
        .padding(6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 50)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func iconButton(_ name: String, label: String, size: CGFloat = 19, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func showControls(autoHide: Bool) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, engine.isPlaying, scrub == nil else { return }
            controlsVisible = false
        }
    }

    private func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { flash = nil }
        }
    }

    static func speedLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%.2gx", rate)
    }
}

/// Played, buffered and remaining bands with the intro and outro marked, draggable.
struct SeekBar: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let skip: SkipTimes?
    let accent: Color
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let played = duration > 0 ? min(1, position / duration) : 0
            let loaded = duration > 0 ? min(1, max(buffered, position) / duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.30)).frame(height: dragging ? 6 : 4)
                Capsule().fill(.white.opacity(0.50)).frame(width: width * loaded, height: dragging ? 6 : 4)
                ForEach(markers, id: \.self) { range in
                    Rectangle()
                        .fill(Color.yellow.opacity(0.85))
                        .frame(width: max(2, width * (range.upperBound - range.lowerBound)), height: dragging ? 6 : 4)
                        .offset(x: width * range.lowerBound)
                }
                Capsule().fill(accent).frame(width: width * played, height: dragging ? 6 : 4)
                Circle().fill(accent)
                    .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: width * played - (dragging ? 9 : 6))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragging = true
                        onScrub(min(max(0, value.location.x / width), 1) * duration)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        dragging = false
                        onCommit(min(max(0, value.location.x / width), 1) * duration)
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue("\(PlayerEngine.clock(position)) of \(PlayerEngine.clock(duration))")
        .accessibilityAdjustableAction { direction in
            onCommit(direction == .increment ? min(duration, position + 10) : max(0, position - 10))
        }
    }

    /// The intro and a credits outro as fractions of the file (Android's `PlayerSeekMarkers`).
    private var markers: [ClosedRange<Double>] {
        guard duration > 0, let skip else { return [] }
        var ranges: [ClosedRange<Double>] = []
        if let intro = skip.intro { ranges.append(max(0, intro.start / duration)...min(1, intro.end / duration)) }
        if let outro = skip.outro, PlaybackPolicy.outroIsCredits(outro, duration: duration) {
            ranges.append(max(0, outro.start / duration)...min(1, outro.end / duration))
        }
        return ranges
    }
}

/// "Skip Intro", with the auto-skip countdown sweeping across it (Android's `AutoSkipCountdown`).
private struct SkipButton: View {
    let offer: PlayerEngine.SkipOffer
    let countdown: Int?
    /// Smaller, with a shorter countdown and an icon for Cancel, for the inline player's bottom row
    /// on a phone too narrow for the full one.
    var compact = false
    /// Off only where even the compact pair does not fit; seeking out of the window still calls the
    /// auto-skip off.
    var showsCancel = true
    let onSkip: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            Button(action: onSkip) {
                HStack(spacing: compact ? 4 : 6) {
                    Image(systemName: "forward.fill")
                    Text(title)
                }
                .font((compact ? AppFont.labelMedium : AppFont.labelLarge).weight(.bold))
                .lineLimit(1)
                .foregroundStyle(.black)
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.vertical, compact ? 8 : 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            if countdown != nil, showsCancel {
                if compact {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(AppFont.labelLarge.weight(.bold))
                            .frame(width: 30, height: 32)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Cancel")
                } else {
                    Button("Cancel", action: onCancel)
                        .font(AppFont.labelLarge.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var title: String {
        guard let countdown else { return offer.label }
        if compact { return "Skip in \(countdown)s" }
        return "Skipping \(offer.label.replacingOccurrences(of: "Skip ", with: "").lowercased()) · \(countdown)s"
    }
}

/// The episode's billing over a darkened frame once a pause has held for a while and the controls
/// have gone (Android's `PlayerPauseOverlay`). It waits 15 s: shorter pauses are about the picture
/// (a subtitle to re-read, a frame), and the panel would cover exactly that.
private struct PauseOverlay: View {
    static let delay: Duration = .seconds(15)

    let seriesTitle: String
    let episodeTitle: String
    let provider: String
    let synopsis: String
    let logo: URL?
    let fullscreen: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0),
                                   .init(color: .black.opacity(0.40), location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: fullscreen ? 8 : 4) {
                Group {
                    if let logo {
                        RemoteImage(url: logo) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                title
                            }
                        }
                        .frame(maxWidth: fullscreen ? 360 : 200, maxHeight: fullscreen ? 96 : 48, alignment: .leading)
                    } else {
                        title
                    }
                }
                .padding(.bottom, 4)
                if !episodeTitle.isEmpty {
                    Text(episodeTitle).font(AppFont.bodyMedium).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
                if !provider.isEmpty {
                    Text(provider).font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
                if !synopsis.isEmpty {
                    Text(synopsis).font(AppFont.bodySmall).foregroundStyle(.white.opacity(0.78)).lineLimit(fullscreen ? 4 : 2)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.leading, fullscreen ? 28 : 16)
            .padding(.trailing, 24)
        }
        .allowsHitTesting(false)
    }

    private var title: some View {
        Text(seriesTitle)
            .font(fullscreen ? Font.system(size: 24, weight: .bold) : AppFont.titleMedium.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(2)
    }
}

/// "Up next", with Play now (counting down) and Stay (Android's `NextEpisodeCard`).
private struct UpNextCard: View {
    let seconds: Int
    let label: String
    let onPlay: () -> Void
    let onStay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up next").font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.62))
            Text(label).font(AppFont.titleSmall).foregroundStyle(.white).lineLimit(2)
            HStack(spacing: 10) {
                Button(seconds > 0 ? "Play now · \(seconds)s" : "Play now", action: onPlay)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Stay", action: onStay)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .font(AppFont.labelLarge.weight(.semibold))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}

/// The clock and finishing time ("21:04 · ends 21:28"), Android's `PlayerClock`.
private struct PlayerClock: View {
    let position: Double
    let duration: Double
    let speed: Float

    var body: some View {
        let twentyFourHour = AppearanceStore.shared.uses24Hour()
        let remaining = max(0, duration - position) / Double(max(speed, 0.1))
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = AirTime.format(context.date, twentyFourHour: twentyFourHour)
            let ends = AirTime.format(context.date.addingTimeInterval(remaining), twentyFourHour: twentyFourHour)
            Text(duration > 0 ? "\(now) · ends \(ends)" : now)
                .font(AppFont.labelMedium.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// The soft subtitles, drawn over the picture (AVPlayer can't load them into HLS).
private struct SubtitleLayer: View {
    @AppStorage(CaptionKey.position) private var position = "bottom"
    @AppStorage(CaptionKey.margin) private var margin = 12
    @AppStorage(CaptionKey.horizontalAnchor) private var anchor = 50
    let text: String
    let raised: Bool
    let fullscreen: Bool

    var body: some View {
        GeometryReader { proxy in
            // Android's edge margin is a share of the picture's height; raised clears the controls.
            let gap = max(CGFloat(margin) / 100 * proxy.size.height, raised ? (fullscreen ? 120 : 84) : 0)
            VStack {
                if position != "top" { Spacer() }
                // Android's horizontal anchor: 0 against the left edge, 50 centred, 100 the right.
                let room = proxy.size.width - 48
                CaptionText(text: text, baseSize: fullscreen ? 21 : 16)
                    .alignmentGuide(.leading) { caption in -max(0, room - caption.width) * CGFloat(min(max(anchor, 0), 100)) / 100 }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(position == "top" ? .top : .bottom, gap)
                if position == "top" { Spacer() }
            }
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: raised)
    }
}

/// The brightness or volume card beside the picture while it's dragged (Android's
/// `GestureLevelIndicator`): on the side away from the finger, a fixed width so a changing number
/// doesn't shake it, and a bar that fills from the bottom.
private struct LevelIndicator: View {
    let level: PlayerOverlay.GestureLevel

    var body: some View {
        let percent = Int((min(1, max(0, level.fraction)) * 100).rounded())
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(height: 26)
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(height: 120 * CGFloat(percent) / 100)
            }
            .frame(width: 6, height: 120)
            Text("\(percent)%")
                .font(AppFont.labelMedium.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.vertical, 16)
        .frame(width: 72)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.isBrightness ? "Brightness" : "Volume")
        .accessibilityValue("\(percent) percent")
    }

    private var symbol: String {
        switch level {
        case .brightness: "sun.max.fill"
        case .volume(let value): value <= 0.001 ? "speaker.slash.fill" : value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        }
    }
}

/// The system volume, through the long-standing hidden `MPVolumeView` slider: iOS has no public
/// setter for the output volume.
///
/// The view is in the window only while a volume drag needs it. Any `MPVolumeView` on screen tells
/// iOS the app draws its own volume control, which hides the system's indicator for the buttons on
/// the side; left in place for good, as it was, pressing them showed nothing at all.
@MainActor
enum SystemVolume {
    private static var view: MPVolumeView?
    private static var releaseTask: Task<Void, Never>?

    static var current: Float { AVAudioSession.sharedInstance().outputVolume }

    /// Puts the hidden view in the window ahead of the first change: a slider set in the same
    /// moment its view arrives can drop the value.
    static func prepare() {
        releaseTask?.cancel()
        _ = mounted()
    }

    static func set(_ value: Float) {
        releaseTask?.cancel()
        mounted().subviews.compactMap { $0 as? UISlider }.first?.value = value
    }

    /// Takes the hidden view out again once a drag is over, which brings the buttons' own
    /// indicator back.
    static func release(after delay: Duration = .seconds(1)) {
        releaseTask?.cancel()
        releaseTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            view?.removeFromSuperview()
            view = nil
        }
    }

    private static func mounted() -> MPVolumeView {
        if let view, view.window != nil { return view }
        view?.removeFromSuperview()
        let fresh = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 10, height: 10))
        fresh.alpha = 0.01
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(fresh)
        view = fresh
        return fresh
    }
}
#endif
