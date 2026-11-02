import Foundation

/// What the on-device stream proxy does to a stream on its way to AVPlayer (the app's
/// `StreamProxy`, after Android's `LocalStreamProxy`, `HlsPlaylistRewrite` and the Kwik and
/// Flixcloud data sources). Pure functions, so they're tested here.
///
/// AVPlayer is stricter than Android's ExoPlayer in three ways these servers trip over:
///
/// - **Segments in disguise.** Several CDNs hand out MPEG-TS dressed as images: some only by
///   name and content type, others with a real PNG glued in front (Miruro's `bee · HD-1` on a
///   TikTok CDN: a 252-byte PNG, then the TS; measured 2026-10-12). ExoPlayer scans for the TS
///   sync byte; AVPlayer expects it at byte 0 and gives up.
/// - **Kwik's IVs.** Kwik's playlists leave the AES-128 IV implicit, which means the media
///   sequence number, while the segments were encrypted with the number in their file name.
/// - **Headers.** Everything is fetched with the server's own headers, playlist to segment.
public enum StreamRewrite {
    /// What a URL named inside a playlist is, which decides how the proxy treats its answer.
    public enum Role: String, Sendable, Equatable {
        /// A variant or rendition playlist: rewritten in turn.
        case playlist
        /// A media segment: unwrapped if it's in disguise.
        case segment
        /// An AES key: passed through untouched.
        case key
        /// An fMP4 initialisation section: passed through untouched.
        case map
    }

    /// Whether `head` is the start of an HLS playlist: `#EXTM3U` is mandatory as its first line,
    /// which is the only witness worth trusting when CDNs serve playlists as `text/plain` or
    /// `application/octet-stream` (a byte-order mark and blank space before it are allowed).
    public static func looksLikePlaylist(_ head: Data) -> Bool {
        var bytes = [UInt8](head.prefix(64))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x0A || first == 0x0D || first == 0x09 { bytes.removeFirst() }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    /// `playlist` with every URL it names resolved against `base` and replaced by what
    /// `register` returns for it. An unrecognised tag is copied through untouched: a line this
    /// can't parse is one AVPlayer may still need.
    public static func playlist(_ playlist: String, base: URL, register: (URL, Role) -> String) -> String {
        // "\r\n" is one Character in Swift, so it's normalised before splitting and put back after.
        let crlf = playlist.contains("\r\n")
        var lines = playlist.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var nextIsVariant = false
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("#EXT-X-STREAM-INF") { nextIsVariant = true }
                let role: Role?
                if trimmed.hasPrefix("#EXT-X-KEY") || trimmed.hasPrefix("#EXT-X-SESSION-KEY") {
                    role = .key
                } else if trimmed.hasPrefix("#EXT-X-MAP") {
                    role = .map
                } else if trimmed.hasPrefix("#EXT-X-MEDIA:") || trimmed.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                    role = .playlist
                } else {
                    role = nil
                }
                if let role { lines[index] = rewriteURIAttribute(line, base: base, role: role, register: register) }
                continue
            }
            let role: Role = nextIsVariant ? .playlist : .segment
            nextIsVariant = false
            if let url = URL(string: trimmed, relativeTo: base)?.absoluteURL, url.scheme?.hasPrefix("http") == true {
                lines[index] = register(url, role)
            }
        }
        return lines.joined(separator: crlf ? "\r\n" : "\n")
    }

    /// Swaps a tag's quoted `URI="…"`, leaving every other attribute as it was. Keys that aren't
    /// fetched over HTTP (`skd:`, `data:`) are left alone.
    static func rewriteURIAttribute(_ line: String, base: URL, role: Role, register: (URL, Role) -> String) -> String {
        guard let start = line.range(of: "URI=\""),
              let end = line.range(of: "\"", range: start.upperBound..<line.endIndex) else { return line }
        let reference = String(line[start.upperBound..<end.lowerBound])
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL, url.scheme?.hasPrefix("http") == true else { return line }
        return line.replacingCharacters(in: start.upperBound..<end.lowerBound, with: register(url, role))
    }

    /// Kwik's playlist with an explicit `IV=` per segment, or nil when it isn't Kwik's shape: AES-128
    /// with the IV left implicit, and every segment named `segment-<n>-…` (Android's
    /// `rewriteKwikPlaylistIvs`). Kwik encrypts each segment with the number in its name, and the
    /// names skip while the sequence counts, so only the first segment decrypts with the default.
    /// Writing the IV out is ordinary HLS; AVPlayer still does the AES.
    public static func explicitKwikIVs(_ playlist: String) -> String? {
        guard playlist.hasPrefix("#EXTM3U") else { return nil }
        let eol = playlist.contains("\r\n") ? "\r\n" : "\n"
        let lines = playlist.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let keyLine = lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { $0.hasPrefix("#EXT-X-KEY:") }),
              keyLine.range(of: "METHOD=AES-128", options: .caseInsensitive) != nil,
              keyLine.range(of: ",IV=", options: .caseInsensitive) == nil else { return nil }
        var numbers: [Int: UInt64] = [:]
        for (index, line) in lines.enumerated() {
            let uri = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if uri.isEmpty || uri.hasPrefix("#") { continue }
            guard let number = kwikSegmentNumber(uri) else { return nil }
            numbers[index] = number
        }
        guard !numbers.isEmpty else { return nil }
        return lines.enumerated().map { index, line in
            guard let number = numbers[index] else { return line }
            return "\(keyLine),IV=\(hlsIV(number))\(eol)\(line)"
        }.joined(separator: eol)
    }

    /// The `n` in `…/segment-n-…`, the shape every Kwik segment is named in.
    static func kwikSegmentNumber(_ uri: String) -> UInt64? {
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        guard let range = path.range(of: #"(?:^|/)segment-(\d+)-"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = path[range].drop { !$0.isNumber }.prefix { $0.isNumber }
        return UInt64(digits)
    }

    /// An IV as HLS writes it: 128 bits of big-endian hex, `0x`-prefixed.
    public static func hlsIV(_ number: UInt64) -> String {
        "0x" + String(repeating: "0", count: 16) + String(format: "%016llx", number)
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// How far into a segment a disguise is looked for. The PNGs seen are a few hundred bytes.
    public static let disguiseLimit = 64 * 1024

    /// Where the real media starts in a segment that begins with `head`: after a PNG wrapper's
    /// `IEND` chunk, or at the first run of MPEG-TS sync bytes behind other image bytes; 0 when
    /// there's nothing in front of it. Nil while more bytes are needed to decide (`complete`
    /// says there are no more).
    ///
    /// The PNG is walked chunk by chunk rather than scanned for a sync byte, so it works for an
    /// encrypted segment too, whose bytes say nothing until AVPlayer has decrypted them.
    public static func payloadOffset(_ head: [UInt8], complete: Bool) -> Int? {
        if head.count < pngSignature.count { return complete ? 0 : nil }
        if head.starts(with: pngSignature) {
            var position = pngSignature.count
            while position + 8 <= head.count {
                let length = Int(head[position]) << 24 | Int(head[position + 1]) << 16 | Int(head[position + 2]) << 8 | Int(head[position + 3])
                let type = String(decoding: head[(position + 4)..<(position + 8)], as: UTF8.self)
                let next = position + 12 + length
                if type == "IEND" { return next <= head.count || complete ? min(next, head.count) : nil }
                guard length >= 0, next < disguiseLimit else { break }
                position = next
            }
            if position + 8 > head.count, !complete, head.count < disguiseLimit { return nil }
            return tsSync(head) ?? 0
        }
        if head[0] == 0x47 { return 0 }
        // Other image bytes in front (a JPEG's FF D8, say): the first run of TS sync bytes.
        let imageLike = head.starts(with: [0xFF, 0xD8]) || head.starts(with: Array("GIF8".utf8)) || head.starts(with: Array("RIFF".utf8))
        guard imageLike else { return 0 }
        if let sync = tsSync(head) { return sync }
        return complete || head.count >= disguiseLimit ? 0 : nil
    }

    /// The first offset with MPEG-TS sync bytes 188 apart three times running.
    static func tsSync(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > 376 else { return nil }
        for index in 0..<(bytes.count - 376) where bytes[index] == 0x47 && bytes[index + 188] == 0x47 && bytes[index + 376] == 0x47 {
            return index
        }
        return nil
    }
}

extension StreamRewrite {
    /// `playlist` without the subtitle renditions whose URI is a plain subtitle file instead of a
    /// playlist, and without the `SUBTITLES=` group references they leave empty. Hentai Haven's
    /// octopus masters list their WebVTT files that way (2026-10-16): ExoPlayer loads them, AVPlayer
    /// expects a playlist there, and a variant naming a group with no renditions makes the whole
    /// master invalid. The provider offers the same files as sideloaded tracks instead.
    public static func droppingFileSubtitles(_ playlist: String) -> String {
        guard playlist.contains("TYPE=SUBTITLES") else { return playlist }
        let crlf = playlist.contains("\r\n")
        var lines = playlist.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var emptied = Set<String>(), kept = Set<String>()
        lines.removeAll { line in
            guard line.hasPrefix("#EXT-X-MEDIA:") else { return false }
            let attributes = attributes(line)
            guard attributes["TYPE"] == "SUBTITLES", let group = attributes["GROUP-ID"] else { return false }
            if let uri = attributes["URI"], isSubtitleFile(uri) {
                emptied.insert(group)
                return true
            }
            kept.insert(group)
            return false
        }
        guard !emptied.isEmpty else { return playlist }
        let orphaned = emptied.subtracting(kept)
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            for group in orphaned {
                for form in [",SUBTITLES=\"\(group)\"", "SUBTITLES=\"\(group)\","] {
                    lines[index] = lines[index].replacingOccurrences(of: form, with: "")
                }
            }
        }
        return lines.joined(separator: crlf ? "\r\n" : "\n")
    }

    /// Whether a rendition URI names a subtitle file itself (`s/en.vtt`) rather than a playlist.
    public static func isSubtitleFile(_ uri: String) -> Bool {
        let path = (uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri).lowercased()
        return [".vtt", ".webvtt", ".srt", ".ass", ".ssa"].contains { path.hasSuffix($0) }
    }

    /// A tag's attribute list (`#EXT-X-MEDIA:TYPE=AUDIO,URI="a,b.m3u8"`), quotes removed; commas
    /// inside quotes don't split.
    public static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""; value = ""; inKey = true
        }
        for character in line[line.index(after: colon)...] {
            if quoted {
                if character == "\"" { quoted = false } else { value.append(character) }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                flush()
            } else if inKey, character == "=" {
                inKey = false
            } else if inKey {
                key.append(character)
            } else {
                value.append(character)
            }
        }
        flush()
        return result
    }
}
