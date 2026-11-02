#if canImport(UIKit)
import AnililiCore
import Foundation
import Observation

/// The signed-in list service (AniList or MyAnimeList, one at a time as on Android): its tokens,
/// the viewer, the account's lists and notifications, and every push the app makes to it, under
/// Android's rules (`LibraryStore` remote half, `AuthManager`, `MalAuthManager`).
///
/// Lists are cached in UserDefaults so My List and the status marks show offline; a push that
/// fails is kept and retried on the next refresh.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var service: AccountService?
    private(set) var profile: AccountProfile?
    private(set) var library: AccountLibrary = .empty
    /// Each title's status on the account, updated the moment the app changes one.
    private(set) var statuses: [Int: ListStatus] = [:]
    private(set) var favourites: [Media] = []
    /// The account's own activity per epoch day (AniList only; MyAnimeList keeps none), for the
    /// account sheet's grid.
    private(set) var activityHistory: [Int: Int] = [:]
    private(set) var notifications: [AccountNotification] = []
    private(set) var unreadNotifications = 0
    private(set) var refreshing = false
    private(set) var lastRefresh: Date?
    /// The last failure worth telling the viewer about (Settings → Accounts shows it).
    private(set) var problem: String?

    @ObservationIgnored weak var libraryStore: LibraryStore?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var pendingProgress: [Int: PendingProgress] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    struct PendingProgress: Codable {
        var media: Media
        var episode: Int
    }

    private enum Key {
        static let anilistToken = "anilist_token"
        static let malTokens = "mal_tokens"
        static let profile = "account.profile.v1"
        static let library = "account.library.v1"
        static let pending = "account.pendingProgress.v1"
    }

    /// Android refreshes on cold start and foreground, at most this often unless forced.
    static let refreshInterval: TimeInterval = 5 * 60

    private init() {
        if let token = Keychain.string(Key.anilistToken) {
            if AniListAuth.isExpired(token) {
                Log.info("account", "stored AniList token expired; signed out")
                Keychain.set(nil, for: Key.anilistToken)
            } else {
                AccountCredentials.shared.anilistToken = token
                service = .anilist
            }
        }
        if service == nil, let raw = Keychain.string(Key.malTokens),
           let tokens = try? JSONDecoder().decode(MALAuth.Tokens.self, from: Data(raw.utf8)) {
            AccountCredentials.shared.malTokens = tokens
            service = .mal
        }
        if service != nil {
            profile = load(AccountProfile.self, Key.profile)
            library = load(AccountLibrary.self, Key.library) ?? .empty
            statuses = library.statuses
            pendingProgress = load([Int: PendingProgress].self, Key.pending) ?? [:]
        }
        Log.info("account", "signed in to \(service?.label ?? "nothing"); \(library.entries.count) cached entries")

        AccountCredentials.shared.onMALTokensChanged { tokens in
            Task { @MainActor in AccountStore.shared.malTokensChanged(tokens) }
        }
        NotificationCenter.default.addObserver(forName: AniListClient.sessionExpired, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = AccountStore.shared
                guard store.service == .anilist else { return }
                store.signOut(reason: AccountError.sessionExpired(.anilist).localizedDescription)
            }
        }
    }

    var isSignedIn: Bool { service != nil }

    // MARK: - Signing in and out

    func signInAniList(token: String) async {
        signOut(reason: nil, quietly: true)
        Keychain.set(token, for: Key.anilistToken)
        AccountCredentials.shared.anilistToken = token
        service = .anilist
        Log.info("account", "signed in to AniList (viewer \(AniListAuth.viewerID(token).map(String.init) ?? "?"))")
        await afterSignIn()
    }

    func signInMAL(code: String, verifier: String) async throws {
        let tokens = try await MALAuth.exchange(code: code, verifier: verifier)
        signOut(reason: nil, quietly: true)
        storeMAL(tokens)
        AccountCredentials.shared.malTokens = tokens
        service = .mal
        Log.info("account", "signed in to MyAnimeList")
        await afterSignIn()
    }

    private func afterSignIn() async {
        problem = nil
        await refresh(force: true)
        // A new account hears about everything saved here (Android's `syncSavedToRemote`).
        await pushWatchlist()
    }

    /// Forgets everything that describes the account being left, so a switch can't read the old
    /// account's snapshot as the new one's (Android's `clearRemoteLibrary`).
    func signOut(reason: String? = nil, quietly: Bool = false) {
        refreshTask?.cancel()
        Keychain.set(nil, for: Key.anilistToken)
        Keychain.set(nil, for: Key.malTokens)
        AccountCredentials.shared.anilistToken = nil
        AccountCredentials.shared.malTokens = nil
        if !quietly { Log.info("account", "signed out of \(service?.label ?? "nothing")\(reason.map { ": \($0)" } ?? "")") }
        service = nil
        profile = nil
        library = .empty
        statuses = [:]
        favourites = []
        activityHistory = [:]
        notifications = []
        unreadNotifications = 0
        lastRefresh = nil
        pendingProgress = [:]
        problem = reason
        dismissedSeeds = []
        defaults.removeObject(forKey: "account.dismissedSeeds.v1")
        for key in [Key.profile, Key.library, Key.pending] { defaults.removeObject(forKey: key) }
    }

    private func malTokensChanged(_ tokens: MALAuth.Tokens?) {
        guard service == .mal else { return }
        if let tokens {
            storeMAL(tokens)
        } else {
            signOut(reason: AccountError.sessionExpired(.mal).localizedDescription)
        }
    }

    private func storeMAL(_ tokens: MALAuth.Tokens) {
        if let data = try? JSONEncoder().encode(tokens) { Keychain.set(String(decoding: data, as: UTF8.self), for: Key.malTokens) }
    }

    // MARK: - Refreshing

    func refreshIfStale() {
        guard service != nil, !refreshing else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        refreshTask = Task { await refresh(force: false) }
    }

    func refresh(force: Bool) async {
        guard let service, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            await retryPendingProgress()
            let fresh: AccountLibrary
            switch service {
            case .anilist:
                if profile == nil || force { profile = try await AniListClient.shared.viewer() }
                let viewerID = AccountCredentials.shared.anilistToken.flatMap(AniListAuth.viewerID) ?? profile?.id
                guard let viewerID else { throw HTTPError("Couldn't tell which AniList account this is") }
                fresh = try await AniListClient.shared.animeList(userID: viewerID)
                favourites = (try? await AniListClient.shared.favouriteAnime()) ?? favourites
                // Reported empty rather than failing the refresh: it's a deprecated field.
                activityHistory = (try? await AniListClient.shared.activityHistory(userID: viewerID)) ?? activityHistory
                if let feed = try? await AniListClient.shared.notifications() {
                    notifications = feed.items
                    unreadNotifications = feed.unread
                }
            case .mal:
                if profile == nil || force { profile = try await MALClient.shared.viewer() }
                fresh = try await MALClient.shared.library()
            }
            guard self.service == service else { return }
            hydrate(fresh)
            lastRefresh = Date()
            problem = nil
            save(profile, Key.profile)
            Log.info("account", "\(service.label) library refreshed: \(fresh.entries.count) entries, \(statuses.count) on status lists")
        } catch {
            Log.error("account", "\(service.label) refresh failed: \(Log.describe(error))")
            if let accountError = error as? AccountError, case .sessionExpired = accountError {
                signOut(reason: accountError.localizedDescription)
            } else {
                problem = "Couldn't refresh your \(service.label) list: \(error.localizedDescription)"
            }
        }
    }

    /// Publishes a fetched list everywhere, and folds its Plan to watch into the device's saves.
    private func hydrate(_ fresh: AccountLibrary) {
        let previous = statuses
        library = fresh
        statuses = fresh.statuses
        save(fresh, Key.library)
        guard UserDefaults.standard.object(forKey: Setting.syncSaved) as? Bool ?? true else { return }
        let planning = fresh.entries(.planning).map(\.media)
        libraryStore?.mergeWatchlist(planning: planning, knownRemoteIDs: Set(statuses.keys), previousRemoteIDs: Set(previous.keys))
    }

    // MARK: - Lists

    /// Moves a title to another list (the list status dialog).
    func setStatus(_ media: Media, _ status: ListStatus) async throws {
        guard let service else { throw AccountError.signInRequired }
        Log.info("account", "\(service.label) status \(media.id) → \(status.rawValue)")
        switch service {
        case .anilist:
            try await AniListClient.shared.setStatus(mediaID: media.id, status)
        case .mal:
            let malID = try await malID(for: media)
            try await MALClient.shared.update(malID: malID, status: status.malValue, rewatching: status == .repeating)
        }
        statuses[media.id] = status
        upsertEntry(media) { $0.status = status }
    }

    /// The series eye: every episode watched, Completed, in one write (Android's `setWatched`,
    /// which skips the progress planner so a second "watched" after an undo still lands).
    func markCompleted(_ media: Media) async throws {
        guard let service else { throw AccountError.signInRequired }
        switch service {
        case .anilist:
            try await AniListClient.shared.setCompleted(mediaID: media.id, totalEpisodes: media.episodes)
        case .mal:
            let malID = try await malID(for: media)
            try await MALClient.shared.update(malID: malID, progress: media.episodes, status: ListStatus.completed.malValue, rewatching: false)
        }
        Log.info("account", "\(service.label) marked \(media.id) completed")
        statuses[media.id] = .completed
        upsertEntry(media) { entry in
            entry.status = .completed
            if let total = media.episodes { entry.progress = total }
        }
    }

    /// Takes a title off the account's list entirely. False when it wasn't on it.
    func removeFromList(_ media: Media) async throws -> Bool {
        guard let service else { throw AccountError.signInRequired }
        let removed: Bool
        switch service {
        case .anilist:
            removed = try await AniListClient.shared.deleteEntry(mediaID: media.id)
        case .mal:
            let malID = try await malID(for: media)
            if try await MALClient.shared.animeStatus(malID: malID).entry == nil {
                removed = false
            } else {
                try await MALClient.shared.delete(malID: malID)
                removed = true
            }
        }
        Log.info("account", "\(service.label) removed \(media.id): \(removed)")
        statuses[media.id] = nil
        library.entries.removeAll { $0.media.id == media.id }
        save(library, Key.library)
        return removed
    }

    /// The viewer's own score for a title on the account, nil when it has none (Android's
    /// `remoteScores`).
    func score(of mediaID: Int) -> Double? {
        guard let score = library.entries.first(where: { $0.media.id == mediaID })?.score, score > 0 else { return nil }
        return score
    }

    /// Scores a title already on the account, 1–10, or 0 to remove the score (Android's
    /// `updateAnimeListScore`).
    func setScore(_ media: Media, _ score: Int) async throws {
        guard let service else { throw AccountError.signInRequired }
        switch service {
        case .anilist:
            try await AniListClient.shared.setScore(mediaID: media.id, score)
        case .mal:
            let malID = try await malID(for: media)
            try await MALClient.shared.update(malID: malID, score: score)
        }
        Log.info("account", "\(service.label) score \(media.id) → \(score)")
        upsertEntry(media) { $0.score = Double(score) }
    }

    /// Custom lists (AniList) or tags (MAL) a title is in.
    func customLists(of mediaID: Int) -> [String] {
        library.entries.first { $0.media.id == mediaID }?.customLists ?? []
    }

    /// Every custom list name: AniList's own list of them, or the tags in use on MAL.
    var customListNames: [String] {
        if service == .anilist { return library.customListNames }
        var seen = Set<String>()
        return library.entries.flatMap(\.customLists).filter { seen.insert($0).inserted }.sorted()
    }

    func setCustomLists(_ media: Media, _ lists: [String]) async throws {
        guard let service else { throw AccountError.signInRequired }
        let known = library.entries.contains { $0.media.id == media.id }
        switch service {
        case .anilist:
            let missing = lists.filter { !library.customListNames.contains($0) }
            if !missing.isEmpty {
                library.customListNames = try await AniListClient.shared.setCustomListNames(library.customListNames + missing)
            }
            try await AniListClient.shared.setCustomLists(mediaID: media.id, lists: lists, create: !known)
        case .mal:
            let malID = try await malID(for: media)
            try await MALClient.shared.update(malID: malID, status: known ? nil : ListStatus.planning.malValue, tags: lists)
        }
        Log.info("account", "\(service.label) custom lists of \(media.id): \(lists)")
        upsertEntry(media, hidden: !known && service == .anilist) { $0.customLists = lists }
    }

    private func upsertEntry(_ media: Media, hidden: Bool = false, _ change: (inout ListEntry) -> Void) {
        if let index = library.entries.firstIndex(where: { $0.media.id == media.id }) {
            change(&library.entries[index])
            library.entries[index].updatedAt = Date()
        } else {
            var entry = ListEntry(entryID: 0, media: media, status: statuses[media.id] ?? .planning, progress: 0,
                                  updatedAt: Date(), hiddenFromStatusLists: hidden)
            change(&entry)
            library.entries.append(entry)
        }
        save(library, Key.library)
    }

    private func malID(for media: Media) async throws -> Int {
        if let id = media.idMal, id > 0 { return id }
        if let id = try await AniListClient.shared.media(id: media.id).idMal, id > 0 { return id }
        throw AccountError.notOnMAL
    }

    // MARK: - What the device tells the account

    /// A finished episode moves the account's progress on (never back), when Settings allows it.
    func episodeWatched(_ media: Media, episode: Int) {
        guard service != nil, media.id > 0, UserDefaults.standard.object(forKey: Setting.autoSyncProgress) as? Bool ?? true else { return }
        pendingProgress[media.id] = PendingProgress(media: media, episode: max(episode, pendingProgress[media.id]?.episode ?? 0))
        save(pendingProgress, Key.pending)
        Task { await pushProgress(media.id) }
    }

    private func pushProgress(_ mediaID: Int) async {
        guard let service, let pending = pendingProgress[mediaID] else { return }
        do {
            let update: ProgressUpdate?
            switch service {
            case .anilist:
                update = try await AniListClient.shared.syncProgress(mediaID: mediaID, watched: pending.episode, totalEpisodes: pending.media.episodes)
            case .mal:
                update = try await MALClient.shared.syncProgress(malID: try await malID(for: pending.media), watched: pending.episode)
            }
            pendingProgress[mediaID] = nil
            save(pendingProgress, Key.pending)
            if let update {
                Log.info("account", "\(service.label) progress \(mediaID) → \(update.progress)\(update.status.map { " (\($0.rawValue))" } ?? "")")
                if let status = update.status { statuses[mediaID] = status }
                upsertEntry(pending.media) { entry in
                    entry.progress = update.progress
                    if let status = update.status { entry.status = status }
                }
            } else {
                Log.info("account", "\(service.label) progress \(mediaID) ep \(pending.episode): nothing to change")
            }
        } catch {
            // Kept for the next refresh: without it the account never hears about this episode.
            Log.error("account", "\(service.label) progress \(mediaID) ep \(pending.episode) failed: \(Log.describe(error))")
        }
    }

    private func retryPendingProgress() async {
        for id in Array(pendingProgress.keys.prefix(10)) { await pushProgress(id) }
    }

    /// The Save button, mirrored onto Plan to watch without hurting an entry that's more than a plan.
    func savedChanged(_ media: Media, saved: Bool) {
        guard let service, media.id > 0, UserDefaults.standard.object(forKey: Setting.syncSaved) as? Bool ?? true else { return }
        Task {
            do {
                switch service {
                case .anilist: try await AniListClient.shared.syncSaved(mediaID: media.id, saved: saved)
                case .mal: try await MALClient.shared.syncSaved(malID: try await malID(for: media), saved: saved)
                }
                Log.info("account", "\(service.label) saved \(media.id): \(saved)")
                if saved, statuses[media.id] == nil {
                    statuses[media.id] = .planning
                    upsertEntry(media) { $0.status = .planning }
                } else if !saved, statuses[media.id] == .planning {
                    statuses[media.id] = nil
                    library.entries.removeAll { $0.media.id == media.id && $0.customLists.isEmpty }
                    save(library, Key.library)
                }
            } catch {
                Log.error("account", "\(service.label) saved sync \(media.id) failed: \(Log.describe(error))")
            }
        }
    }

    /// Every device save the account doesn't know yet goes up as Plan to watch.
    func pushWatchlist() async {
        guard let service, UserDefaults.standard.object(forKey: Setting.syncSaved) as? Bool ?? true,
              let saved = libraryStore?.watchlist.items else { return }
        let missing = saved.filter { $0.id > 0 && statuses[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Log.info("account", "pushing \(missing.count) saved titles to \(service.label)")
        for media in missing {
            do {
                switch service {
                case .anilist: try await AniListClient.shared.syncSaved(mediaID: media.id, saved: true)
                case .mal: try await MALClient.shared.syncSaved(malID: try await malID(for: media), saved: true)
                }
                statuses[media.id] = .planning
                upsertEntry(media) { $0.status = .planning }
            } catch {
                Log.error("account", "saved push \(media.id) failed: \(Log.describe(error))")
                // AniList's limit drops to 30 a minute when degraded; stop rather than dig deeper.
                if (error as? HTTPError)?.status == 429 { break }
            }
        }
    }

    // MARK: - Continue Watching from the account

    /// Titles the account is watching that this device has no history for: a fresh install
    /// signed in to an existing account isn't blank (Android's seeded rows).
    func seededShows(excluding local: Set<Int>) -> [WatchHistory.Show] {
        library.statusEntries
            .filter { $0.status.isWatching && !local.contains($0.media.id) && !dismissedSeeds.contains($0.media.id) }
            .compactMap { entry in
                ListSync.resumeEpisode(progress: entry.progress, totalEpisodes: entry.media.episodes, airedEpisodes: entry.media.releasedEpisodes)
                    .map { WatchHistory.Show(media: entry.media, lastEpisode: $0, updatedAt: entry.updatedAt) }
            }
    }

    /// Local Continue Watching with the account's seeded rows, most recent first.
    func continueWatching(_ history: WatchHistory) -> [WatchHistory.Show] {
        let local = history.continueWatching
        return (local + seededShows(excluding: Set(local.map(\.media.id)))).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Seeded rows the viewer removed here; playing the title again brings its own row back.
    private(set) var dismissedSeeds: Set<Int> = Set(UserDefaults.standard.array(forKey: "account.dismissedSeeds.v1") as? [Int] ?? [])

    func dismissSeed(_ mediaID: Int) {
        dismissedSeeds.insert(mediaID)
        defaults.set(Array(dismissedSeeds), forKey: "account.dismissedSeeds.v1")
    }

    func progress(of mediaID: Int) -> Int? {
        library.entries.first { $0.media.id == mediaID }?.progress
    }

    // MARK: - Notifications

    func loadNotifications(markRead: Bool) async {
        guard service == .anilist else { return }
        do {
            let feed = try await AniListClient.shared.notifications()
            notifications = feed.items
            unreadNotifications = feed.unread
            if markRead, feed.unread > 0 {
                try await AniListClient.shared.markNotificationsRead()
                unreadNotifications = 0
            }
        } catch {
            Log.error("account", "notifications failed: \(Log.describe(error))")
            problem = "Couldn't load notifications: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
#endif
