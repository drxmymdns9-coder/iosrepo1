#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A Nostr event (NIP-01), as the project publishes its update manifest and announcements:
/// addressable kind 30078 under one key, told apart by the `d` tag.
public struct NostrEvent: Sendable, Equatable {
    public var id: String
    public var pubkey: String
    public var createdAt: Int
    public var kind: Int
    public var tags: [[String]]
    public var content: String
    public var sig: String

    /// The project's key and kind (Android's `NostrUpdateSource`).
    public static let projectPubkey = "f1abd1ac685aed1f5145271283cd9418bf13aa92ed26399df191ae0c08b22207"
    public static let projectKind = 30078

    public init?(json: JSON) {
        guard let id = json["id"]?.string, let pubkey = json["pubkey"]?.string,
              let created = json["created_at"]?.number, let kind = json["kind"]?.number else { return nil }
        self.id = id
        self.pubkey = pubkey
        createdAt = Int(created)
        self.kind = Int(kind)
        tags = (json["tags"]?.array ?? []).map { tag in
            (tag.array ?? []).compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        }
        if case .string(let text)? = json["content"] { content = text } else { content = "" }
        if case .string(let text)? = json["sig"] { sig = text } else { sig = "" }
    }

    /// Full verification (Android's `isValidSignedBy`): the key, kind and channel, the id as the
    /// hash of the event, and the Schnorr signature over that id. A relay or mirror can withhold
    /// or replay an event, never write one.
    public func isValidSigned(by pubkey: String = projectPubkey, kind: Int = projectKind, dTag: String) -> Bool {
        guard self.pubkey.lowercased() == pubkey.lowercased(), self.kind == kind else { return false }
        guard tags.contains(where: { $0.count >= 2 && $0[0] == "d" && $0[1] == dTag }) else { return false }
        let expected = computedID
        guard expected == id.lowercased() else {
            Log.warning("announce", "event rejected (\(dTag)): id doesn't match its contents")
            return false
        }
        guard let signature = Self.bytes(sig), let message = Self.bytes(expected), let key = Self.bytes(self.pubkey) else { return false }
        let valid = Schnorr.verify(signature: signature, message: message, publicKey: key)
        if !valid { Log.warning("announce", "event rejected (\(dTag)): bad signature") }
        return valid
    }

    /// NIP-01: sha256 of the compact JSON `[0, pubkey, created_at, kind, tags, content]`.
    public var computedID: String {
        let tagText = "[" + tags.map { "[" + $0.map(Self.quote).joined(separator: ",") + "]" }.joined(separator: ",") + "]"
        let preimage = "[0,\(Self.quote(pubkey)),\(createdAt),\(kind),\(tagText),\(Self.quote(content))]"
        return SHA256.hash(data: Data(preimage.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// NIP-01's string escaping: the short escapes, other control characters as \u00XX, and
    /// everything else (slashes, non-ASCII) as itself.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func bytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

/// A message the project can push to every install without shipping a build (Android's
/// `Announcement`), carried by a signed Nostr event on the `anilili-announcement` channel.
public struct Announcement: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var message: String
    /// Plain https with a host, or nil.
    public var url: String?
    public var urlLabel: String?
    public var urgent: Bool
    /// Unix seconds after which it's ignored; 0 never expires.
    public var expiresAt: Int
    public var minVersion: String?
    public var maxVersion: String?

    public static let dTag = "anilili-announcement"
    /// The same signed event served as a file (Android's `MIRROR_URL`).
    public static let mirrorURL = URL(string: "https://huggingface.co/pommieye/kitsune-7b/resolve/main/latest/announcement.json")!

    /// The announcement in a signed event, or nil when the event isn't the project's or says nothing.
    public static func from(event: JSON) -> Announcement? {
        guard let event = NostrEvent(json: event), event.isValidSigned(dTag: dTag) else { return nil }
        return parse(event.content)
    }

    /// Android's `parseAnnouncement`.
    public static func parse(_ content: String) -> Announcement? {
        guard let body = try? JSON.parse(Data(content.utf8)),
              let id = body["id"]?.string, let message = body["message"]?.string else { return nil }
        func text(_ key: String) -> String? {
            switch body[key] {
            case .string(let value)?: return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
            case .number(let value)?: return String(Int(value))
            default: return nil
            }
        }
        return Announcement(
            id: id, title: text("title") ?? "Anilili", message: message, url: sanitize(text("url")), urlLabel: text("urlLabel"),
            urgent: text("severity")?.lowercased() == "emergency",
            expiresAt: text("expiresAt").flatMap { Int($0) } ?? 0,
            minVersion: text("minVersion"), maxVersion: text("maxVersion")
        )
    }

    /// Only plain https links with a host survive.
    static func sanitize(_ raw: String?) -> String? {
        guard let candidate = raw?.trimmingCharacters(in: .whitespaces), !candidate.isEmpty,
              let components = URLComponents(string: candidate), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return candidate
    }

    /// Whether this device shows it. Android's version bounds name Android builds ("0.1.76 is
    /// broken, stay on 0.1.75"), which mean nothing for the iOS app, so a bounded announcement is
    /// left to the devices it's about.
    public func applies(now: Int) -> Bool {
        if expiresAt > 0 && expiresAt < now { return false }
        return minVersion == nil && maxVersion == nil
    }
}
