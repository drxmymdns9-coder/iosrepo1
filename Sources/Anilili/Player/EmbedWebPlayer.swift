#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UIKit
import WebKit

/// A server that only offers its own web player (an "embed"), shown in a web view, after the
/// Android app's `EmbedWebView`: the page plays inline with its own controls, popups and pop-unders
/// are dropped, the main frame stays on the embed's site once it has loaded, and Android's list of
/// ad and analytics origins is refused. A script in every frame reports the video's clock once a
/// second, which is how progress is saved and the next episode found.
struct EmbedWebPlayer: UIViewRepresentable {
    let source: VideoSource
    var onTick: (_ position: Double, _ duration: Double, _ playing: Bool) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        // Nothing an embed stores is worth keeping between episodes.
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.add(WeakMessageHandler(context.coordinator), name: Coordinator.channel)
        controller.addUserScript(WKUserScript(source: Coordinator.progressScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.load(source, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != source.url { context.coordinator.load(source, in: view) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.channel)
        // Leaves no audio playing behind the closed page.
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let channel = "anilili"

        var parent: EmbedWebPlayer
        private(set) var loaded: URL?
        /// The embed's own site, fixed when its redirect chain has settled (the first finished load).
        private var pinnedHost: String?
        private var ended = false
        private var rulesAdded = false

        init(_ parent: EmbedWebPlayer) {
            self.parent = parent
        }

        func load(_ source: VideoSource, in view: WKWebView) {
            loaded = source.url
            pinnedHost = nil
            ended = false
            var page = URLRequest(url: source.url)
            for (field, value) in source.headers where field.caseInsensitiveCompare("User-Agent") != .orderedSame {
                page.setValue(value, forHTTPHeaderField: field)
            }
            let request = page
            Self.blockList { [weak self] list in
                if let list, self?.rulesAdded == false {
                    view.configuration.userContentController.add(list)
                    self?.rulesAdded = true
                }
                view.load(request)
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["about", "blob", "data"].contains(scheme) { return .allow }
            guard scheme == "http" || scheme == "https" else {
                Log.info("embed", "refused \(scheme): navigation")
                return .cancel
            }
            // Frames load what they like (the player is often an iframe on another host); the
            // main frame doesn't leave the embed's site once it has loaded, which is how ad
            // clicks try to take the page over.
            guard action.targetFrame?.isMainFrame == true, let pinnedHost else { return .allow }
            if Self.sameSite(url.host, pinnedHost) { return .allow }
            Log.info("embed", "refused leaving \(pinnedHost) for \(url.host ?? "?")")
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if pinnedHost == nil, let host = webView.url?.host {
                pinnedHost = host
                Log.info("embed", "page loaded on \(host)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.warning("embed", "page failed: \(Log.describe(error))")
        }

        /// Popups and pop-unders (`window.open`, `target=_blank`) are dropped.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            Log.debug("embed", "dropped a popup to \(action.request.url?.host ?? "?")")
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Log.warning("embed", "web content process ended; reloading")
            webView.reload()
        }

        // MARK: Progress

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let position = (body["t"] as? NSNumber)?.doubleValue,
                  let duration = (body["d"] as? NSNumber)?.doubleValue else { return }
            let playing = (body["p"] as? NSNumber)?.boolValue ?? false
            parent.onTick(position, duration, playing)
            if (body["e"] as? NSNumber)?.boolValue == true {
                guard !ended else { return }
                ended = true
                parent.onEnded()
            } else if position < duration - 2 {
                ended = false
            }
        }

        /// Android's `PROGRESS_POLL_JS`. WebKit runs it in every frame, cross-origin ones included,
        /// so the player's own iframe reports too.
        static let progressScript = """
        (function() {
          if (window.__aniliProgressHooked) return;
          window.__aniliProgressHooked = true;
          function findVideo() {
            var v = document.querySelector('video');
            if (v) return v;
            var frames = document.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
              try {
                var d = frames[i].contentDocument;
                if (d) {
                  var fv = d.querySelector('video');
                  if (fv) return fv;
                }
              } catch (e) { /* cross-origin: that frame reports itself */ }
            }
            return null;
          }
          setInterval(function() {
            try {
              var v = findVideo();
              if (v && isFinite(v.duration) && v.duration > 0 && v.currentTime >= 0) {
                window.webkit.messageHandlers.anilili.postMessage({t: v.currentTime, d: v.duration, p: !v.paused, e: v.ended});
              }
            } catch (e) { /* handler detached */ }
          }, 1000);
        })();
        """

        // MARK: Blocked origins

        /// Android's `EMBED_BLOCKED_ORIGINS`: advertising, analytics and beacon origins no player
        /// needs, matched on the domain and every subdomain of it.
        static let blockedOrigins = [
            "googlesyndication.com", "googletagmanager.com", "google-analytics.com", "doubleclick.net",
            "cloudflareinsights.com", "morphify.net", "sssrr.org", "statlytic.net", "plausible.io", "jwpltx.com",
        ]

        private static var compiled: WKContentRuleList?

        /// The block list, compiled once per launch.
        static func blockList(_ done: @escaping @MainActor (WKContentRuleList?) -> Void) {
            if let compiled { return done(compiled) }
            let rules: [[String: Any]] = blockedOrigins.map { domain in
                let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
                return ["trigger": ["url-filter": "^[a-z]+://([^/:]*\\.)?\(escaped)[:/]"], "action": ["type": "block"]]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else {
                return done(nil)
            }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "anilili-embed-blocklist", encodedContentRuleList: json) { list, error in
                MainActor.assumeIsolated {
                    if let error { Log.warning("embed", "block list didn't compile: \(error.localizedDescription)") }
                    compiled = list
                    done(list)
                }
            }
        }

        /// The same host, or one a subdomain of the other's site ("www." aside).
        static func sameSite(_ host: String?, _ pinned: String) -> Bool {
            guard let host = host?.lowercased() else { return false }
            let strip = { (value: String) in value.hasPrefix("www.") ? String(value.dropFirst(4)) : value }
            let a = strip(host), b = strip(pinned.lowercased())
            return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
        }
    }

    /// The content controller holds its handlers strongly; this keeps it from holding the page.
    @MainActor
    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?

        init(_ target: any WKScriptMessageHandler) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
#endif
