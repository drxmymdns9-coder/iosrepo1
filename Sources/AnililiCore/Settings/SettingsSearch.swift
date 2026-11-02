import Foundation

/// One setting as the Settings search knows it: its title (the row's own), the section holding it,
/// and the words people type instead of its name (Android's `SettingsSearchEntry`).
public struct SettingsSearchEntry: Hashable, Identifiable, Sendable {
    public let sectionID: String
    public let sectionTitle: String
    public let title: String
    public let keywords: [String]

    public var id: String { "\(sectionID).\(title)" }

    public init(_ sectionID: String, _ sectionTitle: String, _ title: String, _ keywords: [String] = []) {
        self.sectionID = sectionID
        self.sectionTitle = sectionTitle
        self.title = title
        self.keywords = keywords
    }
}

/// Android's `settingsSearchEntries` and `searchSettings`, for the rows the iOS app has.
///
/// Hand-written, like Android's: the rows are SwiftUI calls across several files and there is
/// nothing to enumerate. Each title is the row's exact title, which is how a picked result finds
/// its row to scroll to and mark.
public enum SettingsSearch {
    public static let entries: [SettingsSearchEntry] = {
        var all: [SettingsSearchEntry] = []
        func section(_ id: String, _ title: String, _ rows: [(String, [String])]) {
            all += rows.map { SettingsSearchEntry(id, title, $0.0, $0.1) }
        }
        section("player", "Player", [
            ("Play when an episode opens", ["autoplay", "start", "automatic"]),
            ("Open episodes in external player", ["external", "video", "player", "vlc", "infuse", "automatic"]),
            ("External player", ["external", "video", "player", "app", "open with", "default", "vlc", "infuse"]),
            ("Autoplay next episode", ["autoplay", "next", "continue", "binge"]),
            ("Keep playing in a mini player", ["mini", "pip", "picture in picture", "floating", "background", "home"]),
            ("Show details when paused", ["pause", "description", "synopsis"]),
            ("Auto-skip intro, recap and outro", ["skip", "opening", "ending", "op", "ed"]),
            ("Skip button", ["skip", "button"]),
            ("Skip button length", ["skip", "seconds", "length", "85"]),
            ("Watched at", ["progress", "watched", "percent", "complete"]),
            ("Default quality", ["quality", "resolution", "1080", "720", "480", "data"]),
            ("Buffer size", ["buffer", "buffering", "stutter", "stall", "freeze", "lag", "loading", "cache", "network", "wifi", "memory"]),
            ("Playback speed", ["speed", "fast", "slow", "2x"]),
            ("Hold to change speed", ["hold", "long press", "gesture", "toggle"]),
            ("Hold speed", ["hold", "long press", "fast", "slow", "0.5x", "2x", "4x"]),
            ("Preferred audio language", ["audio", "language", "dub", "english"]),
            ("Second choice audio", ["audio", "language", "fallback"]),
            ("Default screen size", ["screen", "size", "zoom", "crop", "fill", "aspect"]),
            ("Prefer dubbed audio", ["dub", "dubbed", "sub", "audio"]),
            ("Brightness and volume gestures", ["gesture", "brightness", "volume", "swipe"]),
            ("Drag to seek", ["gesture", "seek", "scrub", "drag", "swipe"]),
            ("Status bar over the player", ["status", "bar", "fullscreen", "notch"]),
            ("Clock and finishing time", ["clock", "time", "ends", "ending", "finish", "bedtime", "night", "late", "watch"]),
            ("Player debug overlay", ["debug", "overlay", "diagnostics"]),
        ])
        section("subtitles", "Subtitles", [
            ("Show subtitles by default", ["subtitle", "caption", "cc", "default"]),
            ("Also on dubbed audio", ["subtitle", "dub", "caption"]),
            ("Preferred subtitle language", ["subtitle", "language", "english"]),
            ("Second choice subtitles", ["subtitle", "language", "fallback"]),
            ("Caption appearance", ["caption", "subtitle", "font", "size", "colour", "color", "background", "position",
                                    "opacity", "transparent", "move", "place", "margin"]),
            ("OpenSubtitles", ["opensubtitles", "account", "download", "subtitle"]),
            ("Subtitle search language", ["opensubtitles", "language", "search"]),
        ])
        section("downloads", "Downloads", [
            ("Download resolution", ["download", "quality", "resolution", "size"]),
            ("Space used", ["download", "storage", "space", "size"]),
            ("Remove all downloads", ["download", "delete", "remove", "storage", "space"]),
        ])
        section("servers", "Servers", [
            ("Enabled servers", ["server", "source", "provider", "enable", "disable", "off", "on", "hide", "block"]),
            ("Server priority", ["server", "source", "provider", "order", "priority"]),
        ])
        section("accounts", "Accounts & sync", [
            ("AniList", ["anilist", "account", "login", "sync"]),
            ("MyAnimeList", ["mal", "myanimelist", "account", "login", "sync"]),
            ("Sync episode progress", ["sync", "progress", "episode", "anilist", "mal"]),
            ("Sync watchlist with Planning", ["sync", "watchlist", "planning", "list"]),
            ("MyAnimeList tags as lists", ["mal", "myanimelist", "tags", "lists", "my list"]),
        ])
        section("notifications", "Notifications", [
            ("Notification alerts", ["notification", "alert", "release", "airing", "reminder"]),
            ("Announcements", ["announcement", "broadcast", "notice", "developer", "outage", "emergency"]),
            ("Signature expiry reminder", ["signature", "signing", "expire", "expiry", "refresh", "sideload", "sidestore", "sideloadly", "7 days"]),
        ])
        section("content", "Content", [
            ("Hide adult content", ["adult", "nsfw", "hentai", "mature", "filter"]),
            ("Only episodes you can watch", ["continue watching", "home", "episode", "airing", "tomorrow", "upcoming",
                                             "hide", "schedule", "row", "week", "next episode", "caught up"]),
        ])
        section("appearance", "Appearance", [
            ("Theme presets", ["theme", "preset", "look", "crimson", "toxic", "royal", "sakura", "cyber", "ember",
                               "gilded", "forest", "deep sea", "midnight", "high contrast"]),
            ("Background", ["theme", "amoled", "black", "oled", "dark", "grey", "gray", "canvas"]),
            ("Accent colour", ["theme", "color", "colour", "accent", "monochrome", "purple", "green", "neon", "red",
                               "blood", "blue", "cyan", "pink", "orange", "gold", "emerald"]),
            ("Custom colour", ["custom", "color", "colour", "hex", "hue", "picker", "own", "rgb"]),
            ("Colour style", ["theme", "color", "vivid", "tonal", "neutral", "vibrant", "material"]),
            ("Contrast", ["theme", "contrast", "readability", "legibility", "low vision"]),
            ("Colour anime pages by the show", ["anime page", "detail", "show", "color", "colour", "accent", "poster", "theme"]),
            ("Accent in the player", ["player", "seek", "accent", "color", "colour"]),
            ("Match app icon to theme", ["icon", "app icon", "launcher", "home screen", "logo", "color", "colour", "accent"]),
            ("All glass effects", ["glass", "blur", "frosted", "liquid", "transparent"]),
            ("Reset theme", ["theme", "reset", "default", "restore"]),
            ("Keep the bars on screen", ["bar", "chrome", "hide", "scroll", "menu", "top", "nav", "navigation", "fade",
                                         "auto hide", "always", "pin", "tab bar"]),
            ("Search as you type", ["search", "suggest", "suggestion", "autocomplete", "auto suggest", "typing",
                                    "keyboard", "lag", "slow", "live", "instant"]),
            ("Arrange Home", ["home", "rows", "row", "order", "reorder", "arrange", "layout", "customize", "customise",
                              "sections", "drag", "move", "hide", "show", "for you", "trending"]),
            ("Card details", ["poster", "card", "badge", "label", "tag", "dub", "score", "rating", "star", "title",
                              "name", "caption", "details", "cover", "artwork", "hide", "show", "new", "progress",
                              "18+", "adult", "clean", "minimal"]),
            ("Blur episode images", ["blur", "spoiler", "thumbnail", "image"]),
            ("Series logos", ["logo", "title", "name", "wordmark", "header", "clearlogo", "text"]),
            ("Time format", ["time", "clock", "12", "24", "hour", "am", "pm", "military", "schedule"]),
        ])
        section("data", "Data", [
            ("Back up to a file", ["backup", "export", "save", "transfer"]),
            ("Restore from a backup", ["restore", "import", "backup", "transfer"]),
            ("Export MyAnimeList XML", ["export", "mal", "myanimelist", "xml"]),
            ("Import MyAnimeList XML", ["import", "mal", "myanimelist", "xml"]),
            ("Clear cache", ["cache", "clear", "storage", "space", "images"]),
            ("Re-download metadata", ["metadata", "refresh", "index", "catalogue", "catalog", "update", "data", "stale"]),
            ("Clear viewing history", ["history", "clear", "watched", "continue"]),
        ])
        section("app", "App", [
            ("Menu language", ["language", "spanish", "español", "english", "menu", "idioma"]),
            ("Layout", ["layout", "tv", "television", "ipad", "tablet", "phone", "form factor", "device", "big screen"]),
            ("Check for updates on launch", ["update", "upgrade", "new version", "prompt", "launch", "automatic"]),
            ("Check for updates", ["update", "upgrade", "new version", "install", "sidestore", "altstore", "ipa"]),
            ("Version", ["version", "build", "update"]),
            ("Signature", ["signature", "signing", "expire", "expiry", "refresh", "sideload", "sidestore", "sideloadly", "certificate"]),
            ("Send diagnostics", ["diagnostics", "logs", "report", "bug"]),
            ("Debug log", ["debug", "log", "diagnostics", "logs", "report", "bug"]),
        ])
        section("about", "About", [
            ("Discord server", ["discord", "support", "community", "help"]),
        ])
        return all
    }()

    /// The settings a typed query offers, best first: a title the query starts beats a title
    /// with a word it starts, beats a title merely containing it, beats a keyword, beats the
    /// section's name. Every word has to land somewhere, so a second word only narrows.
    public static func search(_ query: String, in entries: [SettingsSearchEntry] = entries, limit: Int = 8) -> [SettingsSearchEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var ranked: [(entry: SettingsSearchEntry, rank: Int, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            let title = entry.title.lowercased()
            let section = entry.sectionTitle.lowercased()
            let titleWords = title.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            var best = Int.max
            var matched = true
            for word in words {
                let rank: Int
                if title.hasPrefix(word) {
                    rank = 0
                } else if titleWords.contains(where: { $0.hasPrefix(word) }) {
                    rank = 1
                } else if title.contains(word) {
                    rank = 2
                } else if entry.keywords.contains(where: { $0.hasPrefix(word) }) {
                    rank = 3
                } else if entry.keywords.contains(where: { $0.contains(word) }) {
                    rank = 4
                } else if section.contains(word) {
                    rank = 5
                } else {
                    matched = false
                    break
                }
                best = min(best, rank)
            }
            if matched { ranked.append((entry, best, order)) }
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.prefix(limit).map(\.entry)
    }

    /// Past queries offered as completions of what is being typed: containing it, not equal to
    /// it, at most three. An empty field offers none (Android's `SettingsSearch`).
    public static func completions(_ query: String, history: [String]) -> [String] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }
        return Array(history.filter {
            $0.range(of: term, options: .caseInsensitive) != nil && $0.caseInsensitiveCompare(term) != .orderedSame
        }.prefix(3))
    }

    /// Android's `SettingsSearchHistory.record`: the term to the front, once, eight at most.
    public static func recording(_ query: String, in history: [String]) -> [String] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return history }
        return Array(([term] + history.filter { $0.caseInsensitiveCompare(term) != .orderedSame }).prefix(8))
    }
}
