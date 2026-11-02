#if canImport(UIKit)
import AnililiCore
import UIKit
import WebKit

/// The hidden web view hanime's streams need (Android's `HanimeBridge` and
/// `HanimeResolverWebView`), plugged into the core as `Hanime.resolver`.
///
/// hanime's player encrypts its handshake and decrypts the reply in WebAssembly, so the page itself
/// has to run it. A `JSON.parse` hook, installed before any of the page's scripts, keeps the first
/// parsed object that carries a `sources` array: the decrypted quality ladder, which arrives before
/// any video would play.
///
/// What Android learnt the hard way, kept here:
/// - The page mounts its player only when that part of it is in view, so the web view is laid out
///   at a phone-sized viewport (412×892). It sits inside a 1-point container that clips it, behind
///   the app's own views: WebKit sees a full, visible page, the viewer sees nothing.
/// - Videos are kept from playing (`mediaTypesRequiringUserActionForPlayback`, then paused and
///   muted every 100 ms), so the resolver never takes the decoder or the audio session.
/// - Navigation is held to hanime.tv and pop-ups are refused; the page is parked on `about:blank`
///   after every resolve, since a live hanime tab keeps timers and media running.
@MainActor
final class HanimeResolver: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let shared = HanimeResolver()

    /// Android's budget for the browser resolvers.
    static let timeout: TimeInterval = 25
    private static let viewport = CGSize(width: 412, height: 892)

    private var webView: WKWebView?
    private var container: UIView?
    private var busy = false

    /// Called once at launch. hanime is still only asked while adult content is shown.
    static func install() {
        Hanime.resolver = { slug in try await HanimeResolver.resolve(slug) }
    }

    static func resolve(_ slug: String) async throws -> [Hanime.Rung] {
        try await shared.run(slug)
    }

    private func run(_ slug: String) async throws -> [Hanime.Rung] {
        // One page at a time: a single web view can't run two loads.
        while busy {
            try await Task.sleep(for: .milliseconds(200))
        }
        busy = true
        defer {
            busy = false
            webView?.load(URLRequest(url: URL(string: "about:blank")!))
        }
        guard let web = attach(), let page = URL(string: "https://hanime.tv/videos/hentai/\(slug)") else {
            throw HTTPError("hanime's resolver has no window to live in")
        }
        Log.info("hanime", "resolving \(slug) in the hidden web view")
        web.load(URLRequest(url: page))
        let started = Date()
        var polls = 0
        while Date().timeIntervalSince(started) < Self.timeout {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
            polls += 1
            guard let raw = await evaluate(web, Self.readSources), !raw.isEmpty else {
                if polls % 20 == 5 {
                    let state = await evaluate(web, Self.pageState) ?? "?"
                    Log.debug("hanime", "waiting: \(state)")
                }
                continue
            }
            do {
                let ladder = try JSONDecoder().decode([Hanime.Rung].self, from: Data(raw.utf8))
                Log.info("hanime", "\(slug): \(ladder.count) rungs after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                if ladder.contains(where: \.isPlayable) { return ladder }
            } catch {
                Log.warning("hanime", "sources didn't decode: \(Log.describe(error))")
            }
        }
        let state = await evaluate(web, Self.pageState) ?? "?"
        Log.warning("hanime", "\(slug): no sources within \(Int(Self.timeout))s (\(state))")
        throw HTTPError("hanime's page produced no stream")
    }

    /// The web view, created on first use inside its clipping container in the key window.
    private func attach() -> WKWebView? {
        if let webView, webView.window != nil { return webView }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.websiteDataStore = .nonPersistent()
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: Self.hookSources, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: Self.quietVideos, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let web = WKWebView(frame: CGRect(origin: .zero, size: Self.viewport), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isUserInteractionEnabled = false
        web.accessibilityElementsHidden = true

        let box = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        box.clipsToBounds = true
        box.isUserInteractionEnabled = false
        box.accessibilityElementsHidden = true
        box.addSubview(web)
        // Behind everything the app draws: the clip hides it, and so does the root view.
        window.insertSubview(box, at: 0)

        container?.removeFromSuperview()
        container = box
        webView = web
        Log.info("hanime", "resolver web view attached")
        return web
    }

    /// One script's result as a string; nil for anything else, including `null`.
    private func evaluate(_ web: WKWebView, _ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    // MARK: - WKNavigationDelegate, WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else { return .allow }
        if url.absoluteString == "about:blank" { return .allow }
        let host = url.host?.lowercased() ?? ""
        let allowed = url.scheme == "https" && (host == "hanime.tv" || host.hasSuffix(".hanime.tv"))
        if !allowed { Log.debug("hanime", "blocked navigation to \(host)") }
        return allowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        Log.debug("hanime", "blocked a pop-up")
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.warning("hanime", "resolver web content process ended")
        container?.removeFromSuperview()
        container = nil
        self.webView = nil
    }

    // MARK: - Scripts

    /// Keeps whatever `JSON.parse` is handed that looks like the decrypted handshake: the one point
    /// where the payload is both decrypted and reachable from outside the player's module.
    private static let hookSources = """
    (function() {
      if (window.__aniliHanimeHook) return;
      window.__aniliHanimeHook = true;
      window.__aniliHanimeSources = '';
      var original = JSON.parse;
      JSON.parse = function(text, reviver) {
        var value = original.call(JSON, text, reviver);
        try {
          if (!window.__aniliHanimeSources && value && typeof value === 'object' &&
              Object.prototype.toString.call(value.sources) === '[object Array]') {
            window.__aniliHanimeSources = JSON.stringify(value.sources);
          }
        } catch (e) {}
        return value;
      };
    })();
    """

    /// A string always, so the bridge never has to carry a `null`.
    private static let readSources = "String(window.__aniliHanimeSources || '')"

    /// Enough to tell "the page never loaded" from "it loaded and the handshake never ran".
    private static let pageState = """
    (function() {
      try {
        return ['ready=' + document.readyState, 'hook=' + (window.__aniliHanimeHook ? 1 : 0),
                'videos=' + document.querySelectorAll('video').length, 'url=' + location.pathname,
                'len=' + document.body.innerHTML.length].join(' ');
      } catch (e) { return 'state-unreadable'; }
    })();
    """

    /// Muted isn't stopped: a playing video still decodes. Pause everything, all the time.
    private static let quietVideos = """
    (function() {
      if (window.__aniliHanimeQuiet) return;
      window.__aniliHanimeQuiet = true;
      function quiet() {
        try {
          var videos = document.querySelectorAll('video');
          for (var i = 0; i < videos.length; i++) {
            videos[i].muted = true;
            videos[i].autoplay = false;
            if (!videos[i].paused) videos[i].pause();
          }
        } catch (e) {}
      }
      quiet();
      setInterval(quiet, 100);
    })();
    """
}
#endif
