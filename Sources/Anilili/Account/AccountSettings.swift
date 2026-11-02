#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Settings → Accounts & sync (Android's section): AniList and MyAnimeList (one at a time; signing
/// in to one switches list sync to it), what syncs, and MyAnimeList's tags as lists.
struct AccountSettings: View {
    @Environment(\.palette) private var palette
    @AppStorage(Setting.autoSyncProgress) private var autoSync = true
    @AppStorage(Setting.syncSaved) private var syncSaved = true
    @State private var signingIn: AccountService?
    @State private var managing: AccountService?
    @State private var editingTags = false

    private var account: AccountStore { .shared }

    var body: some View {
        if let service = account.service {
            profileCard(service)
                .padding(.bottom, 4)
        }
        ForEach(AccountService.allCases) { service in
            let connected = account.service == service
            Button {
                if connected { managing = service } else { signingIn = service }
            } label: {
                SettingsRowShell(title: service.label, detail: description(service)) {
                    ConnectionStatus(text: connected ? "Connected" : "Sign in", connected: connected)
                }
            }
            .buttonStyle(.plain)
        }
        ToggleRow(title: "Sync episode progress", detail: "Update watched episodes while playing", isOn: $autoSync)
        ToggleRow(title: "Sync watchlist with Planning", detail: "Import Planning and add new saves without replacing progress", isOn: $syncSaved)
            .onChange(of: syncSaved) { _, on in
                if on { Task { await account.pushWatchlist() } }
            }
        if account.service == .mal {
            ActionRow(title: "MyAnimeList tags as lists", detail: "Choose which of your tags show up on My List") { editingTags = true }
        }
        if account.isSignedIn {
            ActionRow(title: "Refresh now", detail: account.lastRefresh.map { "Last refreshed \($0.formatted(.relative(presentation: .named)))" },
                      busy: account.refreshing, chevron: false) {
                Task { await account.refresh(force: true) }
            }
        }
        if let problem = account.problem {
            SettingsNotice(text: problem, tone: .error)
        }
        Color.clear.frame(height: 0)
            .sheet(item: $signingIn) { service in
                SignInView(service: service).environment(\.palette, palette)
            }
            .sheet(isPresented: $editingTags) { MALTagsSheet().settingsSheet(palette) }
            .confirmationDialog(managing.map { "\($0.label) is connected" } ?? "", isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } }),
                                titleVisibility: .visible) {
                Button("Refresh now") { Task { await account.refresh(force: true) } }
                Button("Sign out", role: .destructive) { account.signOut() }
            } message: {
                Text("Signing out keeps your watchlist and history on this device. Titles seeded from the account leave Continue Watching.")
            }
    }

    /// Android's wording: which service is active, and what signing in to the other would do.
    private func description(_ service: AccountService) -> String {
        if account.service == service { return "The active list service" }
        if account.service != nil { return "Signing in switches list sync to \(service.label)" }
        return "Your lists and episode progress, on every device"
    }

    private func profileCard(_ service: AccountService) -> some View {
        HStack(spacing: 14) {
            RemoteImage(url: account.profile?.avatar) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(palette.onSurfaceVariant)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(account.profile?.name ?? "Signed in").font(AppFont.titleMedium).foregroundStyle(palette.onSurface)
                Text(service.label).font(AppFont.labelMedium).foregroundStyle(palette.primary)
                if let profile = account.profile {
                    Text(stats(profile)).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                }
            }
            Spacer()
            if account.refreshing { ProgressView().controlSize(.small) }
        }
        .padding(14)
        .background(palette.onSurface.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stats(_ profile: AccountProfile) -> String {
        var parts = ["\(profile.animeCount) anime"]
        if profile.episodesWatched > 0 { parts.append("\(profile.episodesWatched) episodes") }
        if profile.minutesWatched > 0 { parts.append(String(format: "%.1f days", Double(profile.minutesWatched) / 1440)) }
        if profile.meanScore > 0 { parts.append(String(format: "mean %.1f", profile.meanScore)) }
        return parts.joined(separator: " · ")
    }
}

/// Which MyAnimeList tags My List shows as lists (Android's `MalTagsDialog`). Unticking one only
/// stops it showing here; the tag stays on MyAnimeList as it was.
private struct MALTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Setting.hiddenMALTags) private var hiddenRaw = ""

    var body: some View {
        let tags = AccountStore.shared.customListNames
        let hidden = MALTags.hidden(hiddenRaw)
        SettingsSheet(kicker: "MyAnimeList", title: "Tags shown as lists",
                      metadata: tags.isEmpty ? nil : "\(tags.filter { !MALTags.isHidden($0, in: hidden) }.count) of \(tags.count) shown",
                      explanation: "MyAnimeList has no custom lists, so Anilili shows your tags as lists instead. Untick a tag to keep it off My List; it stays on MyAnimeList untouched.") {
            if tags.isEmpty {
                SettingsNotice(text: "No tags on your MyAnimeList yet. Lists you make here become tags, and any tags you add on MyAnimeList appear after the next sync.")
            }
            ForEach(tags, id: \.self) { tag in
                let shown = !MALTags.isHidden(tag, in: hidden)
                SelectionOptionRow(title: tag, selected: shown) {
                    let others = hidden.filter { MALTags.key($0) != MALTags.key(tag) }
                    hiddenRaw = (shown ? others + [tag] : others).sorted().joined(separator: ",")
                }
            }
        } footer: {
            Button("Done") { dismiss() }
        }
    }
}

/// Android's `hidden_mal_tags`: comma-separated, compared trimmed and case-blind.
enum MALTags {
    static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    static func hidden(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isHidden(_ tag: String, in hidden: [String]) -> Bool {
        hidden.contains { key($0) == key(tag) }
    }

    static var hiddenNow: [String] { hidden(UserDefaults.standard.string(forKey: Setting.hiddenMALTags) ?? "") }
}
#endif
