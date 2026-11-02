#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Home's dice as Android's swipeable card stack (`RandomAnimeDialog`): drag right to open the
/// title, left to deal the next. The card tilts with the finger, says WATCH or SKIP before it's
/// let go, flies off past the threshold and springs home short of it; the next card waits below.
@MainActor
@Observable
final class RandomDeckModel {
    static let shared = RandomDeckModel()

    private(set) var pick: Media?
    private(set) var upNext: Media?
    private(set) var rolling = false
    private(set) var failure: String?
    /// For You, set by Home: every third card leans toward it.
    @ObservationIgnored var taste: [Media] = []

    @ObservationIgnored private let deck: RandomDeck

    /// Titles in the device's history, kept current by the deck view; read from the deck's actor.
    static let started = StartedTitles()

    private init() {
        let started = Self.started
        deck = RandomDeck(
            pageCount: AniListClient.randomPoolPages,
            // A title already started isn't a discovery.
            skip: { media in started.contains(media.id) },
            taste: { await MainActor.run { RandomDeckModel.shared.taste } },
            fetchPage: { page in try await AniListClient.shared.randomPool(page: page, hideAdult: ContentSettings.hideAdult) }
        )
    }

    func ensurePick() {
        if pick == nil || upNext == nil { roll() }
    }

    /// Deals until both the top card and the one under it are in hand, so a swipe can promote
    /// the next card in the same frame instead of waiting on the deck.
    func roll() {
        guard !rolling else { return }
        rolling = true
        failure = nil
        Task {
            do {
                while pick == nil || upNext == nil {
                    guard let card = try await deck.draw() else {
                        if pick == nil { failure = "The pool gave nothing back. Try again in a moment." }
                        break
                    }
                    // Placed after the await: a swipe meanwhile may have emptied the top.
                    if pick == nil { pick = card } else { upNext = card }
                }
            } catch {
                Log.error("random", "draw failed: \(Log.describe(error))")
                failure = error.localizedDescription
            }
            rolling = false
        }
    }

    /// Opened: a light "yes" for the taste model, and the deck moves on behind the viewer's back.
    func opened() {
        if let pick { DiceFeedback.record(pick.id, weight: Recommendations.diceOpened) }
        advance()
    }

    /// Swiped away: a light "not this".
    func skipped() {
        if let pick { DiceFeedback.record(pick.id, weight: Recommendations.diceSkipped) }
        advance()
    }

    private func advance() {
        pick = upNext
        upNext = nil
        roll()
    }
}

final class StartedTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []

    func set(_ ids: Set<Int>) {
        lock.lock()
        self.ids = ids
        lock.unlock()
    }

    func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}

/// The dice's opens and skips, which the neighbour graph's taste signals read (Android's
/// `TasteStore.recordDice`). The latest hundred.
enum DiceFeedback {
    private static let key = "ios_dice_feedback"

    static var all: [(id: Int, weight: Double)] {
        (UserDefaults.standard.array(forKey: key) as? [[Double]] ?? []).compactMap { pair in
            pair.count == 2 ? (Int(pair[0]), pair[1]) : nil
        }
    }

    static func record(_ id: Int, weight: Double) {
        var list = all.filter { $0.id != id }
        list.insert((id, weight), at: 0)
        UserDefaults.standard.set(list.prefix(100).map { [Double($0.id), $0.weight] }, forKey: key)
    }
}

struct RandomDeckView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    let onOpen: (Media) -> Void

    @State private var offset: CGSize = .zero
    @State private var grabbedTop = true
    @State private var thrown = false

    private var model: RandomDeckModel { .shared }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let threshold = width * 0.28
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { dismiss() }
                VStack(spacing: 16) {
                    HStack {
                        Text("Swipe right to watch, left for another").font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 36, height: 36).background(.white.opacity(0.15), in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                    ZStack {
                        if let pick = model.pick {
                            // One ForEach keyed by id, so the card underneath keeps its view (and its
                            // loaded cover) when it becomes the top one, rather than being rebuilt.
                            let progress = min(1, abs(offset.width) / threshold)
                            ForEach([model.upNext, pick].compactMap { $0 }) { media in
                                let isTop = media.id == pick.id
                                card(media)
                                    .overlay(alignment: .top) { if isTop { stamp(threshold: threshold) } }
                                    .scaleEffect(isTop ? 1 : 0.94 + 0.06 * progress)
                                    .opacity(isTop ? 1 : 0.85 + 0.15 * progress)
                                    .rotationEffect(.degrees(isTop ? Double(offset.width / width) * (grabbedTop ? 14 : -14) : 0),
                                                    anchor: grabbedTop ? .bottom : .top)
                                    .offset(isTop ? offset : .zero)
                                    .zIndex(isTop ? 1 : 0)
                                    .gesture(drag(width: width, threshold: threshold, pick: media), including: isTop ? .all : .none)
                                    .onTapGesture { open(media) }
                                    .allowsHitTesting(isTop)
                                    .accessibilityHidden(!isTop)
                                    .accessibilityAction(named: "Watch") { open(media) }
                                    .accessibilityAction(named: "Skip") { model.skipped() }
                            }
                        } else if model.rolling {
                            WaterFillLoader(size: 64, color: .white)
                        } else if let failure = model.failure {
                            VStack(spacing: 12) {
                                Text(failure).foregroundStyle(.white).multilineTextAlignment(.center)
                                Button("Try again") { model.roll() }.foregroundStyle(palette.primary)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(20)
            }
        }
        .presentationBackground(.clear)
        .onAppear {
            RandomDeckModel.started.set(Set(library.history.shows.keys))
            model.ensurePick()
        }
    }

    private func card(_ media: Media) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(media: media)
            LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title.preferred).font(.system(size: 24, weight: .bold)).foregroundStyle(.white).lineLimit(3)
                Text([media.averageScore.map { "\($0)%" }, media.formatLabel, media.seasonYear.map(String.init), media.episodes.map { "\($0) eps" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(AppFont.labelLarge).foregroundStyle(.white.opacity(0.85))
                if let genres = media.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · ")).font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.7))
                }
                if let description = media.description.map(HTML.plainDescription), !description.isEmpty {
                    Text(description).font(AppFont.bodySmall).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
                }
            }
            .padding(18)
        }
        .aspectRatio(0.68, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    @ViewBuilder
    private func stamp(threshold: CGFloat) -> some View {
        let progress = min(1, abs(offset.width) / threshold)
        if offset.width > 8 {
            Text("WATCH").font(.system(size: 30, weight: .black)).foregroundStyle(.green)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.green, lineWidth: 4))
                .rotationEffect(.degrees(-12)).opacity(progress).padding(.top, 30)
        } else if offset.width < -8 {
            Text("SKIP").font(.system(size: 30, weight: .black)).foregroundStyle(.red)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red, lineWidth: 4))
                .rotationEffect(.degrees(12)).opacity(progress).padding(.top, 30)
        }
    }

    private func drag(width: CGFloat, threshold: CGFloat, pick: Media) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !thrown else { return }
                if offset == .zero { grabbedTop = value.startLocation.y < width * 0.7 }
                offset = value.translation
            }
            .onEnded { value in
                guard !thrown else { return }
                let flick = value.predictedEndTranslation.width
                if value.translation.width > threshold || flick > width {
                    throwCard(direction: 1, width: width) { open(pick) }
                } else if value.translation.width < -threshold || flick < -width {
                    throwCard(direction: -1, width: width) { model.skipped() }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                }
            }
    }

    private func throwCard(direction: CGFloat, width: CGFloat, then action: @escaping () -> Void) {
        thrown = true
        withAnimation(.easeIn(duration: 0.22)) { offset = CGSize(width: direction * width * 1.6, height: offset.height + 60) }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            // The next card takes the top and the offset resets in one frame, unanimated, so the
            // thrown card never flashes back at the centre.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action()
                offset = .zero
            }
            thrown = false
        }
    }

    private func open(_ media: Media) {
        Log.info("random", "opened \(media.id) \(media.title.preferred)")
        model.opened()
        dismiss()
        onOpen(media)
    }
}
#endif
