import Foundation

/// One subtitle line on screen, from `start` to `end` seconds.
public struct SubtitleCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// WebVTT and SRT, parsed for the player's own subtitle layer: AVPlayer can't side-load a
/// subtitle file into an HLS stream, so soft-sub servers are drawn over the video by the app.
public enum Subtitles {
    private static let timing = Pattern("((?:\\d+:)?\\d{1,2}:\\d{2}[.,]\\d{1,3})\\s*-->\\s*((?:\\d+:)?\\d{1,2}:\\d{2}[.,]\\d{1,3})")
    /// Ruby annotations (`<rt>`) are furigana or watermarks; the base text is what's read.
    private static let rubyText = Pattern("<rt>.*?</rt>", dotAll: true)
    private static let tag = Pattern("</?[a-z][^>]*>|\\{\\\\[^}]*\\}")

    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.range(of: #"(?m)^\[Events\]"#, options: .regularExpression) != nil || normalized.range(of: #"(?m)^Dialogue:"#, options: .regularExpression) != nil {
            return parseASS(normalized)
        }
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let match = timing.firstMatch(in: lines[timingIndex]),
                  let start = match[1].flatMap(seconds), let end = match[2].flatMap(seconds), end > start else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            let clean = clean(body)
            if !clean.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// SubStation Alpha (`.ass`/`.ssa`), the format AniZone and AnimeOnsen publish, read for its
    /// words: each `Dialogue:` line's times and text, by the `Format:` line's field order, with
    /// override tags (`{\i1}`) dropped, `\N` as a line break and vector drawings (`{\p1}`) left
    /// out. The styling isn't drawn; the app's own caption style is.
    static func parseASS(_ text: String) -> [SubtitleCue] {
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [SubtitleCue] = []
        var inEvents = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            if inEvents, trimmed.lowercased().hasPrefix("format:") {
                fields = trimmed.dropFirst("format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard trimmed.hasPrefix("Dialogue:") else { continue }
            // The text is the last field and may itself hold commas.
            let values = trimmed.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: max(0, fields.count - 1), omittingEmptySubsequences: false)
                .map { String($0) }
            guard values.count == fields.count,
                  let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text"),
                  let start = seconds(values[startIndex].trimmingCharacters(in: .whitespaces)),
                  let end = seconds(values[endIndex].trimmingCharacters(in: .whitespaces)), end > start else { continue }
            let raw = values[textIndex]
            if raw.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { continue }
            let words = raw.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: words)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `01:02:03.456`, `02:03.456` or SRT's `01:02:03,456` in seconds.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let last = Double(parts.last!) else { return nil }
        let units = parts.dropLast().compactMap { Double($0) }
        guard units.count == parts.count - 1 else { return nil }
        return units.reduce(0) { $0 * 60 + $1 } * 60 + last
    }

    static func clean(_ text: String) -> String {
        let withoutRuby = rubyText.replacing(in: text, with: "")
        let withoutTags = tag.replacing(in: withoutRuby, with: "")
        return HTML.decodeEntities(withoutTags)
            .replacingOccurrences(of: "\\N", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The cues showing at `time` (after `delay`), joined, or nil.
    public static func text(at time: Double, in cues: [SubtitleCue], delay: Double = 0) -> String? {
        let t = time - delay
        // Cues are sorted by start; anything starting after `t` can't be showing.
        var lines: [String] = []
        for cue in cues {
            if cue.start > t { break }
            if t < cue.end { lines.append(cue.text) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Downloads and parses a track with the server's headers (most subtitle hosts refuse a bare
    /// request, as their video CDNs do).
    public static func load(_ track: SubtitleTrack, headers: [String: String]) async throws -> [SubtitleCue] {
        if track.url.isFileURL {
            let text = try String(contentsOf: track.url, encoding: .utf8)
            let cues = parse(text)
            Log.info("subtitles", "\(track.label): \(cues.count) local cues")
            return cues
        }
        var all = headers
        all["User-Agent"] = all["User-Agent"] ?? HTTP.safariUserAgent
        let text = try await HTTP.text(track.url, headers: all)
        let cues = parse(text)
        Log.info("subtitles", "\(track.label): \(cues.count) cues from \(track.url.host ?? "?")")
        return cues
    }
}

/// An HLS master playlist's variants, for the player's quality menu.
public enum HLSPlaylist {
    public struct Variant: Hashable, Sendable {
        public var bandwidth: Int
        public var width: Int?
        public var height: Int?
        public var label: String { height.map { "\($0)p" } ?? "\(bandwidth / 1000) kbps" }
    }

    private static let attribute = Pattern("([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)", caseInsensitive: false)

    /// The `#EXT-X-STREAM-INF` entries, best first; empty for a media playlist.
    public static func variants(_ text: String) -> [Variant] {
        var variants: [Variant] = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let attributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            var bandwidth = 0
            var width: Int?
            var height: Int?
            for match in attribute.matches(in: attributes) {
                guard let key = match[1], let value = match[2] else { continue }
                switch key {
                case "BANDWIDTH": bandwidth = Int(value) ?? 0
                case "RESOLUTION":
                    let size = value.split(separator: "x").compactMap { Int($0) }
                    if size.count == 2 { (width, height) = (size[0], size[1]) }
                default: break
                }
            }
            variants.append(Variant(bandwidth: bandwidth, width: width, height: height))
        }
        var seen = Set<String>()
        return variants
            .sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) }
            .filter { seen.insert($0.label).inserted }
    }

    public static func load(_ url: URL, headers: [String: String]) async throws -> [Variant] {
        var all = headers
        all["User-Agent"] = all["User-Agent"] ?? HTTP.safariUserAgent
        return variants(try await HTTP.text(url, headers: all))
    }
}
