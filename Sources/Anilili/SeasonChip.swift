#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// One season in the show page's picker (Android's `SeasonFilterRow`): its name over its year,
/// filled when it's the one listed. A season that hasn't started airing is shown faded with
/// "Upcoming" and can't be chosen, unless it's the page's own.
struct SeasonChip: View {
    @Environment(\.palette) private var palette
    let season: Media
    let label: String
    let selected: Bool
    let choosable: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label)
                    .font(AppFont.labelLarge.weight(selected ? .bold : .regular))
                    .foregroundStyle(selected ? palette.onPrimary : palette.onSurface)
                    .lineLimit(1)
                if let year = season.seasonYear ?? season.startDate?.year {
                    Text(SeasonLabels.isUpcoming(season) ? "\(String(year)) · Upcoming" : String(year))
                        .font(AppFont.labelSmall)
                        .foregroundStyle(selected ? palette.onPrimary.opacity(0.8) : palette.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? palette.primary : palette.surface, in: shape)
            .overlay(shape.strokeBorder(selected ? palette.primary : palette.outline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!choosable)
        .opacity(choosable ? 1 : 0.38)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// TheTVDB's season numbers for AniList entries, bundled as `tvdb-seasons.csv` (an extract of the
/// media index's id map, as the Android app bundles the whole map). Read once, on first use.
enum TVDBSeasons {
    static let refs: [Int: TVDBRef] = {
        guard let url = Bundle.module.url(forResource: "tvdb-seasons", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Log.warning("detail", "tvdb-seasons.csv missing from the bundle; seasons numbered from titles")
            return [:]
        }
        return TVDBRef.parse(text)
    }()

    static func ref(_ anilistID: Int) -> TVDBRef? { refs[anilistID] }
}
#endif
