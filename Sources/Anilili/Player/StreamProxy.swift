#if canImport(UIKit)
import AnililiCore
import Foundation
import Network

/// A loopback HTTP proxy between AVPlayer and a server's HLS (after Android's `LocalStreamProxy`
/// and the data sources it stacks on Media3). AVPlayer is handed `http://127.0.0.1:<port>/<token>`
/// and this makes the real request, so that:
///
/// - every request (playlist, variant, key, segment) carries the server's own headers, not just
///   the ones AVFoundation chooses to pass on;
/// - playlists come back rewritten so their segments and keys come here too, with Kwik's
///   implicit IVs written out (`StreamRewrite.explicitKwikIVs`);
/// - segments in disguise (a PNG glued in front, an image content type) reach AVPlayer as the
///   MPEG-TS they are.
///
/// Not an open proxy: it listens on loopback only and fetches only URLs this app registered under
/// an unguessable token. Responses are close-delimited, one request per connection.
final class StreamProxy: NSObject, @unchecked Sendable, URLSessionDataDelegate {
    static let shared = StreamProxy()

    private struct Entry: Hashable {
        var url: URL
        var headers: [String: String]
        /// What the URL was named as inside a playlist; nil for the stream's own address.
        var role: StreamRewrite.Role?
        /// The stream's AES key when its key URL is gated; key requests are answered with it.
        var key: Data?
    }

    /// One request being relayed: AVPlayer's connection, and what has come back so far.
    private final class Relay {
        let connection: NWConnection
        let entry: Entry
        let headOnly: Bool
        let ranged: Bool
        var response: HTTPURLResponse?
        var head = Data()
        var decided = false
        var playlist = false

        init(connection: NWConnection, entry: Entry, headOnly: Bool, ranged: Bool) {
            self.connection = connection
            self.entry = entry
            self.headOnly = headOnly
            self.ranged = ranged
        }
    }

    private let queue = DispatchQueue(label: "com.anilili.ios.stream-proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyPort: UInt16?
    private var starting = false
    private var entries: [String: Entry] = [:]
    private var tokens: [Entry: String] = [:]
    /// Touched only on `queue` (the session's delegate queue and every connection's).
    private var relays: [Int: Relay] = [:]

    static let maxPlaylistBytes = 4 * 1024 * 1024
    static let maxEntries = 30_000

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
    }()

    /// Starts listening if it isn't already, so an address can be handed out without waiting.
    func prepare() {
        lock.lock()
        let needed = listener == nil && !starting
        if needed { starting = true }
        lock.unlock()
        if needed { launch() }
    }

    /// The loopback address that plays `url` with `headers`, or nil while the proxy isn't
    /// listening yet (the caller plays the URL directly then).
    func address(for url: URL, headers: [String: String], key: Data? = nil) -> URL? {
        prepare()
        lock.lock()
        defer { lock.unlock() }
        guard let port = readyPort else { return nil }
        return address(Entry(url: url, headers: headers, role: nil, key: key), port: port)
    }

    /// Registers one URL and returns its loopback address; an identical entry keeps its token.
    /// Called with `lock` held.
    private func address(_ entry: Entry, port: UInt16) -> URL? {
        let token: String
        if let known = tokens[entry] {
            token = known
        } else {
            if entries.count >= Self.maxEntries {
                entries.removeAll()
                tokens.removeAll()
            }
            var bytes = [UInt8](repeating: 0, count: 16)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            entries[token] = entry
            tokens[entry] = token
        }
        // An extension AVPlayer can read the kind from, besides the content type sent back.
        let suffix: String
        switch entry.role {
        case nil, .playlist?: suffix = "m3u8"
        case .segment?: suffix = "ts"
        case .key?: suffix = "key"
        case .map?: suffix = "mp4"
        }
        return URL(string: "http://127.0.0.1:\(port)/\(token).\(suffix)")
    }

    private func entry(for token: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]
    }

    // MARK: - Listening

    private func launch() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.start(queue: queue)
        } catch {
            Log.error("proxy", "couldn't listen: \(Log.describe(error))")
            lock.lock()
            starting = false
            lock.unlock()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            readyPort = listener?.port?.rawValue
            starting = false
            let port = readyPort ?? 0
            lock.unlock()
            Log.info("proxy", "stream proxy on 127.0.0.1:\(port)")
        case .failed(let error):
            Log.error("proxy", "stream proxy failed: \(error)")
            lock.lock()
            listener?.cancel()
            listener = nil
            readyPort = nil
            starting = false
            lock.unlock()
        case .cancelled:
            lock.lock()
            listener = nil
            readyPort = nil
            starting = false
            lock.unlock()
        default:
            break
        }
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var head = buffer
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.relay(connection, head: String(decoding: head[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil || head.count > 65_536 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: head)
            }
        }
    }

    private func relay(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return reply(connection, status: 405)
        }
        let path = String(parts[1]).dropFirst()
        let token = String(path.prefix { $0 != "." && $0 != "?" })
        guard let entry = entry(for: token) else { return reply(connection, status: 404) }
        if entry.role == .key, let key = entry.key {
            // Answered here: the real key URL wants a header only the site's own player sends.
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(key.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(head.utf8)
            if parts[0] != "HEAD" { payload.append(key) }
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        var request = URLRequest(url: entry.url)
        request.httpShouldHandleCookies = false
        request.setValue(HTTP.safariUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in entry.headers { request.setValue(value, forHTTPHeaderField: name) }
        // Only the headers that say which bytes are wanted; who is asking is this app's to say.
        var ranged = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if ["range", "if-range"].contains(name.lowercased()) {
                request.setValue(value, forHTTPHeaderField: name)
                if name.lowercased() == "range" { ranged = true }
            }
        }
        let task = session.dataTask(with: request)
        relays[task.taskIdentifier] = Relay(connection: connection, entry: entry, headOnly: parts[0] == "HEAD", ranged: ranged)
        connection.stateUpdateHandler = { [weak self, weak task] state in
            switch state {
            case .cancelled, .failed:
                // AVPlayer seeking or moving on closes the socket mid-body; the upstream read
                // has nobody left to serve.
                task?.cancel()
                if let id = task?.taskIdentifier { self?.relays[id] = nil }
            default:
                break
            }
        }
        task.resume()
    }

    // MARK: - Upstream

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        relays[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let relay = relays[dataTask.taskIdentifier] else { return }
        if relay.decided && !relay.playlist {
            if !relay.headOnly { relay.connection.send(content: data, completion: .idempotent) }
            return
        }
        relay.head.append(data)
        if relay.playlist, relay.head.count > Self.maxPlaylistBytes {
            Log.warning("proxy", "playlist over \(Self.maxPlaylistBytes) bytes from \(relay.entry.url.host ?? "?")")
            dataTask.cancel()
            relays[dataTask.taskIdentifier] = nil
            return reply(relay.connection, status: 502)
        }
        if !relay.decided { decide(relay, complete: false) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let relay = relays.removeValue(forKey: task.taskIdentifier) else { return }
        if let error, !relay.decided || relay.playlist {
            if (error as? URLError)?.code != .cancelled {
                Log.warning("proxy", "\(relay.entry.url.host ?? "?") failed: \(Log.describe(error))")
            }
            return reply(relay.connection, status: 502)
        }
        if !relay.decided { decide(relay, complete: true) }
        if relay.playlist { sendPlaylist(relay) }
        // The body is done: close once everything queued has gone out.
        relay.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                              completion: .contentProcessed { _ in relay.connection.cancel() })
    }

    /// Decides, from the first bytes, what the response is: a playlist to buffer and rewrite, or
    /// media to stream on (from past any disguise). Waits for more bytes while it can't tell.
    private func decide(_ relay: Relay, complete: Bool) {
        guard let response = relay.response else { return }
        guard (200..<300).contains(response.statusCode) else {
            relay.decided = true
            Log.warning("proxy", "\(relay.entry.url.host ?? "?") answered \(response.statusCode) for \(relay.entry.role?.rawValue ?? "the stream")")
            sendHead(relay, status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"), length: nil, extra: [:])
            if !relay.headOnly { relay.connection.send(content: relay.head, completion: .idempotent) }
            return
        }
        let role = relay.entry.role
        if role == nil || role == .playlist {
            if relay.head.count < 16 && !complete { return }
            if StreamRewrite.looksLikePlaylist(relay.head) {
                relay.decided = true
                relay.playlist = true
                return
            }
        }
        var offset = 0
        if role == .segment && !relay.ranged {
            guard let found = StreamRewrite.payloadOffset([UInt8](relay.head.prefix(StreamRewrite.disguiseLimit)), complete: complete) else { return }
            offset = found
            if offset > 0 { Log.debug("proxy", "unwrapped a \(offset)-byte disguise from \(relay.entry.url.host ?? "?")") }
        }
        relay.decided = true
        let upstreamType = response.value(forHTTPHeaderField: "Content-Type")
        let type = role == .segment ? Self.segmentType(upstreamType, body: relay.head, offset: offset) : upstreamType
        let expected = response.expectedContentLength
        var extra: [String: String] = [:]
        if offset == 0 {
            for name in ["Content-Range", "Accept-Ranges"] {
                if let value = response.value(forHTTPHeaderField: name) { extra[name] = value }
            }
        }
        sendHead(relay, status: offset > 0 ? 200 : response.statusCode, contentType: type,
                 length: expected > 0 ? Int(expected) - offset : nil, extra: extra)
        if !relay.headOnly, relay.head.count > offset {
            relay.connection.send(content: relay.head.subdata(in: offset..<relay.head.count), completion: .idempotent)
        }
        relay.head = Data()
    }

    /// A segment's real type: what the CDN said unless it dressed it as an image or said nothing
    /// useful, in which case fMP4 by its box names and MPEG-TS otherwise.
    static func segmentType(_ upstream: String?, body: Data, offset: Int) -> String {
        let declared = upstream?.lowercased() ?? ""
        if declared.hasPrefix("video/") || declared.hasPrefix("audio/") { return upstream ?? "video/mp2t" }
        let bytes = [UInt8](body.dropFirst(offset).prefix(8))
        if bytes.count == 8, ["ftyp", "moof", "styp", "sidx"].contains(String(decoding: bytes[4..<8], as: UTF8.self)) {
            return "video/mp4"
        }
        return "video/mp2t"
    }

    private func sendPlaylist(_ relay: Relay) {
        guard let response = relay.response else { return reply(relay.connection, status: 502) }
        var text = String(decoding: relay.head, as: UTF8.self)
        if let kwik = StreamRewrite.explicitKwikIVs(text) {
            Log.debug("proxy", "Kwik IVs written out for \(relay.entry.url.host ?? "?")")
            text = kwik
        }
        text = StreamRewrite.droppingFileSubtitles(text)
        let base = response.url ?? relay.entry.url
        lock.lock()
        let port = readyPort ?? 0
        let rewritten = StreamRewrite.playlist(text, base: base) { url, role in
            address(Entry(url: url, headers: relay.entry.headers, role: role, key: relay.entry.key), port: port)?.absoluteString ?? url.absoluteString
        }
        lock.unlock()
        let body = Data(rewritten.utf8)
        sendHead(relay, status: 200, contentType: "application/vnd.apple.mpegurl", length: body.count, extra: [:])
        if !relay.headOnly { relay.connection.send(content: body, completion: .idempotent) }
    }

    private func sendHead(_ relay: Relay, status: Int, contentType: String?, length: Int?, extra: [String: String]) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let length { head += "Content-Length: \(length)\r\n" }
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        relay.connection.send(content: Data(head.utf8), completion: .idempotent)
    }

    private func reply(_ connection: NWConnection, status: Int) {
        let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 502: return "Bad Gateway"
        default: return "Status \(status)"
        }
    }
}
#endif
