import Foundation

/// What saving an HLS episode needs: the variant to keep, and the media playlist rewritten so
/// every segment, key and init section is a file beside it. Encryption is left as it is (the
/// key is saved too); the app serves the folder from 127.0.0.1 to play it, because AVFoundation's
/// own HLS downloader doesn't run in the Simulator and won't keep AES-128 keys for offline use.
///
/// The local server hands the files over as they are, so what `StreamProxy` fixes on the way to
/// the player is fixed here at save time instead: Kwik's implicit IVs are written out before the
/// segments lose the names they come from, and disguised segments are saved unwrapped.
///
/// What the local server serves is never checked again on the way to AVPlayer, so a segment is
/// checked when it's saved (`isMedia`): a CDN that answers 200 with an error page or a
/// placeholder image would otherwise leave a copy that plays up to that segment and stops there.
public enum HLSDownload {
    /// One file to fetch and the name it's saved under.
    public struct File: Equatable, Sendable {
        public var remote: URL
        public var local: String
        /// A media segment, which may come dressed as an image (`unwrap`); keys and init
        /// sections are saved as they come.
        public var isSegment = false
        /// A segment under an AES-128 key, whose bytes say nothing until AVPlayer decrypts them.
        public var encrypted = false
    }

    public struct Plan: Equatable, Sendable {
        /// The playlist to save as `index.m3u8`.
        public var playlist: String
        public var files: [File]
        /// Seconds of video, from the segment durations.
        public var duration: Double
    }

    static let mediaExtensions: Set<String> = ["ts", "m4s", "mp4", "m4v", "aac", "m4a", "mp3", "vtt"]

    private static let uriAttribute = Pattern(#"URI="([^"]*)""#, caseInsensitive: false)
    private static let streamAttribute = Pattern("([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)", caseInsensitive: false)

    /// The variant URL to download from a master playlist: the tallest at or under `maxHeight`
    /// (the smallest when none is), the highest bandwidth breaking ties. Nil for a media playlist.
    public static func variant(in master: String, base: URL, maxHeight: Int?) -> URL? {
        struct Option { var url: URL; var height: Int; var bandwidth: Int }
        var options: [Option] = []
        var pending: (height: Int, bandwidth: Int)?
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                var height = 0
                var bandwidth = 0
                for match in streamAttribute.matches(in: String(line.dropFirst("#EXT-X-STREAM-INF:".count))) {
                    guard let key = match[1], let value = match[2] else { continue }
                    if key == "BANDWIDTH" { bandwidth = Int(value) ?? 0 }
                    if key == "RESOLUTION" { height = Int(value.split(separator: "x").last ?? "") ?? 0 }
                }
                pending = (height, bandwidth)
            } else if let attributes = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    options.append(Option(url: url, height: attributes.height, bandwidth: attributes.bandwidth))
                }
                pending = nil
            }
        }
        guard !options.isEmpty else { return nil }
        let order: (Option, Option) -> Bool = { ($0.height, $0.bandwidth) > ($1.height, $1.bandwidth) }
        if let maxHeight, let fitting = options.filter({ $0.height > 0 && $0.height <= maxHeight }).sorted(by: order).first {
            return fitting.url
        }
        if maxHeight != nil { return options.sorted(by: order).last?.url }
        return options.sorted(by: order).first?.url
    }

    /// The media playlist with every URI made local, and the files to fetch for it.
    public static func plan(_ playlist: String, base: URL) -> Plan {
        plan(playlist, base: base, prefix: "s")
    }

    /// As `plan`, but with a distinct file prefix. A master playlist can reference separate video
    /// and audio media playlists; their segment names must not collide in the same download folder.
    public static func plan(_ playlist: String, base: URL, prefix: String) -> Plan {
        // Kwik's IVs come from the numbers in its segment names, which the local names drop: a
        // copy saved without them decrypts every segment but the first wrongly, so playing it from
        // anywhere but 0:00 finds no tracks and "ends" at once (One Piece 208, 2026-10-12).
        let media = StreamRewrite.explicitKwikIVs(playlist) ?? playlist
        var lines: [String] = []
        var files: [File] = []
        var known: [URL: String] = [:]
        var segments = 0
        var keys = 0
        var maps = 0
        var duration = 0.0
        var encrypted = false

        func local(_ uri: String, prefix: String, counter: inout Int, fallbackExtension: String, isSegment: Bool = false) -> String? {
            guard let url = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
            if let name = known[url] { return name }
            // Only real media extensions are kept: Miruro's servers dress segments up as .jpg/.png,
            // and the local server picks the Content-Type from the name.
            let ext = url.pathExtension.lowercased()
            let safe = mediaExtensions.contains(ext) ? ext : fallbackExtension
            let name = "\(prefix)\(String(format: "%05d", counter)).\(safe)"
            counter += 1
            known[url] = name
            files.append(File(remote: url, local: name, isSegment: isSegment, encrypted: isSegment && encrypted))
            return name
        }

        for raw in media.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-MAP:") {
                let isKey = line.hasPrefix("#EXT-X-KEY:")
                if isKey { encrypted = line.range(of: "METHOD=AES-128", options: .caseInsensitive) != nil }
                if let match = uriAttribute.firstMatch(in: line), let uri = match[1],
                   let name = isKey ? local(uri, prefix: prefix == "s" ? "key" : "\(prefix)key", counter: &keys, fallbackExtension: "bin")
                                    : local(uri, prefix: prefix == "s" ? "init" : "\(prefix)init", counter: &maps, fallbackExtension: "mp4") {
                    lines.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(name)\""))
                } else {
                    lines.append(line)
                }
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
                duration += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                lines.append(line)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                lines.append(local(line, prefix: prefix, counter: &segments, fallbackExtension: "ts", isSegment: true) ?? line)
            } else {
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if !lines.contains(where: { $0.hasPrefix("#EXT-X-ENDLIST") }) { lines.append("#EXT-X-ENDLIST") }
        return Plan(playlist: lines.joined(separator: "\n") + "\n", files: files, duration: duration)
    }

    /// How many bytes from the start of a segment `isMedia` looks at.
    public static let mediaCheckLength = 512

    /// Whether a saved segment, `size` bytes long and starting with `head`, is media rather than
    /// what a CDN answers 200 with when it won't hand the segment over (an HTML or JSON error, a
    /// placeholder image). AVPlayer gives up on such a segment with CoreMedia's `'fmt?'`, and a copy
    /// holding one stops there every time it's played (a saved knob · Vidplay episode, 2026-10-12).
    ///
    /// Unencrypted: MPEG-TS sync bytes, an ID3 tag, an fMP4 box, ADTS or MP3 audio, or WebVTT.
    /// AES-128: only the length can be checked, a whole number of 16-byte blocks.
    public static func isMedia(_ head: [UInt8], size: Int, encrypted: Bool) -> Bool {
        guard size > 0, !head.isEmpty else { return false }
        if encrypted { return size >= 16 && size % 16 == 0 }
        // A GIF starts with "G" too.
        if head[0] == 0x47, !head.starts(with: Array("GIF8".utf8)) {
            return head.count > 188 ? head[188] == 0x47 : size % 188 == 0
        }
        if head.starts(with: Array("ID3".utf8)) || head.starts(with: Array("WEBVTT".utf8)) { return true }
        if head.count >= 8, ["ftyp", "styp", "moof", "sidx", "emsg", "prft", "free", "mdat"].contains(String(decoding: head[4..<8], as: UTF8.self)) {
            return true
        }
        // ADTS AAC and MPEG audio frames both start with an 11-bit frame sync.
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return true }
        return false
    }

    /// The segments of the copy saved in `folder` that are missing or aren't media, by file name,
    /// read from its `index.m3u8`. Empty when there's no playlist to go by.
    public static func damagedSegments(in folder: URL) -> [String] {
        let index = folder.appendingPathComponent("index.m3u8")
        guard let playlist = try? String(contentsOf: index, encoding: .utf8) else { return [] }
        return plan(playlist, base: index).files.filter(\.isSegment).compactMap { file in
            let name = file.remote.lastPathComponent
            let url = folder.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return name }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: mediaCheckLength)) ?? Data()
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            return isMedia([UInt8](head), size: size, encrypted: file.encrypted) ? nil : name
        }
    }

    /// A downloaded segment without the image glued in front of it, if it has one.
    public static func unwrap(_ segment: Data) -> Data {
        let offset = StreamRewrite.payloadOffset([UInt8](segment.prefix(StreamRewrite.disguiseLimit)), complete: true) ?? 0
        return offset > 0 ? segment.subdata(in: (segment.startIndex + offset)..<segment.endIndex) : segment
    }
}
