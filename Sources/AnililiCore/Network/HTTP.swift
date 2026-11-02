import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPError: LocalizedError, Sendable {
    public let status: Int?
    public let message: String

    public init(status: Int? = nil, _ message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One URLSession for the whole app, with the defaults scraping needs.
public enum HTTP {
    /// The UA the Android app's scrapers send. AnimeHeaven was measured against it, so keep it
    /// rather than advertising iOS Safari.
    public static let androidChromeUserAgent =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

    /// What the app's own requests look like to an API that checks: Safari on an iPhone.
    public static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// The browser a provider request claims to be, matched to the TLS stack actually making it:
    /// Cloudflare refuses a client whose User-Agent and TLS fingerprint disagree (error 1010 for an
    /// iPhone Safari UA sent from Linux's libcurl, 2026-10-12). On Apple platforms URLSession *is*
    /// Safari's stack; the Linux test runs say they're the Android app, whose UA these sites take.
    public static var browserUserAgent: String {
        #if os(Linux)
        return androidChromeUserAgent
        #else
        return safariUserAgent
        #endif
    }

    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        // Providers that need a cookie are given it explicitly; a shared jar would leak one
        // site's session into another's requests.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    public static func data(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await data(for: request)
    }

    /// Any request, logged like the rest; for providers that need a POST or a response header.
    public static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = request.url
        let started = Date()
        let elapsed = { String(format: "%.0fms", Date().timeIntervalSince(started) * 1000) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Log.warning("http", "\(method) \(Log.short(url)) failed after \(elapsed()): \(Log.describe(error))")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError("No HTTP response from \(url?.host ?? "?")")
        }
        let line = "\(method) \(Log.short(url)) → \(http.statusCode) \(data.count)B \(elapsed())"
        if (200..<400).contains(http.statusCode) {
            Log.debug("http", line)
        } else {
            // The start of an error body usually says who refused: Cloudflare, the API, a CDN.
            let snippet = String(decoding: data.prefix(160), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            Log.warning("http", "\(line) body: \(snippet)")
        }
        return (data, http)
    }

    /// The body as text, throwing on anything but 2xx.
    public static func text(_ url: URL, headers: [String: String] = [:]) async throws -> String {
        let (data, response) = try await data(url, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, "HTTP \(response.statusCode) from \(url.host ?? "server")")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension String {
    /// Percent-encoded for a query value; spaces as `%20`, which PHP and FastAPI both accept.
    public var queryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? self
    }

    /// RFC 3986 unreserved, ASCII only: `CharacterSet.alphanumerics` would let a Japanese title
    /// through unencoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
