import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AniList sign-in, the implicit grant Android uses (`AuthManager`): AniList redirects to
/// `http://localhost/#access_token=…`, and the sign-in web view reads the token out of that URL
/// before anything tries to open localhost. No client secret; tokens last about a year and AniList
/// has no refresh.
public enum AniListAuth {
    public static let clientID = "45552"
    static let authorizeEndpoint = URL(string: "https://anilist.co/api/v2/oauth/authorize")!

    /// The page to open. AniList uses the redirect registered for the client; naming it here
    /// makes its grant step fail with unsupported_grant_type.
    public static func authorizeURL(state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Whether a navigation is the redirect carrying the token (either scheme on localhost).
    public static func isRedirect(_ url: URL) -> Bool {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https", url.host == "localhost" else { return false }
        return url.fragment?.contains("access_token=") == true
    }

    /// The token, when the redirect's state is the one this sign-in sent.
    public static func token(from url: URL, expectedState: String) -> String? {
        guard isRedirect(url), let fragment = url.fragment else { return nil }
        var components = URLComponents()
        components.query = fragment
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return items.first(where: { $0.name == "access_token" })?.value?.nonBlank
    }

    /// Whether the token's `exp` has passed (with a minute's margin). A token without one counts as
    /// live, as on Android.
    public static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = JWT.claim(token, "exp") else { return false }
        return Double(expiry) <= now.timeIntervalSince1970 + 60
    }

    /// The AniList user id the token belongs to.
    public static func viewerID(_ token: String) -> Int? {
        JWT.claim(token, "sub")
    }
}

/// MyAnimeList sign-in: authorization code with PKCE `plain`, the only method MAL supports
/// (`MalAuthManager`). The web view catches the registered `https://localhost/?code=…` redirect and
/// the code is traded for a token pair. Access tokens expire and refresh tokens rotate.
public enum MALAuth {
    public static let clientID = "4ae5f8056db821737a4f40f8816177cd"
    static let authorizeEndpoint = URL(string: "https://myanimelist.net/v1/oauth2/authorize")!
    static let tokenEndpoint = URL(string: "https://myanimelist.net/v1/oauth2/token")!
    /// Refresh this long before the reported expiry.
    public static let expiryMargin: TimeInterval = 5 * 60

    public struct Tokens: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date

        public init(accessToken: String, refreshToken: String, expiresAt: Date) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }

        public func isFresh(now: Date = Date()) -> Bool { now < expiresAt.addingTimeInterval(-MALAuth.expiryMargin) }
    }

    /// Under `plain` the verifier is the challenge; 32 random bytes give 43 characters, inside
    /// MAL's 43–128 window.
    public static func authorizeURL(state: String, verifier: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain"),
        ]
        return components.url!
    }

    public static func isRedirect(_ url: URL) -> Bool {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https", url.host == "localhost" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "code" } == true
    }

    public static func code(from url: URL, expectedState: String) -> String? {
        guard isRedirect(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return items.first(where: { $0.name == "code" })?.value?.nonBlank
    }

    public static func exchange(code: String, verifier: String) async throws -> Tokens {
        try await requestTokens([
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
        ])
    }

    public static func refresh(_ tokens: Tokens) async throws -> Tokens {
        try await requestTokens([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ])
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String
        var expires_in: Double?
    }

    static func requestTokens(_ form: [String: String]) async throws -> Tokens {
        let (data, response) = try await HTTP.data(
            tokenEndpoint,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(FormEncoding.encode(form).utf8)
        )
        guard (200..<300).contains(response.statusCode) else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw HTTPError(status: response.statusCode, "MyAnimeList's token endpoint answered HTTP \(response.statusCode): \(snippet)")
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(accessToken: parsed.access_token, refreshToken: parsed.refresh_token,
                      expiresAt: Date().addingTimeInterval(parsed.expires_in ?? 3600))
    }
}

/// Random URL-safe strings for OAuth state and PKCE verifiers.
public enum OAuthRandom {
    public static func urlSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Base64URL.encode(Data(bytes))
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

enum JWT {
    /// A numeric claim from the token's payload (`exp`, `sub`); AniList writes `sub` as a string.
    static func claim(_ token: String, _ name: String) -> Int? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = Base64URL.decode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch object[name] {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }
}

enum FormEncoding {
    static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ form: [String: String]) -> String {
        form.sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
