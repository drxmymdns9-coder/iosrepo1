import Foundation

/// Intro and outro windows when the episode list didn't carry them: the media index's mirror of
/// AniSkip first (`skip/{id/1000}/{id}.json`), then AniSkip itself by MAL id. A port of the
/// desktop's `aniskip.rs` without its relation-rule redirects.
public actor SkipTimesService {
    public static let shared = SkipTimesService()

    typealias Fetch = @Sendable (URL) async throws -> Data?

    private let fetch: Fetch
    private var mirrors: [Int: JSON?] = [:]

    public init() {
        fetch = { url in
            let (data, response) = try await HTTP.data(url, headers: ["Accept": "application/json"])
            if response.statusCode == 404 { return nil }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPError(status: response.statusCode, "Skip times answered HTTP \(response.statusCode)")
            }
            return data
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// The windows for `episode`, matched to the playing file's `length` (submissions from a cut
    /// of a different length are off by the difference).
    public func skipTimes(anilistID: Int, malID: Int?, episode: Int, length: Double) async -> SkipTimes? {
        if let found = await fromMirror(anilistID, episode: episode, length: length) {
            Log.info("skip", "\(anilistID) ep \(episode): from the media index")
            return found
        }
        guard let malID else { return nil }
        let types = ["op", "ed", "mixed-op", "mixed-ed", "recap"].map { "types%5B%5D=\($0)" }.joined(separator: "&")
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)?\(types)&episodeLength=\(Int(length))"),
              let data = try? await fetch(url), let body = try? JSON.parse(data), body["found"]?.bool == true else { return nil }
        let segments: [(kind: String, window: SkipTimes.Window, length: Double?)] = (body["results"]?.array ?? []).compactMap { row in
            guard let kind = row["skipType"]?.string, let start = row["interval"]?["startTime"]?.number,
                  let end = row["interval"]?["endTime"]?.number, end > start else { return nil }
            return (kind, .init(start: start, end: end), row["episodeLength"]?.number)
        }
        let found = Self.pick(segments, length: length)
        if found != nil { Log.info("skip", "\(anilistID) ep \(episode): from AniSkip") }
        return found
    }

    private func fromMirror(_ anilistID: Int, episode: Int, length: Double) async -> SkipTimes? {
        if mirrors[anilistID] == nil {
            let url = URL(string: "\(MediaIndex.base)/skip/\(anilistID / 1000)/\(anilistID).json")
            let data = url == nil ? nil : (try? await fetch(url!)) ?? nil
            mirrors[anilistID] = data.flatMap { try? JSON.parse($0) }
        }
        guard let mirror = mirrors[anilistID] ?? nil else { return nil }
        let rows = mirror["episodes"]?["\(episode)"]?.array ?? []
        let segments: [(kind: String, window: SkipTimes.Window, length: Double?)] = rows.compactMap { row in
            guard let fields = row.array, fields.count >= 3, let kind = fields[0].string,
                  let start = fields[1].number, let end = fields[2].number, end > start else { return nil }
            return (kind, .init(start: start, end: end), fields.count > 3 ? fields[3].number : nil)
        }
        return Self.pick(segments, length: length)
    }

    /// The plain kind over the mixed one, and of each the submission whose episode length is
    /// closest to the file's.
    static func pick(_ segments: [(kind: String, window: SkipTimes.Window, length: Double?)], length: Double) -> SkipTimes? {
        func best(_ primary: String, _ fallback: String) -> SkipTimes.Window? {
            let matching = segments.filter { $0.kind == primary }
            let candidates = matching.isEmpty ? segments.filter { $0.kind == fallback } : matching
            return candidates.min { a, b in
                let offA = length <= 0 ? 0 : a.length.map { abs($0 - length) } ?? .greatestFiniteMagnitude
                let offB = length <= 0 ? 0 : b.length.map { abs($0 - length) } ?? .greatestFiniteMagnitude
                return offA < offB
            }?.window
        }
        let skip = SkipTimes(intro: best("op", "mixed-op"), outro: best("ed", "mixed-ed"))
        return skip.intro == nil && skip.outro == nil ? nil : skip
    }
}
