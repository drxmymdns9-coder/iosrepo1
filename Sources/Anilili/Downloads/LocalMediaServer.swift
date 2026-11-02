#if canImport(UIKit)
import AnililiCore
import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that serves the downloads folder, so a saved HLS episode
/// (playlist, segments, key) plays offline: AVPlayer won't play HLS from file URLs, and its own
/// offline HLS downloader doesn't run in the Simulator. GET and Range only; one request per
/// connection. Info.plist allows loopback HTTP (`NSAllowsLocalNetworking`).
final class LocalMediaServer: @unchecked Sendable {
    static let shared = LocalMediaServer()

    private let queue = DispatchQueue(label: "com.anilili.ios.local-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyPort: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []

    /// The served folder (the downloads directory).
    var root: URL { DownloadPaths.root }

    /// The address of a file under the root, starting the server if it isn't running.
    func url(for relativePath: String) async throws -> URL {
        let port = try await start()
        let path = relativePath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(path)") else { throw HTTPError("Bad local path \(relativePath)") }
        return url
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let readyPort {
                lock.unlock()
                continuation.resume(returning: readyPort)
                return
            }
            waiters.append(continuation)
            let starting = listener != nil
            lock.unlock()
            if !starting { launch() }
        }
    }

    private func launch() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.start(queue: queue)
        } catch {
            finish(.failure(error))
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            Log.info("downloads", "local server on 127.0.0.1:\(port)")
            lock.lock()
            readyPort = port
            lock.unlock()
            finish(.success(port))
        case .failed(let error):
            Log.error("downloads", "local server failed: \(error)")
            lock.lock()
            listener?.cancel()
            listener = nil
            readyPort = nil
            lock.unlock()
            finish(.failure(error))
        case .cancelled:
            lock.lock()
            listener = nil
            readyPort = nil
            lock.unlock()
        default:
            break
        }
    }

    private func finish(_ result: Result<UInt16, Error>) {
        lock.lock()
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(with: result) }
    }

    // MARK: - Requests

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var head = buffer
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: head[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil || head.count > 65_536 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: head)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return send(connection, status: "405 Method Not Allowed", body: Data()) }
        let rawPath = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        let path = rawPath.removingPercentEncoding ?? rawPath
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), !path.contains(".."),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return send(connection, status: "404 Not Found", body: Data())
        }
        var headers = ["Content-Type": Self.contentType(file.pathExtension), "Accept-Ranges": "bytes"]
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.flatMap { Self.byteRange($0, size: data.count) }
        let isHead = parts[0] == "HEAD"
        if let range {
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            send(connection, status: "206 Partial Content", headers: headers, body: data.subdata(in: range), headOnly: isHead)
        } else {
            send(connection, status: "200 OK", headers: headers, body: data, headOnly: isHead)
        }
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String] = [:], body: Data, headOnly: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// `Range: bytes=a-b` (or `a-`, or `-n`) as a half-open range within `size`.
    static func byteRange(_ header: String, size: Int) -> Range<Int>? {
        guard let spec = header.split(separator: "=", maxSplits: 1).last?.split(separator: ",").first else { return nil }
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count == 2, size > 0 else { return nil }
        if ends[0].isEmpty, let suffix = Int(ends[1]) { return max(0, size - suffix)..<size }
        guard let start = Int(ends[0]), start < size else { return nil }
        let end = Int(ends[1]).map { min($0, size - 1) } ?? size - 1
        return end >= start ? start..<(end + 1) : nil
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4", "m4s", "m4v": return "video/mp4"
        case "aac": return "audio/aac"
        case "m4a": return "audio/mp4"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
}
#endif
