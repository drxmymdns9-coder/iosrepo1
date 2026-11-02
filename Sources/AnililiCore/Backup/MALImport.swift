import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads a MyAnimeList XML export (Android's `MalImport`): the file MAL's own export page gives,
/// gzipped or not. The titles are then matched to AniList by MAL id and saved to the watchlist.
public enum MALImport {
    /// One `<anime>` entry.
    public struct Entry: Equatable, Sendable {
        public var malID: Int
        public var title: String
        public var watchedEpisodes: Int
        public var status: String
    }

    /// What an import did, for the line under the row.
    public struct Summary: Equatable, Sendable {
        public var total: Int
        public var added: Int
        public var alreadySaved: Int
        public var unmatched: Int

        public init(total: Int, added: Int, alreadySaved: Int, unmatched: Int) {
            self.total = total
            self.added = added
            self.alreadySaved = alreadySaved
            self.unmatched = unmatched
        }

        /// Android's wording.
        public var text: String {
            var line = "Imported \(added) new anime"
            if alreadySaved > 0 { line += "; \(alreadySaved) already saved" }
            if unmatched > 0 { line += "; \(unmatched) not found on AniList" }
            return line
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case tooLarge
        case expandedTooLarge
        case unsafe
        case notAnExport
        case empty

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "The MAL export is larger than the 16 MB safety limit."
            case .expandedTooLarge: return "The expanded MAL export is larger than the 32 MB safety limit."
            case .unsafe: return "MyAnimeList exports with document type or entity declarations are not supported."
            case .notAnExport: return "That file isn't a MyAnimeList export."
            case .empty: return "That MyAnimeList export lists no anime."
            }
        }
    }

    public static let maxSourceBytes = 16 * 1024 * 1024
    public static let maxExpandedBytes = 32 * 1024 * 1024

    /// The entries of an export, one per MAL id; entries without a usable id are skipped.
    public static func parse(_ data: Data) throws -> [Entry] {
        guard data.count <= maxSourceBytes else { throw Failure.tooLarge }
        let xml: Data
        if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            xml = try Gzip.decompress(data)
            guard xml.count <= maxExpandedBytes else { throw Failure.expandedTooLarge }
        } else {
            xml = data
        }
        // The file comes from outside the app: refuse declarations outright rather than trust a
        // parser setting, and refuse NUL-carrying encodings that could hide them from this scan.
        guard !xml.contains(0) else { throw Failure.unsafe }
        let markup = String(decoding: xml, as: UTF8.self).uppercased()
        guard !markup.contains("<!DOCTYPE"), !markup.contains("<!ENTITY") else { throw Failure.unsafe }

        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.root == "myanimelist" else { throw Failure.notAnExport }
        var seen = Set<Int>()
        return reader.entries.filter { seen.insert($0.malID).inserted }
    }

    /// Old exports and some third-party tools write the numeric codes.
    static func normaliseStatus(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "") {
        case "watching", "1": return "Watching"
        case "completed", "2": return "Completed"
        case "on-hold", "onhold", "3": return "On-Hold"
        case "dropped", "4": return "Dropped"
        default: return "Plan to Watch"
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?
        var entries: [Entry] = []
        private var fields: [String: String]?
        private var element: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if root == nil { root = name }
            if name == "anime" {
                fields = [:]
            } else if fields != nil {
                element = name
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if element != nil { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if element != nil { text += String(decoding: block, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "anime", let fields {
                if let id = fields["series_animedb_id"].flatMap(Int.init), id > 0 {
                    entries.append(Entry(
                        malID: id,
                        title: fields["series_title"] ?? "",
                        watchedEpisodes: max(0, fields["my_watched_episodes"].flatMap(Int.init) ?? 0),
                        status: MALImport.normaliseStatus(fields["my_status"])
                    ))
                }
                self.fields = nil
            } else if name == element {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, fields?[name] == nil { fields?[name] = value }
                element = nil
            }
        }
    }
}
