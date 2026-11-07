#if canImport(UIKit)
import AVFoundation
import AnililiCore
import BackgroundTasks
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// Shows reminders while the app is open, and opens the show when one is tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the root view: opens a show page by AniList id.
    @MainActor static var openShow: ((Int) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { HanimeResolver.install() }
        registerDownloadProcessing()
        scheduleDownloadProcessing()
        return true
    }

    private func registerDownloadProcessing() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.anilili.ios.downloads", using: nil) { task in
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            Task { @MainActor in
                // DownloadStore restores queued/partial records during initialization and pumps
                // them when the process is relaunched by iOS.
                _ = DownloadStore.shared
                task.setTaskCompleted(success: true)
                Self.scheduleDownloadProcessing()
            }
        }
    }

    private static func scheduleDownloadProcessing() {
        let request = BGProcessingTaskRequest(identifier: "com.anilili.ios.downloads")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// A phone stays portrait outside the player, which widens this while it's open (see
    /// `OrientationLock`). An iPad turns freely everywhere: iPadOS doesn't hold a multitasking app
    /// to one orientation, and the TV layout it gets is drawn for landscape.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad ? .all : OrientationLock.allowed }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let announcement = response.notification.request.content.userInfo["announcementId"] as? String {
            await MainActor.run { AnnouncementCenter.shared.open(id: announcement) }
            return
        }
        guard let id = response.notification.request.content.userInfo["anilistId"] as? Int else { return }
        Log.info("app", "notification opened show \(id)")
        await MainActor.run { AppDelegate.openShow?(id) }
    }
}

@main
struct AnililiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    @State private var router = AppRouter()

    init() {
        // First, so everything after it is on disk if the app crashes.
        CrashCapture.install()
        Log.info("app", "launch: \(AppInfo.summary)")
        // `.playback` keeps audio going with the silent switch on and is what Picture in Picture
        // and background audio (UIBackgroundModes: audio) both require.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            Log.error("app", "audio session: \(Log.describe(error))")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(router)
                .environment(\.layoutDirection, MenuLanguage.usesArabic ? .rightToLeft : .leftToRight)
                .environment(\.locale, Locale(identifier: MenuLanguage.usesArabic ? "ar" : MenuLanguage.usesSpanish ? "es" : "en"))
                .preferredColorScheme(.dark)
                .task { await DubIndexStore.shared.load() }
        }
    }
}

/// Pages reached from more than one place, pushed onto whichever tab's stack asked.
enum Route: Hashable {
    case schedule
    case notifications
    case settings(SettingsPage)
    /// A section opened from Settings search, with the row it found marked.
    case settingsRow(SettingsPage, String)
    case debugLog
}

/// Cross-tab navigation: which tab is showing, each tab's stack, and Browse's pending genre.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .home
    var paths: [AppTab: NavigationPath] = [:]
    /// Filters for Browse to open with (a genre pill, a studio chip); Browse applies and clears them.
    var browseFilters: DiscoverFilters?
    /// The tab bar and Home's header tucked away while scrolling down (see `tucksChrome`).
    var chromeHidden = false
    /// The TV layout's Home has scrolled its spotlight out from under the top navigation, which
    /// then takes the page colour.
    var televisionPastHero = false
    /// The title whose list status sheet is open (long-press "Add to list…", the show page).
    var listSheet: Media?
    /// The title whose score sheet is open on its own (long-press "Rate this season", the show
    /// page's star).
    var scoreSheet: Media?

    func select(_ tab: AppTab) {
        if tab == self.tab {
            // A second tap on the current tab goes back to its first page.
            paths[tab] = NavigationPath()
        } else {
            self.tab = tab
        }
        chromeHidden = false
    }

    func push<Value: Hashable>(_ value: Value, on tab: AppTab? = nil) {
        let target = tab ?? self.tab
        var path = paths[target] ?? NavigationPath()
        path.append(value)
        paths[target] = path
    }

    func openGenre(_ genre: String?) {
        var filters = DiscoverFilters()
        if let genre { filters.genres = [genre] }
        browseFilters = filters
        select(.search)
    }

    func openStudio(id: Int, name: String) {
        var filters = DiscoverFilters()
        filters.studioID = id
        filters.studioName = name
        browseFilters = filters
        select(.search)
    }
}

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    /// Read so the tab labels redraw when Settings → App → Menu language changes.
    @AppStorage(MenuLanguage.key) private var menuLanguage = MenuLanguage.system.rawValue
    @State private var linkPlay: PlayRequest?
    private var television = TelevisionLayout()

    /// `anilili://anime|watch|search` (see `AppLink`): the show page, the player, or Browse.
    private func open(_ url: URL) {
        guard let link = AppLink(url.absoluteString) else {
            Log.warning("link", "not a link this app opens: \(Log.short(url))")
            return
        }
        Log.info("link", "opening \(link.url)")
        switch link {
        case .anime(let id):
            router.push(Media(id: id, title: .init()), on: router.tab)
        case .search(let query):
            var filters = DiscoverFilters()
            filters.query = query
            router.browseFilters = filters
            router.select(.search)
        case .watch(let id, let episode, let start):
            Task {
                let media = (try? await AniListClient.shared.media(id: id)) ?? Media(id: id, title: .init())
                let preferDub = UserDefaults.standard.bool(forKey: Setting.preferDub)
                linkPlay = PlayRequest(media: media, episode: max(1, Int(episode.rounded(.down))), audio: preferDub ? .dub : .sub,
                                       listing: .empty, start: start)
            }
        }
    }

    var body: some View {
        let palette = AppearanceStore.shared.palette
        shell
        .background(palette.background.ignoresSafeArea())
        .environment(\.palette, palette)
        .tint(palette.primary)
        // MenuLanguage is intentionally not a system localization bundle. Re-keying the shell
        // guarantees every conditional Arabic/English/Spanish label and RTL direction is rebuilt
        // immediately after the App settings picker changes.
        .id(menuLanguage)
        .onAppear {
            AppDelegate.openShow = { id in router.push(Media(id: id, title: .init())) }
            AccountStore.shared.libraryStore = library
            AccountStore.shared.refreshIfStale()
            _ = DownloadStore.shared  // resumes whatever was saving when the app stopped
            StreamProxy.shared.prepare()  // listening before the first episode opens
            ReleaseAlerts.refreshIfStale(library: library)
            AnnouncementCenter.shared.check()
            UpdateCenter.shared.checkIfDue()
            UsageReporter.cameToFront()
            UsageReporter.check()
            Task { await SigningReminder.schedule() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                AccountStore.shared.refreshIfStale()
                ReleaseAlerts.refreshIfStale(library: library)
                AppIconSync.sync()
                AnnouncementCenter.shared.check()
                UpdateCenter.shared.checkIfDue()
                UsageReporter.cameToFront()
                UsageReporter.check()
            } else if phase == .background {
                UsageReporter.wentAway()
            }
        }
        .onOpenURL { url in open(url) }
        .sheet(item: Binding(get: { AnnouncementCenter.shared.showing }, set: { AnnouncementCenter.shared.showing = $0 })) { announcement in
            AnnouncementSheet(announcement: announcement).environment(\.palette, palette)
        }
        .sheet(item: Binding(get: { UpdateCenter.shared.showing }, set: { UpdateCenter.shared.showing = $0 })) { update in
            UpdateSheet(update: update).environment(\.palette, palette)
        }
        .fullScreenCover(item: $linkPlay) { request in
            WatchView(request: request)
                .environment(\.palette, palette)
                .environment(library)
                .environment(router)
        }
        .sheet(item: Binding(get: { router.listSheet }, set: { router.listSheet = $0 })) { media in
            ListStatusSheet(media: media)
                .environment(\.palette, palette)
                .environment(library)
                .environment(router)
        }
        .sheet(item: Binding(get: { router.scoreSheet }, set: { router.scoreSheet = $0 })) { media in
            NavigationStack { ScoreSheet(media: media, standalone: true) }
                .tint(palette.primary)
                .presentationDetents([.medium, .large])
                .environment(\.palette, palette)
        }
    }

    /// The phone's tab bar, or on an iPad the TV layout's top navigation (Settings → App → Layout).
    @ViewBuilder
    private var shell: some View {
        if television.isOn {
            TelevisionShell()
        } else {
            // The system tab bar: Liquid Glass on iOS 26, where Search sits apart at the trailing end.
            TabView(selection: Binding(get: { router.tab }, set: { router.select($0) })) {
                ForEach(AppTab.phone) { tab in
                    Tab(tab.label, systemImage: tab.systemImage, value: tab, role: tab == .search ? .search : nil) {
                        TabStack(tab: tab)
                    }
                }
            }
            .modifier(TabBarMinimizes())
            .onAppear { if router.tab == .schedule { router.tab = .home } }
        }
    }
}

/// Android's bars tucking away on scroll, for the tab bar: iOS 26 shrinks it to its selected tab
/// while scrolling down; earlier versions hide it (see `TabStack`). Neither when Appearance →
/// Keep the bars on screen is on.
private struct TabBarMinimizes: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        // The iOS 26 tab-bar minimization API is not present in the iOS 18 SDK.
        // Keep the modifier as a no-op so the project remains buildable with Xcode 16.
        content
    }
}

/// One tab's navigation stack, kept alive while another tab shows.
struct TabStack: View {
    @Environment(AppRouter.self) private var router
    let tab: AppTab

    var body: some View {
        NavigationStack(path: Binding(
            get: { router.paths[tab] ?? NavigationPath() },
            set: { router.paths[tab] = $0 }
        )) {
            if #available(iOS 26, *) {
                root.mediaDestinations()
            } else {
                root.mediaDestinations()
                    .toolbar(router.chromeHidden ? .hidden : .visible, for: .tabBar)
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch tab {
        case .home: HomeView()
        case .search: BrowseView()
        case .downloads: DownloadsView()
        case .library: LibraryView()
        case .settings: SettingsView()
        case .schedule: ScheduleView()
        }
    }
}

extension View {
    /// Every stack opens a `Media` and the shared routes the same way, so any poster anywhere
    /// can be a NavigationLink.
    func mediaDestinations() -> some View {
        navigationDestination(for: Media.self) { DetailView(media: $0) }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .schedule: ScheduleView()
                case .notifications: NotificationsView()
                case .settings(let page): SettingsPageView(page: page)
                case .settingsRow(let page, let row): SettingsPageView(page: page, spotlight: row)
                case .debugLog: DebugLogView()
                }
            }
    }
}
#endif
