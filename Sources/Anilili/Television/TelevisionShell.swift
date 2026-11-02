#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Whether the TV layout is drawing: Settings → App → Layout (Android's `form_factor_preference`),
/// which on Automatic gives it to an iPad in a full or wide window. A property each view that
/// differs reads for itself, so a sheet or a full-screen cover answers the same as the page under it.
struct TelevisionLayout: DynamicProperty {
    @AppStorage(FormFactorPreference.key) private var stored = FormFactorPreference.automatic.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass

    @MainActor var isOn: Bool {
        FormFactorPreference.stored(stored).usesTelevision(isPad: Self.isPad, wideWindow: sizeClass != .compact)
    }

    @MainActor static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

/// Android TV's frame, for the iPad: the top navigation over every page instead of the tab bar,
/// each tab keeping its own stack underneath as the tab bar's do.
struct TelevisionShell: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette
    /// Tabs opened so far: a stack is built on its first visit, as the tab bar builds them, rather
    /// than every tab loading its page at launch.
    @State private var visited: Set<AppTab> = [.home]
    @State private var rollingDice = false
    @State private var showingAccount = false

    var body: some View {
        ZStack {
            ForEach(AppTab.television + [.settings]) { tab in
                if visited.contains(tab) {
                    let showing = router.tab == tab
                    TabStack(tab: tab)
                        .opacity(showing ? 1 : 0)
                        .allowsHitTesting(showing)
                        .accessibilityHidden(!showing)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TelevisionTopBar(
                overArtwork: router.tab == .home && (router.paths[.home]?.isEmpty ?? true) && !router.televisionPastHero,
                onDice: { rollingDice = true },
                onAccount: { showingAccount = true }
            )
        }
        .onAppear { visited.insert(router.tab) }
        .onChange(of: router.tab) { _, tab in visited.insert(tab) }
        .fullScreenCover(isPresented: $rollingDice) {
            RandomDeckView { router.push($0) }
                .environment(\.palette, palette)
                .environment(library)
        }
        .sheet(isPresented: $showingAccount) {
            AccountSheet()
                .environment(\.palette, palette)
                .environment(library)
                .environment(router)
        }
    }
}

/// Android TV's top navigation (`AppTvTopNavigation`): the wordmark, the destinations as labelled
/// pills with the current one filled, then the dice, notifications, Settings and the account.
/// Clear over Home's spotlight, the page colour everywhere else.
private struct TelevisionTopBar: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    let overArtwork: Bool
    let onDice: () -> Void
    let onAccount: () -> Void

    static let height: CGFloat = 68

    var body: some View {
        // The labels come off when the window is too narrow for them (an iPad mini held upright).
        ViewThatFits(in: .horizontal) {
            bar(labelled: true)
            bar(labelled: false)
        }
        .frame(height: Self.height)
        .background(alignment: .top) {
            ZStack {
                if overArtwork {
                    LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                } else {
                    palette.background
                }
            }
            .ignoresSafeArea(edges: .top)
            .animation(.easeInOut(duration: 0.2), value: overArtwork)
        }
    }

    private func bar(labelled: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                router.select(.home)
            } label: {
                Wordmark(height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home")
            .padding(.trailing, labelled ? 22 : 12)
            ForEach(AppTab.television) { tab in
                destination(tab, labelled: labelled)
            }
            Spacer(minLength: 12)
            icon("dice.fill", label: "Pick something at random", action: onDice)
            bell
            icon("gearshape.fill", label: AppTab.settings.label, selected: router.tab == .settings) { router.select(.settings) }
            account
        }
        .padding(.horizontal, 28)
    }

    private func destination(_ tab: AppTab, labelled: Bool) -> some View {
        let selected = router.tab == tab
        return Button {
            router.select(tab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage).font(.system(size: 16, weight: .semibold))
                if labelled {
                    Text(tab.label).font(AppFont.titleSmall.weight(selected ? .bold : .semibold))
                }
            }
            .foregroundStyle(selected ? palette.onSurface : palette.onSurface.opacity(0.72))
            .padding(.horizontal, labelled ? 16 : 12)
            .frame(height: 44)
            .background {
                if selected {
                    Capsule().fill(palette.onSurface.opacity(0.16))
                        .overlay(Capsule().strokeBorder(palette.onSurface.opacity(0.22), lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func icon(_ systemImage: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.onSurface.opacity(selected ? 1 : 0.85))
                .frame(width: 44, height: 44)
                .background {
                    if selected { Circle().fill(palette.onSurface.opacity(0.16)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var bell: some View {
        let unread = AccountStore.shared.unreadNotifications
        return icon("bell.fill", label: unread > 0 ? "Notifications, \(unread) unread" : "Notifications") {
            router.push(Route.notifications)
        }
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Color.red, in: Capsule())
                    .offset(x: -2, y: 4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The account's avatar, opening the account sheet; the sign-in page while signed out.
    private var account: some View {
        let store = AccountStore.shared
        return Button {
            if store.isSignedIn {
                onAccount()
            } else {
                router.select(.settings)
                router.push(Route.settings(.accounts), on: .settings)
            }
        } label: {
            Group {
                if store.isSignedIn {
                    RemoteImage(url: store.profile?.avatar) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Text(String((store.profile?.name ?? "A").prefix(1)).uppercased())
                                .font(AppFont.titleMedium.weight(.bold))
                                .foregroundStyle(palette.onPrimary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(palette.primary)
                        }
                    }
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(palette.onSurface.opacity(0.85))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .padding(.leading, 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isSignedIn ? "Your account" : "Sign in")
    }
}
#endif
