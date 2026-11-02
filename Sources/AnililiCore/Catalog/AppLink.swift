import Foundation

/// `anilili://` links, as written down in the desktop's `docs/LINKS.md` and read by its
/// `links.rs`; `Tests/AnililiCoreTests/Fixtures/parity/links.json` holds the cases every app
/// must answer alike.
///
/// ```text
/// anilili://anime/<anilist id>                        the title's page
/// anilili://watch/<anilist id>/<episode>[?t=<secs>]   play an episode, from `t` if given
/// anilili://search?q=<text>                           search
/// ```
///
/// Parsed by hand rather than through `URL`, whose handling of `anilili:anime/1` and friends
/// differs between Apple's Foundation and Linux's.
public enum AppLink: Equatable, Sendable {
    case anime(id: Int)
    case watch(id: Int, episode: Double, start: Double?)
    case search(query: String)

    public static let scheme = "anilili"

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(Self.scheme + ":") else { return nil }
        let rest = trimmed.dropFirst(Self.scheme.count + 1)
        let pathPart: Substring
        let queryPart: Substring?
        if let mark = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            pathPart = rest[..<mark]
            queryPart = rest[mark] == "?" ? rest[rest.index(after: mark)...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first : nil
        } else {
            pathPart = rest
            queryPart = nil
        }
        let parts = pathPart.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let query = Self.queryItems(queryPart.map(String.init) ?? "")
        func id(_ text: String) -> Int? { Int(text).flatMap { $0 > 0 ? $0 : nil } }

        switch parts.first {
        case "anime" where parts.count == 2:
            guard let id = id(parts[1]) else { return nil }
            self = .anime(id: id)
        case "watch" where parts.count == 3:
            guard let id = id(parts[1]), let episode = Double(parts[2]), episode.isFinite, episode >= 0 else { return nil }
            let start = query["t"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self = .watch(id: id, episode: episode, start: start)
        case "search" where parts.count == 1:
            guard let text = query["q"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            self = .search(query: text)
        default:
            return nil
        }
    }

    /// The canonical form.
    public var url: String {
        switch self {
        case .anime(let id):
            return "\(Self.scheme)://anime/\(id)"
        case .watch(let id, let episode, let start):
            let base = "\(Self.scheme)://watch/\(id)/\(Self.number(episode))"
            return start.map { "\(base)?t=\(Int($0.rounded(.down)))" } ?? base
        case .search(let query):
            return "\(Self.scheme)://search?q=\(Self.formEncode(query))"
        }
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// `application/x-www-form-urlencoded`, as the url crate's `append_pair` writes it.
    static func formEncode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                out.append(Character(Unicode.Scalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (text: Substring) in
                String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(text)
            }
            let key = decode(halves[0])
            if items[key] == nil { items[key] = halves.count > 1 ? decode(halves[1]) : "" }
        }
        return items
    }
}
