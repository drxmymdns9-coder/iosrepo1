import Foundation

/// The tokens the network layer sends, set by the app from its Keychain. AniList's goes on every
/// AniList request once there is one, as on Android: it lifts the rate limit and AniList's
/// outages have let signed-in requests through when anonymous ones were refused.
public final class AccountCredentials: @unchecked Sendable {
    public static let shared = AccountCredentials()

    private let lock = NSLock()
    private var anilist: String?
    private var mal: MALAuth.Tokens?
    private var malRefresh: Task<MALAuth.Tokens, Error>?
    /// Called with every MAL token pair a refresh produces, so the app can store it.
    private var onMALRefresh: (@Sendable (MALAuth.Tokens?) -> Void)?

    public init() {}

    public var anilistToken: String? {
        get { locked { anilist } }
        set { locked { anilist = newValue } }
    }

    public var malTokens: MALAuth.Tokens? {
        get { locked { mal } }
        set { locked { mal = newValue } }
    }

    public func onMALTokensChanged(_ handler: @escaping @Sendable (MALAuth.Tokens?) -> Void) {
        locked { onMALRefresh = handler }
    }

    /// A usable MAL access token, refreshing (one refresh at a time) when the stored one is close
    /// to expiry. A failed refresh only signs out once the old token is really dead: a network
    /// blip keeps the session for later.
    public func malAccessToken() async throws -> String {
        guard let tokens = malTokens else { throw AccountError.signInRequired }
        if tokens.isFresh() { return tokens.accessToken }
        let task: Task<MALAuth.Tokens, Error> = locked {
            if let running = malRefresh { return running }
            let started = Task { try await MALAuth.refresh(tokens) }
            malRefresh = started
            return started
        }
        do {
            let fresh = try await task.value
            let handler: (@Sendable (MALAuth.Tokens?) -> Void)? = locked {
                mal = fresh
                malRefresh = nil
                return onMALRefresh
            }
            Log.info("account", "MyAnimeList token refreshed")
            handler?(fresh)
            return fresh.accessToken
        } catch {
            locked { malRefresh = nil }
            Log.error("account", "MyAnimeList token refresh failed: \(Log.describe(error))")
            if Date() >= tokens.expiresAt {
                let handler: (@Sendable (MALAuth.Tokens?) -> Void)? = locked {
                    mal = nil
                    return onMALRefresh
                }
                handler?(nil)
                throw AccountError.sessionExpired(.mal)
            }
            return tokens.accessToken
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public enum AccountError: LocalizedError, Equatable, Sendable {
    case signInRequired
    case sessionExpired(AccountService)
    case notOnMAL

    public var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to AniList or MyAnimeList from Settings to keep a list."
        case .sessionExpired(let service): return "Your \(service.label) sign-in expired. Sign in again from Settings → Accounts."
        case .notOnMAL: return "This anime couldn't be matched to MyAnimeList."
        }
    }
}
