#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Android's `AnimeListStatusDialog`: the five list destinations on the signed-in service, with
/// one accent rail on the current one, plus the title's custom lists and taking it off the list.
/// Signed out, it says where to sign in and still offers the device watchlist.
struct ListStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    let media: Media

    @State private var busy: ListStatus?
    @State private var working = false
    @State private var failure: String?
    @State private var newList = ""
    @State private var confirmRemove = false

    private var account: AccountStore { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header.padding(.bottom, 8)
                    if let service = account.service {
                        Text("Syncing with \(service.label)")
                            .font(AppFont.labelMedium)
                            .foregroundStyle(palette.onSurfaceVariant)
                        ForEach(ListStatus.pickerOptions, id: \.status) { option in
                            statusRow(option.status, label: option.label)
                        }
                        if account.statuses[media.id] == .repeating {
                            statusRow(.repeating, label: "Rewatching")
                        }
                        scoreRow(service)
                        if let total = media.releasedEpisodes, total > 0 {
                            Button { markAllWatched(total) } label: {
                                Label("Mark every episode watched", systemImage: "eye")
                                    .font(AppFont.labelLarge)
                                    .foregroundStyle(palette.onSurface)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                            }
                            .disabled(working || busy != nil)
                        }
                        customLists(service)
                        if account.statuses[media.id] != nil || !account.customLists(of: media.id).isEmpty {
                            Button(role: .destructive) { confirmRemove = true } label: {
                                Label("Remove from \(service.label)", systemImage: "trash")
                                    .font(AppFont.labelLarge)
                                    .foregroundStyle(palette.error)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                            }
                            .disabled(working || busy != nil)
                        }
                    } else {
                        notice("Sign in to AniList or MyAnimeList from Settings to keep a list.")
                        Button("Open Accounts") {
                            dismiss()
                            router.push(Route.settings(.accounts))
                        }
                        .font(AppFont.labelLarge)
                        .foregroundStyle(palette.primary)
                    }
                    watchlistRow.padding(.top, 8)
                    if let failure { notice(failure, error: true) }
                }
                .padding(Metrics.pagePadding)
            }
            .background(palette.background)
            .navigationTitle("My list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.disabled(busy != nil) } }
            .confirmationDialog("Remove \(media.title.preferred) from your list?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
            } message: {
                Text("Its progress and score go with it, and \(account.service?.label ?? "the service") has no undo.")
            }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(busy != nil)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CoverImage(media: media)
                .frame(width: 54, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("MY LIST").font(AppFont.labelSmall.weight(.bold)).kerning(1.2).foregroundStyle(palette.primary)
                Text(media.title.preferred).font(AppFont.titleMedium).foregroundStyle(palette.onSurface).lineLimit(2)
                if let progress = account.progress(of: media.id), progress > 0 {
                    Text("Episode \(progress)\(media.episodes.map { " of \($0)" } ?? "")")
                        .font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
                }
            }
        }
    }

    private func statusRow(_ status: ListStatus, label: String) -> some View {
        let selected = account.statuses[media.id] == status
        return Button { select(status) } label: {
            HStack(spacing: 12) {
                Capsule().fill(selected ? palette.primary : .clear).frame(width: 4, height: 22)
                Image(systemName: icon(status)).frame(width: 22).foregroundStyle(status == .dropped ? palette.error : palette.onSurfaceVariant)
                Text(label).font(AppFont.titleMedium).foregroundStyle(palette.onSurface)
                Spacer()
                if busy == status {
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
        .disabled(busy != nil || working)
    }

    /// Android's "Your score" row, offered only for a title the account holds: either service
    /// would otherwise make an entry to hold the score, on a list the viewer never picked. Going
    /// back from the score sheet returns here, showing the score the account just confirmed.
    @ViewBuilder
    private func scoreRow(_ service: AccountService) -> some View {
        if account.statuses[media.id] != nil {
            let score = account.score(of: media.id)
            let subtitle: String? = score == nil
                ? "Sent to your \(service.label) list"
                : score.flatMap(ListScore.whole).flatMap(ListScore.label)
            SettingsSectionHeader(title: "Your score")
            NavigationLink {
                ScoreSheet(media: media)
            } label: {
                HStack(spacing: 12) {
                    Capsule().fill(.clear).frame(width: 4, height: 22)
                    Image(systemName: score == nil ? "star" : "star.fill")
                        .frame(width: 22)
                        .foregroundStyle(score == nil ? palette.onSurfaceVariant : palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(score.map { "\(ListScore.format($0)) / 10" } ?? "Rate this season")
                            .font(AppFont.titleMedium)
                            .foregroundStyle(palette.onSurface)
                        if let subtitle {
                            Text(subtitle).font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.vertical, 12)
                .padding(.trailing, 14)
                .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy != nil || working)
        }
    }

    private func icon(_ status: ListStatus) -> String {
        switch status {
        case .current: return "play.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        case .planning: return "bookmark"
        case .completed: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .dropped: return "xmark.circle"
        }
    }

    @ViewBuilder
    private func customLists(_ service: AccountService) -> some View {
        let names = account.customListNames
        let mine = account.customLists(of: media.id)
        SettingsSectionHeader(title: service == .anilist ? "Custom lists" : "Tags")
        ForEach(names, id: \.self) { name in
            let on = mine.contains(name)
            Button {
                saveLists(on ? mine.filter { $0 != name } : mine + [name])
            } label: {
                HStack {
                    Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? palette.primary : palette.onSurfaceVariant)
                    Text(name).font(AppFont.bodyLarge).foregroundStyle(palette.onSurface)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(working)
        }
        HStack {
            TextField(service == .anilist ? "New list" : "New tag", text: $newList)
                .textInputAutocapitalization(.words)
                .onSubmit(addList)
            Button("Add", action: addList).disabled(newList.trimmingCharacters(in: .whitespaces).isEmpty || working)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
    }

    private var watchlistRow: some View {
        let saved = library.watchlist.contains(media.id)
        return Button {
            library.toggleWatchlist(media)
        } label: {
            Label(saved ? "Remove from watchlist" : "Add to watchlist", systemImage: saved ? "bookmark.slash" : "bookmark")
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
    }

    private func notice(_ text: String, error: Bool = false) -> some View {
        Text(text)
            .font(AppFont.bodyMedium)
            .foregroundStyle(error ? palette.error : palette.onSurfaceVariant)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    private func select(_ status: ListStatus) {
        guard busy == nil, account.statuses[media.id] != status else { return }
        busy = status
        failure = nil
        Task {
            do {
                try await account.setStatus(media, status)
                busy = nil
                dismiss()
            } catch {
                Log.error("account", "status \(status.rawValue) for \(media.id) failed: \(Log.describe(error))")
                failure = "Couldn't update your list: \(error.localizedDescription)"
                busy = nil
            }
        }
    }

    /// Marks every aired episode watched here, and the title Completed on the account when it's
    /// finished airing (Android's series eye).
    private func markAllWatched(_ total: Int) {
        working = true
        failure = nil
        library.setWatched(media, episodes: (1...total).filter { !library.history.isWatched(mediaID: media.id, episode: $0) })
        Task {
            do {
                if media.nextAiringEpisode == nil { try await account.markCompleted(media) }
                dismiss()
            } catch {
                failure = "Marked here, but the list didn't update: \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func saveLists(_ lists: [String]) {
        working = true
        failure = nil
        Task {
            do {
                try await account.setCustomLists(media, lists)
            } catch {
                Log.error("account", "custom lists for \(media.id) failed: \(Log.describe(error))")
                failure = "Couldn't change the lists: \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func addList() {
        let name = newList.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newList = ""
        let mine = account.customLists(of: media.id)
        if !mine.contains(name) { saveLists(mine + [name]) }
    }

    private func remove() {
        working = true
        failure = nil
        Task {
            do {
                let removed = try await account.removeFromList(media)
                if !removed { failure = "It wasn't on your list." } else { dismiss() }
            } catch {
                failure = "Couldn't remove it: \(error.localizedDescription)"
            }
            working = false
        }
    }
}
#endif
