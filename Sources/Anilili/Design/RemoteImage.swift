#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UIKit

/// What a `RemoteImage` has so far: the picture, or nil while it loads, when it failed, or when
/// there is no URL. Shaped like AsyncImage's phase so call sites read the same.
struct RemoteImagePhase {
    var image: Image?
}

/// Artwork from the network, in place of AsyncImage. AsyncImage drops a load when its view is
/// redrawn mid-download: the cancelled request becomes a failure that is never retried, which on
/// a phone's slower network left whole grids of posters blank (My List, as the account's lists
/// and new-episode counts arrive). Here the download belongs to `ImagePipeline`, not the view, so
/// a redraw can't cut it off; decoded images are kept in memory and responses on disk, and a cached
/// image shows straight away.
struct RemoteImage<Content: View>: View {
    private let url: URL?
    private let content: (RemoteImagePhase) -> Content
    @State private var loaded: Loaded?

    private struct Loaded {
        var url: URL
        var image: UIImage
    }

    init(url: URL?, @ViewBuilder content: @escaping (RemoteImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        ZStack {
            // Never empty: SwiftUI doesn't run `.task` on a view that draws nothing, and content
            // with no placeholder (`if let image = phase.image { … }` alone) is empty until the
            // image arrives, so it would never load.
            Color.clear.frame(width: 0, height: 0)
            content(RemoteImagePhase(image: current.map { Image(uiImage: $0) }))
        }
        .task(id: url) {
            guard let url, current == nil else { return }
            if let image = await ImagePipeline.shared.image(for: url) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = Loaded(url: url, image: image) }
            }
        }
    }

    private var current: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ImagePipeline.shared.cached(url)
    }
}

/// Downloads, decodes and caches artwork for `RemoteImage`. One download per URL however many
/// views ask, and it runs to the end even if every view asking has gone, so the next one finds it.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        // Artwork at a given URL doesn't change; a cached copy also keeps posters up offline.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inFlight[url] { return running }
            let started = Task.detached(priority: .userInitiated) { [session] in
                await Self.fetch(url, session: session)
            }
            inFlight[url] = started
            return started
        }
        let image = await task.value
        lock.withLock {
            if let image { memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image)) }
            inFlight[url] = nil
        }
        return image
    }

    private static func fetch(_ url: URL, session: URLSession) async -> UIImage? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Log.warning("image", "\(Log.short(url)) → \(http.statusCode)")
                return nil
            }
            guard let image = UIImage(data: data) else {
                Log.warning("image", "\(Log.short(url)): not an image (\(data.count) bytes)")
                return nil
            }
            return await image.byPreparingForDisplay() ?? image
        } catch {
            Log.warning("image", "\(Log.short(url)) failed: \(Log.describe(error))")
            return nil
        }
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}
#endif
