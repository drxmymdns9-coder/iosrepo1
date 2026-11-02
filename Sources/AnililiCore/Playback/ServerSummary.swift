import Foundation

/// What the server picker says about each server, after Android's `SourceLanguages`,
/// `SourceFilter` and the watch screen's `serverDescription`: which languages it carries, how its
/// subtitles come, whether it can be saved, so a viewer can choose between servers by more than a
/// name.
public enum ServerSummary {
    /// What a server is taken to carry until it names something else (Android's
    /// `ASSUMED_LANGUAGE`): these sources are English unless they say so.
    public static let assumedLanguage = "English"

    /// The languages a server carries in `audio`, as display names: a soft-sub server's subtitle
    /// files, a server that names its language in its own name ("AnimeDekho (Hindi)"), a dub's
    /// audio track, and otherwise the English everything is assumed to be.
    public static func languages(of source: VideoSource, audio: AudioTrack) -> [String] {
        if let declared = declaredLanguage(source.provider) { return [declared] }
        if audio == .sub, source.softSub, !source.subtitles.isEmpty {
            var seen = Set<String>()
            let named = source.subtitles
                .compactMap { normalizeLanguage($0.language) ?? normalizeLanguage($0.label) }
                .filter { seen.insert($0).inserted }
                .sorted()
            if !named.isEmpty { return named }
        }
        if audio == .dub, let spoken = normalizeLanguage(source.audioLanguage) { return [spoken] }
        return [assumedLanguage]
    }

    /// Every language across `sources`, alphabetical, for the picker's language chips.
    public static func languages(of sources: [VideoSource], audio: AudioTrack) -> [String] {
        Array(Set(sources.flatMap { languages(of: $0, audio: audio) })).sorted()
    }

    /// The servers carrying `language`, or all of them for nil.
    public static func filter(_ sources: [VideoSource], language: String?, audio: AudioTrack) -> [VideoSource] {
        guard let language else { return sources }
        return sources.filter { languages(of: $0, audio: audio).contains(language) }
    }

    /// The language a server names in its own title, as the Hindi and Spanish sites do.
    public static func declaredLanguage(_ provider: String) -> String? {
        guard let open = provider.lastIndex(of: "("), let close = provider.lastIndex(of: ")"), open < close else { return nil }
        return normalizeLanguage(String(provider[provider.index(after: open)..<close]))
    }

    /// Whether the downloader can save from this server: it saves streams with the subtitles in
    /// the picture, so a soft-sub server's video would arrive without them, and a web player has no
    /// stream to save at all.
    public static func canDownload(_ source: VideoSource) -> Bool {
        !source.softSub && source.kind != .embed
    }

    /// How a server carries the episode, as a person would say it (Android's `spokenLabel`).
    public static func kind(of source: VideoSource, audio: AudioTrack) -> String {
        if source.kind == .embed { return audio == .dub ? "Dubbed · web player" : "Web player" }
        if audio == .dub { return "Dubbed" }
        return source.softSub ? "Subtitles you can switch" : "Subtitles in the picture"
    }

    /// The second line of a server row: playing now, how it carries the episode, its languages,
    /// whether it can be saved, and why it failed if it did.
    public static func description(of source: VideoSource, audio: AudioTrack, playing: Bool, failure: String?) -> String {
        var parts: [String] = []
        if playing { parts.append("Playing now") }
        parts.append(kind(of: source, audio: audio))
        parts.append(languages(of: source, audio: audio).joined(separator: ", "))
        if canDownload(source) { parts.append("Can download") }
        if let failure, !playing { parts.append("Failed: \(failure)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Language names

    /// Labels that restate the sub/dub axis and name no language.
    private static let categoryLabels: Set<String> = ["sub", "dub", "subbed", "dubbed", "raw", "default", "auto", "und"]

    /// Endonyms, country codes written for language codes, and ISO 639-2 bibliographic codes that a
    /// locale lookup won't resolve (Android's `ALIASES`).
    private static let aliases: [String: String] = [
        "espanol": "Spanish", "español": "Spanish", "espanol latino": "Spanish", "español latino": "Spanish",
        "latino": "Spanish", "castellano": "Spanish",
        "sp": "Spanish", "esp": "Spanish", "la": "Spanish", "lat": "Spanish", "latam": "Spanish",
        "po": "Portuguese", "br": "Portuguese", "pob": "Portuguese", "ptb": "Portuguese",
        "jp": "Japanese", "kr": "Korean", "vn": "Vietnamese", "gr": "Greek", "cz": "Czech", "dk": "Danish",
        "ua": "Ukrainian", "se": "Swedish",
        "ger": "German", "fre": "French", "dut": "Dutch", "chi": "Chinese", "gre": "Greek", "cze": "Czech",
        "per": "Persian", "rum": "Romanian", "slo": "Slovak", "may": "Malay", "alb": "Albanian",
        "arm": "Armenian", "geo": "Georgian", "baq": "Basque", "mac": "Macedonian", "bur": "Burmese",
        "wel": "Welsh", "ice": "Icelandic", "fil": "Tagalog",
        "francais": "French", "français": "French", "deutsch": "German", "italiano": "Italian",
        "portugues": "Portuguese", "português": "Portuguese", "brazilian": "Portuguese", "brasil": "Portuguese",
        "nihongo": "Japanese", "jpn": "Japanese", "eng": "English", "filipino": "Tagalog",
        "bahasa": "Indonesian", "bahasa indonesia": "Indonesian", "farsi": "Persian",
        "cn": "Chinese", "zh": "Chinese", "mandarin": "Chinese",
    ]

    /// Decorations providers bolt onto a language name ("English Dub", "Hindi Uncut").
    private static let noise = try! NSRegularExpression(
        pattern: #"\b(dub(bed)?|sub(bed|titles?|s)?|audio|uncut|multi|hd|fhd|sd|soft|hard|cc|forced|full)\b"#,
        options: [.caseInsensitive]
    )

    /// A bare tag such as `pt-BR`, `es_419` or `zh-Hans`.
    private static let languageTag = try! NSRegularExpression(pattern: #"^([A-Za-z]{2,3})[-_][A-Za-z0-9]{2,4}$"#)

    /// The English display name for a provider's language label ("en", "pt-BR", "Español",
    /// "English Dub"), or nil when it names no language (Android's `normalizeLanguage`).
    public static func normalizeLanguage(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = languageTag.firstMatch(in: trimmed, range: whole),
           let base = Range(match.range(at: 1), in: trimmed),
           let name = languageName(String(trimmed[base]).lowercased()) {
            return name
        }
        var cleaned = noise.stringByReplacingMatches(in: trimmed, range: whole, withTemplate: " ")
        cleaned = cleaned.replacingOccurrences(of: #"[\[\](){}_/|]"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -·,."))
        let key = cleaned.lowercased()
        guard !key.isEmpty, !categoryLabels.contains(key) else { return nil }
        if let name = languageName(key) { return name }
        // Already a language name ("Japanese", "Hindi"), or one we don't know: shown as written.
        return cleaned.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func languageName(_ key: String) -> String? {
        if let alias = aliases[key] { return alias }
        guard (2...3).contains(key.count), key.allSatisfy(\.isLetter) else { return nil }
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: key)
        guard let name, !name.isEmpty, name.lowercased() != key else { return nil }
        return name
    }
}
