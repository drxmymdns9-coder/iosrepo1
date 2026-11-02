import Foundation

/// The MyAnimeList XML export (Android's `MalExport`), which MAL's own importer and most trackers
/// take: the account's list when signed in, otherwise what this device knows (saves as Plan to
/// Watch, history as Watching or Completed). Titles without a MAL id are skipped and counted.
public enum MALExport {
    public struct Entry: Equatable, Sendable {
        public var malID: Int
        public var title: String
        public var format: String?
        public var episodes: Int?
        public var watchedEpisodes: Int
        public var score: Int
        public var status: String
        public var rewatching: Bool

        public init(malID: Int, title: String, format: String?, episodes: Int?, watchedEpisodes: Int, score: Int, status: String, rewatching: Bool = false) {
            self.malID = malID
            self.title = title
            self.format = format
            self.episodes = episodes
            self.watchedEpisodes = watchedEpisodes
            self.score = score
            self.status = status
            self.rewatching = rewatching
        }
    }

    public static func entry(_ media: Media, status: String, progress: Int, score: Double = 0, rewatching: Bool = false) -> Entry? {
        guard let malID = media.idMal, malID > 0 else { return nil }
        let watched = status == "Completed" && progress <= 0 ? (media.episodes ?? progress) : progress
        return Entry(malID: malID, title: media.title.preferred, format: media.format, episodes: media.episodes,
                     watchedEpisodes: watched, score: score > 0 ? Int(score.rounded()) : 0, status: status, rewatching: rewatching)
    }

    public static func status(_ status: ListStatus) -> (label: String, rewatching: Bool) {
        switch status {
        case .current: return ("Watching", false)
        case .repeating: return ("Watching", true)
        case .completed: return ("Completed", false)
        case .paused: return ("On-Hold", false)
        case .dropped: return ("Dropped", false)
        case .planning: return ("Plan to Watch", false)
        }
    }

    public static func localStatus(progress: Int, episodes: Int?) -> String {
        if progress <= 0 { return "Plan to Watch" }
        if let episodes, episodes > 0, progress >= episodes { return "Completed" }
        return "Watching"
    }

    /// The account's entries, or the device's saves and history.
    public static func entries(account: AccountLibrary?, history: WatchHistory, watchlist: Watchlist) -> (entries: [Entry], skipped: Int) {
        var entries: [Entry] = []
        var skipped = 0
        if let account, !account.entries.isEmpty {
            for item in account.statusEntries {
                let (label, rewatching) = status(item.status)
                if let entry = entry(item.media, status: label, progress: item.progress, score: item.score, rewatching: rewatching) {
                    entries.append(entry)
                } else {
                    skipped += 1
                }
            }
            return (entries, skipped)
        }
        var seen = Set<Int>()
        for show in history.continueWatching {
            seen.insert(show.media.id)
            let watched = show.episodes.filter { $0.value.isFinished }.keys.max() ?? 0
            if let entry = entry(show.media, status: localStatus(progress: watched, episodes: show.media.episodes), progress: watched) {
                entries.append(entry)
            } else {
                skipped += 1
            }
        }
        for media in watchlist.items where seen.insert(media.id).inserted {
            if let entry = entry(media, status: "Plan to Watch", progress: 0) { entries.append(entry) } else { skipped += 1 }
        }
        return (entries, skipped)
    }

    public static func xml(username: String?, entries: [Entry]) -> String {
        var lines = [#"<?xml version="1.0" encoding="UTF-8" ?>"#, "<myanimelist>", "  <myinfo>", "    <user_id>0</user_id>",
                     "    <user_name>\(escape(username ?? "Anilili"))</user_name>", "    <user_export_type>1</user_export_type>", "  </myinfo>"]
        for entry in entries {
            lines += [
                "  <anime>",
                "    <series_animedb_id>\(entry.malID)</series_animedb_id>",
                "    <series_title>\(escape(entry.title))</series_title>",
                "    <series_type>\(escape(type(entry.format)))</series_type>",
                "    <series_episodes>\(entry.episodes ?? 0)</series_episodes>",
                "    <my_id>0</my_id>",
                "    <my_watched_episodes>\(max(0, entry.watchedEpisodes))</my_watched_episodes>",
                "    <my_start_date>0000-00-00</my_start_date>",
                "    <my_finish_date>0000-00-00</my_finish_date>",
                "    <my_score>\(min(max(entry.score, 0), 10))</my_score>",
                "    <my_status>\(escape(entry.status))</my_status>",
                "    <my_comments></my_comments>",
                "    <my_times_watched>0</my_times_watched>",
                "    <my_rewatch_value></my_rewatch_value>",
                "    <my_tags></my_tags>",
                "    <my_rewatching>\(entry.rewatching ? 1 : 0)</my_rewatching>",
                "    <my_rewatching_ep>0</my_rewatching_ep>",
                "    <update_on_import>1</update_on_import>",
                "  </anime>",
            ]
        }
        lines.append("</myanimelist>")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func fileName(_ date: Date = Date()) -> String {
        BackupDocument.fileName(date).replacingOccurrences(of: "Anilili-backup-", with: "Anilili-mal-export-").replacingOccurrences(of: ".json", with: ".xml")
    }

    static func type(_ format: String?) -> String {
        switch format?.uppercased() {
        case "MOVIE": return "Movie"
        case "SPECIAL": return "Special"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "MUSIC": return "Music"
        default: return "TV"
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
