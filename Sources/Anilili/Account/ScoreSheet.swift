#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Android's `AnimeScoreDialog`: the viewer's own score for a title, one row per point from 10
/// down to 1. Choosing a row is the write, and the sheet goes back once the account confirms.
/// Whole points only: MyAnimeList stores nothing finer, and an AniList score given in half points
/// on the website shows as it is, with no row ticked. Offered only for a title on the account,
/// since either service would otherwise make an entry to hold the score.
struct ScoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let media: Media
    /// Opened on its own (the long-press menu) rather than pushed from the list sheet, which has
    /// its own Close.
    var standalone = false

    @State private var busy: Int?
    @State private var failure: String?

    private var account: AccountStore { .shared }

    var body: some View {
        let current = account.score(of: media.id)
        let service = account.service?.label ?? "your list"
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header(current, service: service).padding(.bottom, 8)
                Text("Score this season on \(service)")
                    .font(AppFont.labelMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
                ForEach(ListScore.points, id: \.self) { score in
                    scoreRow(score, selected: current == Double(score))
                }
                if current != nil {
                    Button(role: .destructive) { rate(0, current: current) } label: {
                        HStack {
                            Label("Remove score", systemImage: "star.slash")
                            Spacer()
                            if busy == 0 { ProgressView().controlSize(.small) }
                        }
                        .font(AppFont.labelLarge)
                        .foregroundStyle(palette.error)
                        .padding(.vertical, 12)
                    }
                    .disabled(busy != nil)
                }
                if let failure {
                    Text(failure)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.error)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(Metrics.pagePadding)
        }
        .background(palette.background)
        .navigationTitle("Your score")
        .navigationBarTitleDisplayMode(.inline)
        // The score is a network write; leaving mid-flight would leave the viewer unsure it landed.
        .navigationBarBackButtonHidden(busy != nil)
        .interactiveDismissDisabled(busy != nil)
        .toolbar {
            if standalone {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.disabled(busy != nil) }
            }
        }
    }

    private func header(_ current: Double?, service: String) -> some View {
        HStack(spacing: 12) {
            CoverImage(media: media)
                .frame(width: 54, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR SCORE").font(AppFont.labelSmall.weight(.bold)).kerning(1.2).foregroundStyle(palette.primary)
                Text(media.title.preferred).font(AppFont.titleMedium).foregroundStyle(palette.onSurface).lineLimit(2)
                Text(current.map { "\(ListScore.format($0)) / 10 on \(service)" } ?? "Not scored on \(service) yet")
                    .font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
            }
        }
    }

    private func scoreRow(_ score: Int, selected: Bool) -> some View {
        Button { rate(score, current: account.score(of: media.id)) } label: {
            HStack(spacing: 12) {
                Capsule().fill(selected ? palette.primary : .clear).frame(width: 4, height: 22)
                Text("\(score)").font(AppFont.titleMedium.monospacedDigit()).foregroundStyle(palette.onSurface).frame(minWidth: 24, alignment: .leading)
                Text(ListScore.label(score) ?? "").font(AppFont.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                Spacer()
                if busy == score {
                    ProgressView().controlSize(.small)
                } else if selected {
                    Image(systemName: "checkmark").foregroundStyle(palette.primary)
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .background(selected ? palette.containerHigh : palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
    }

    private func rate(_ score: Int, current: Double?) {
        guard busy == nil, current != Double(score), !(score == 0 && current == nil) else { return }
        busy = score
        failure = nil
        Task {
            do {
                try await account.setScore(media, score)
                busy = nil
                dismiss()
            } catch {
                Log.error("account", "score \(score) for \(media.id) failed: \(Log.describe(error))")
                failure = "Couldn't save your score: \(error.localizedDescription)"
                busy = nil
            }
        }
    }
}
#endif
