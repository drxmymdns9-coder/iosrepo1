import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The iOS app's update channel, after Android's `NostrUpdateSource` and `UpdateManager` and the
/// desktop app's channel: a manifest signed with the project key (kind 30078, d-tag
/// `anilili-ios-update`), mirrored as `latest/ios.json` and read from there first, with the relays
/// as the durable copy. Nothing it says is trusted until the signature checks out.
///
/// The manifest's content:
///
///     {"version":"0.0.2","build":5,"changelog":"## 📺 iPad\n- **…** …",
///      "ios":{"url":"https://…/Anilili-iOS.ipa","sizeBytes":4260492,"sha256":"…","mirrors":["https://…"]}}
///
/// iOS can't install the file itself: a sideloaded app is replaced by the tool that signed it, so
/// an update is handed to SideStore or AltStore, or downloaded for Sideloadly on a computer.
public struct AppUpdate: Equatable, Sendable, Identifiable {
    public var version: String
    /// The build number (`CFBundleVersion`); nil for a manifest that names none.
    public var build: Int?
    /// Light markdown, Android's shape: `## Heading`, `- item`, `**bold**`.
    public var changelog: String
    public var url: URL
    public var sizeBytes: Int64?
    public var sha256: String?
    /// The same file elsewhere, tried after `url`.
    public var mirrors: [URL]

    public static let dTag = "anilili-ios-update"
    /// The signed event served as a file (Android's `MANIFEST_MIRROR_URL`, desktop's `desktop.json`).
    public static let mirrorURL = URL(string: "https://huggingface.co/pommieye/kitsune-7b/resolve/main/latest/ios.json")!

    public init(version: String, build: Int?, changelog: String, url: URL, sizeBytes: Int64? = nil, sha256: String? = nil, mirrors: [URL] = []) {
        self.version = version
        self.build = build
        self.changelog = changelog
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.mirrors = mirrors
    }

    public var id: String { "\(version)-\(build ?? 0)" }

    /// Every address the file can be fetched from, preferred first.
    public var downloadURLs: [URL] {
        var seen = Set<URL>()
        return ([url] + mirrors).filter { seen.insert($0).inserted }
    }

    /// The update in a signed event, or nil when it isn't the project's or names no file.
    public static func from(event json: JSON) -> AppUpdate? {
        guard let event = NostrEvent(json: json), event.isValidSigned(dTag: dTag) else { return nil }
        return parse(event.content)
    }

    /// The manifest's content. Only plain https addresses are taken.
    public static func parse(_ content: String) -> AppUpdate? {
        guard let body = try? JSON.parse(Data(content.utf8)),
              let version = body["version"]?.string?.trimmingCharacters(in: .whitespaces), !version.isEmpty,
              let file = body["ios"], let url = https(file["url"]?.string) else { return nil }
        let build = (file["build"]?.number ?? body["build"]?.number).map { Int($0) }
        return AppUpdate(
            version: version,
            build: build,
            changelog: body["changelog"]?.string ?? "",
            url: url,
            sizeBytes: file["sizeBytes"]?.number.map { Int64($0) },
            sha256: file["sha256"]?.string,
            mirrors: (file["mirrors"]?.array ?? []).compactMap { https($0.string) }
        )
    }

    static func https(_ raw: String?) -> URL? {
        guard let raw, let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return nil }
        return components.url
    }

    // MARK: - Fetching

    /// The newest validly signed manifest: the mirror (one request), else the relays.
    public static func fetch() async throws -> AppUpdate {
        if let mirrored = await fromMirror() { return mirrored }
        let events = await AnnouncementSource.scan(dTag: dTag)
        let verified = events.compactMap { json -> (Int, AppUpdate)? in
            guard let event = NostrEvent(json: json), event.isValidSigned(dTag: dTag),
                  let update = parse(event.content) else { return nil }
            return (event.createdAt, update)
        }
        Log.info("update", "relay scan: \(events.count) events, \(verified.count) verified")
        guard let newest = verified.max(by: { $0.0 < $1.0 })?.1 else {
            throw HTTPError("No update manifest could be read from the mirror or the relays.")
        }
        return newest
    }

    static func fromMirror() async -> AppUpdate? {
        do {
            let (data, response) = try await HTTP.data(mirrorURL, headers: ["Accept": "application/json", "Cache-Control": "no-cache"])
            guard (200..<300).contains(response.statusCode) else {
                Log.info("update", "mirror answered \(response.statusCode)")
                return nil
            }
            guard let update = from(event: try JSON.parse(data)) else {
                Log.warning("update", "the mirror served a manifest that failed verification")
                return nil
            }
            return update
        } catch {
            Log.info("update", "mirror unreadable: \(Log.describe(error))")
            return nil
        }
    }
}

/// What a check does with the build it found (Android's `UpdateOffer`).
public enum UpdateOffer: Equatable, Sendable {
    /// Nothing newer.
    case none
    /// A new version: shown when the app opens.
    case prompt
    /// The same version under a higher build number: offered in Settings, never popped up.
    case quiet

    /// Android's `updateOffer`: a newer version name prompts; a higher build of the same name is a
    /// quiet rebuild; a lower build is never offered, whatever its name says.
    public static func decide(remoteVersion: String, remoteBuild: Int?, installedVersion: String, installedBuild: Int) -> UpdateOffer {
        if let remoteBuild, remoteBuild < installedBuild { return .none }
        let names = compareVersions(remoteVersion, installedVersion)
        if names > 0 { return .prompt }
        if names == 0, let remoteBuild, remoteBuild > installedBuild { return .quiet }
        return .none
    }

    /// Dotted numbers compared part by part ("0.0.10" > "0.0.9"); a leading "v" and any suffix
    /// after a number ("1.2.3-beta") are ignored.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ version: String) -> [Int] {
            let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// "v0.0.2", or "v0.0.1 (build 5)" when the build is what tells two apart (Android's `versionLabel`).
    public static func label(version: String, build: Int?) -> String {
        build.map { "v\(version) (build \($0))" } ?? "v\(version)"
    }
}

/// Release notes as blocks (Android's `parseReleaseNotes`): `## Heading` or a wholly bold line is
/// a heading, `- item` a bullet, anything else a paragraph. Bold marks stay in bullet and
/// paragraph text for the view to set.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    public static func parse(_ body: String) -> [Block] {
        body.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, line.prefix(while: { $0 == "#" }).count <= 6 { return .heading(text.replacingOccurrences(of: "**", with: "")) }
            }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"), line.count > 4 {
                let inner = line.dropFirst(2).dropLast(line.hasSuffix(":") ? 3 : 2)
                if !inner.contains("**") { return .heading(String(inner)) }
            }
            return .paragraph(line)
        }
    }
}
