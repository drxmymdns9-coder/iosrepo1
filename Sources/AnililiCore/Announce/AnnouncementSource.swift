import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where announcements come from (Android's `AnnouncementSource`): the mirrored file first, one
/// request, then the Nostr relays, which are the durable copy: the emergency worth announcing may
/// be the mirror's host going away. Nothing either answers is trusted until its signature checks
/// out against the project key.
public enum AnnouncementSource {
    static let relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.nostr.band", "wss://relay.primal.net"]
    static let perRelayTimeout: Duration = .seconds(8)

    /// The newest validly signed announcement, or nil (the usual answer: most of the time there's
    /// nothing published).
    public static func fetch() async -> Announcement? {
        if let mirrored = await fromMirror() { return mirrored }
        return await fromRelays()
    }

    static func fromMirror() async -> Announcement? {
        do {
            let (data, response) = try await HTTP.data(Announcement.mirrorURL, headers: ["Accept": "application/json"])
            // 404 is "nothing published", the resting state of this channel.
            guard (200..<300).contains(response.statusCode) else { return nil }
            let event = try JSON.parse(data)
            guard let announcement = Announcement.from(event: event) else {
                Log.warning("announce", "the mirror served an event that failed verification")
                return nil
            }
            return announcement
        } catch {
            Log.debug("announce", "mirror unreadable: \(Log.describe(error))")
            return nil
        }
    }

    static func fromRelays() async -> Announcement? {
        let events = await scan(dTag: Announcement.dTag)
        let verified = events.compactMap { json -> (Int, Announcement)? in
            guard let event = NostrEvent(json: json), event.isValidSigned(dTag: Announcement.dTag),
                  let announcement = Announcement.parse(event.content) else { return nil }
            return (event.createdAt, announcement)
        }
        Log.info("announce", "relay scan: \(events.count) events, \(verified.count) verified")
        return verified.max { $0.0 < $1.0 }?.1
    }

    /// Every relay's events for one channel of the project's key, asked together.
    static func scan(dTag: String) async -> [JSON] {
        await withTaskGroup(of: [JSON].self) { group in
            for relay in relays {
                group.addTask { await query(relay, dTag: dTag) }
            }
            var all: [JSON] = []
            for await found in group { all += found }
            return all
        }
    }

    /// One relay's events for the channel, until it says it has sent them all (EOSE) or times out.
    static func query(_ address: String, dTag: String) async -> [JSON] {
        guard let url = URL(string: address) else { return [] }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let request = """
        ["REQ","\(dTag)",{"kinds":[\(NostrEvent.projectKind)],"authors":["\(NostrEvent.projectPubkey)"],"#d":["\(dTag)"],"limit":3}]
        """
        do {
            try await task.send(.string(request))
            return try await withThrowingTaskGroup(of: [JSON].self) { group in
                group.addTask {
                    var events: [JSON] = []
                    while true {
                        guard case .string(let text) = try await task.receive(),
                              case .array(let message)? = try? JSON.parse(Data(text.utf8)),
                              case .string(let type)? = message.first else { continue }
                        if type == "EVENT", message.count > 2 { events.append(message[2]) }
                        if type == "EOSE" || type == "CLOSED" {
                            if type == "CLOSED" { Log.info("announce", "relay \(address) closed the request: \(text.prefix(160))") }
                            return events
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: perRelayTimeout)
                    return []
                }
                let first = try await group.next() ?? []
                group.cancelAll()
                return first
            }
        } catch {
            Log.warning("announce", "relay \(address) failed: \(Log.describe(error))")
            return []
        }
    }
}
