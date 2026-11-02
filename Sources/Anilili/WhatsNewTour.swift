#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// What's new, shown once per tour id on the first open of a release (Android's `WhatsNewTour`,
/// same copy and id). Android points a spotlight at each thing on Home; here the steps are cards
/// over Home, which is behind them.
struct WhatsNewTour: View {
    /// Android's `TOUR_ID`: change it for the next release's tour.
    static let id = "home-2026-10"
    private static let seenKey = "ios_whats_new_seen"

    static var shouldShow: Bool { UserDefaults.standard.string(forKey: seenKey) != id }
    static func markSeen() { UserDefaults.standard.set(id, forKey: seenKey) }

    struct Step: Identifiable {
        var id: Int
        var systemImage: String
        var title: String
        var body: String
    }

    static let steps = [
        Step(id: 0, systemImage: "sparkles", title: "Home just got smarter", body: "A quick look at what's new — three things, under a minute."),
        Step(id: 1, systemImage: "heart.text.square", title: "For you",
             body: "Picked for you from everything you've watched. The more you watch, the better it gets. It shows up on Home once you've watched a few titles."),
        Step(id: 2, systemImage: "arrow.turn.down.right", title: "Because you watched…",
             body: "More like the last series you finished, so there's always something lined up next. It appears on Home after you finish a series."),
        Step(id: 3, systemImage: "slider.horizontal.3", title: "Make Home yours",
             body: "Arrange Home, at the bottom of Home, moves rows up or down and hides the ones you don't need."),
        Step(id: 4, systemImage: "dice", title: "Can't decide?", body: "Roll the dice for a random pick. Swipe right to watch it, left for another."),
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var page = 0

    var body: some View {
        VStack(spacing: 18) {
            TabView(selection: $page) {
                ForEach(Self.steps) { step in
                    VStack(spacing: 14) {
                        Image(systemName: step.systemImage)
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .frame(width: 84, height: 84)
                            .background(palette.primary.opacity(0.14), in: Circle())
                        Text(step.title).font(AppFont.titleLarge).foregroundStyle(palette.onSurface)
                        Text(step.body).font(AppFont.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .tag(step.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            HStack {
                Button("Skip") { finish() }.foregroundStyle(palette.onSurfaceVariant)
                Spacer()
                Button(page == Self.steps.count - 1 ? "Done" : "Next") {
                    if page == Self.steps.count - 1 { finish() } else { withAnimation { page += 1 } }
                }
                .font(AppFont.labelLarge.weight(.bold))
                .foregroundStyle(palette.onPrimary)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(palette.primary, in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .padding(.top, 24)
        .background(palette.background)
        .presentationDetents([.medium])
        // Written when it starts, so closing the app halfway doesn't bring it back (as on Android).
        .onAppear { Self.markSeen() }
    }

    private func finish() {
        Log.info("tour", "what's new \(Self.id) finished at step \(page + 1)")
        dismiss()
    }
}
#endif
