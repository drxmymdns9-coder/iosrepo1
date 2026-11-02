#if canImport(UIKit)
import AnililiCore
import SwiftUI
import WebKit

/// Sign-in to AniList or MyAnimeList in a web view that catches the `localhost` redirect before
/// anything tries to load it (Android's login WebView). ASWebAuthenticationSession can't take an
/// http(s)://localhost callback, which is what both services are registered with.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let service: AccountService

    @State private var state = OAuthRandom.urlSafe(bytes: 24)
    @State private var verifier = OAuthRandom.urlSafe(bytes: 32)
    @State private var working = false
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                SignInWebView(url: authorizeURL, loading: $loading) { url in redirected(url) }
                if loading || working {
                    VStack(spacing: 12) {
                        WaterFillLoader(size: 56)
                        Text(working ? "Signing in…" : "Opening \(service.label)…")
                            .font(AppFont.labelMedium)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background.opacity(working ? 0.9 : 0.6))
                }
                if let failure {
                    VStack(spacing: 12) {
                        Text(failure).font(AppFont.bodyMedium).foregroundStyle(palette.onSurface).multilineTextAlignment(.center)
                        Button("Try again") {
                            self.failure = nil
                            state = OAuthRandom.urlSafe(bytes: 24)
                            verifier = OAuthRandom.urlSafe(bytes: 32)
                        }
                        .foregroundStyle(palette.primary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                }
            }
            .navigationTitle("Sign in to \(service.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
        .tint(palette.primary)
        .interactiveDismissDisabled(working)
    }

    private var authorizeURL: URL {
        service == .anilist ? AniListAuth.authorizeURL(state: state) : MALAuth.authorizeURL(state: state, verifier: verifier)
    }

    /// Whether a navigation is the redirect; when it is, the web view never loads it.
    private func redirected(_ url: URL) -> Bool {
        switch service {
        case .anilist:
            guard AniListAuth.isRedirect(url) else { return false }
            guard let token = AniListAuth.token(from: url, expectedState: state) else {
                Log.error("account", "AniList redirect without a token for this sign-in (state mismatch)")
                failure = "AniList's answer didn't match this sign-in. Try again."
                return true
            }
            working = true
            Task {
                await AccountStore.shared.signInAniList(token: token)
                dismiss()
            }
        case .mal:
            guard MALAuth.isRedirect(url) else { return false }
            guard let code = MALAuth.code(from: url, expectedState: state) else {
                Log.error("account", "MyAnimeList redirect without a code for this sign-in (state mismatch)")
                failure = "MyAnimeList's answer didn't match this sign-in. Try again."
                return true
            }
            working = true
            Task {
                do {
                    try await AccountStore.shared.signInMAL(code: code, verifier: verifier)
                    dismiss()
                } catch {
                    Log.error("account", "MyAnimeList token exchange failed: \(Log.describe(error))")
                    working = false
                    failure = "MyAnimeList refused the sign-in: \(error.localizedDescription)"
                }
            }
        }
        return true
    }
}

private struct SignInWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    /// Returns true when the URL was the redirect and must not load.
    let onNavigate: (URL) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
        Log.info("account", "sign-in page \(Log.short(url))")
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        // A retry makes a new state, so a new page.
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            view.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignInWebView
        var loaded: URL?

        init(_ parent: SignInWebView) { self.parent = parent }

        // The async form: its signature hasn't changed across SDKs, where the completion-handler
        // one gained @MainActor @Sendable and a near-miss would silently never be called.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, url.host == "localhost" else { return .allow }
            // Never load it, whatever it carries: nothing is listening there.
            if !parent.onNavigate(url) { Log.warning("account", "localhost navigation that isn't a sign-in redirect: \(Log.short(url))") }
            return .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            Log.warning("account", "sign-in page failed: \(Log.describe(error))")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            // The cancelled redirect lands here too (WebKitErrorFrameLoadInterruptedByPolicyChange).
            if (error as NSError).code != 102 { Log.warning("account", "sign-in page failed to load: \(Log.describe(error))") }
        }
    }
}
#endif
