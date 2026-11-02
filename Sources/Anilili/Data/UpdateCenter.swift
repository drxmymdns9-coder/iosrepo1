#if canImport(UIKit)
import AnililiCore
import Observation
import SwiftUI
import UIKit

/// Updates for the sideloaded app (Android's `UpdateManager`, setting `update_check_on_launch`):
/// the signed iOS manifest is read when the app opens and on return to it, at most every five
/// minutes. A new version pops up unless the setting is off; a rebuild of the installed version
/// waits quietly in Settings, as on Android. The check runs either way, so Settings' App tile can
/// show what's waiting for someone who turned the pop-up off.
@MainActor
@Observable
final class UpdateCenter {
    static let shared = UpdateCenter()
    /// Android's key, so a backup carries the choice across.
    static let checkOnLaunchKey = "update_check_on_launch"
    private static let lastCheckKey = "ios_update_last_check"
    /// Android's floor: only there so a burst of returns to the app isn't a burst of requests.
    private static let interval: TimeInterval = 5 * 60

    enum State: Equatable {
        case idle
        case checking
        /// A check asked for found nothing newer; the newest published version.
        case upToDate(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The update on screen.
    var showing: AppUpdate?
    /// Any newer build the last check found, until it's installed: badges Settings → App.
    private(set) var pending: AppUpdate?
    /// A rebuild of the installed version, which only Settings offers.
    private(set) var quiet: AppUpdate?

    static var checkOnLaunch: Bool { UserDefaults.standard.object(forKey: checkOnLaunchKey) as? Bool ?? true }
    static var installedVersion: String { AppInfo.shortVersion }
    static var installedBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// At launch and on return to the app.
    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard last <= 0 || now < last || now - last >= Self.interval else { return }
        check(manual: false)
    }

    /// `manual`: asked for from Settings, which also offers a quiet rebuild and says when there's
    /// nothing newer or the check failed.
    func check(manual: Bool) {
        guard state != .checking else { return }
        state = .checking
        Log.info("update", "check (\(manual ? "manual" : "automatic")); installed \(Self.installedVersion) build \(Self.installedBuild)")
        Task {
            do {
                let update = try await AppUpdate.fetch()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                let offer = UpdateOffer.decide(remoteVersion: update.version, remoteBuild: update.build,
                                               installedVersion: Self.installedVersion, installedBuild: Self.installedBuild)
                quiet = offer == .quiet ? update : nil
                pending = offer == .none ? nil : update
                switch offer {
                case .prompt where manual || Self.checkOnLaunch, .quiet where manual:
                    showing = update
                    state = .idle
                default:
                    state = manual && offer == .none ? .upToDate(update.version) : .idle
                }
                Log.info("update", "published \(UpdateOffer.label(version: update.version, build: update.build)): \(offer)")
            } catch {
                Log.warning("update", "check failed: \(Log.describe(error))")
                // An automatic check that fails stays silent: nobody asked.
                state = manual ? .failed("Couldn't reach the update channel. Try again later.") : .idle
            }
        }
    }

    /// The offered build's name beside the installed one: with build numbers when the versions match.
    static func offeredLabel(_ update: AppUpdate) -> String {
        UpdateOffer.label(version: update.version, build: update.version == installedVersion ? update.build : nil)
    }

    static func installedLabel(_ update: AppUpdate?) -> String {
        UpdateOffer.label(version: installedVersion, build: update?.version == installedVersion ? installedBuild : nil)
    }
}

/// How an IPA reaches the device. iOS gives an app no way to replace itself: the sideloading tool
/// that signed it installs the new one. SideStore and AltStore take a link and do the rest; for
/// Sideloadly the file is downloaded on a computer.
enum UpdateInstaller {
    /// SideStore, then AltStore, then the file in Safari. Calls back with what opened.
    @MainActor static func install(_ file: URL, done: @escaping (String) -> Void) {
        let encoded = file.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file.absoluteString
        let stores = [("SideStore", "sidestore://install?url=\(encoded)"), ("AltStore", "altstore://install?url=\(encoded)")]
        func attempt(_ index: Int) {
            guard index < stores.count, let link = URL(string: stores[index].1) else {
                UIApplication.shared.open(file)
                Log.info("update", "no SideStore or AltStore; opened the file in Safari")
                done("Safari")
                return
            }
            UIApplication.shared.open(link) { opened in
                if opened {
                    Log.info("update", "handed the update to \(stores[index].0)")
                    done(stores[index].0)
                } else {
                    attempt(index + 1)
                }
            }
        }
        attempt(0)
    }
}

/// The update, with its notes (Android's `UpdateDialog`): what's offered against what's installed,
/// the size, the release notes as headings and bullets, and how to install it.
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.palette) private var palette
    let update: AppUpdate
    @State private var handedTo: String?
    @State private var copied = false

    var body: some View {
        let rebuild = update.version == UpdateCenter.installedVersion
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.app.fill").foregroundStyle(palette.primary)
                    Text(rebuild ? "A new build is ready" : "Update available")
                        .font(AppFont.titleLarge)
                        .foregroundStyle(palette.onSurface)
                }
                Text("\(UpdateCenter.offeredLabel(update)) · you have \(UpdateCenter.installedLabel(update))"
                     + (update.sizeBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            ScrollView {
                ReleaseNotesView(text: update.changelog.isEmpty ? "- Fixes and improvements." : update.changelog)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            if let handedTo {
                Text(handedTo == "Safari"
                     ? "The file is downloading in Safari. Install it with SideStore, AltStore or Sideloadly, the way you installed Anilili."
                     : "\(handedTo) is installing it. It signs the update with your Apple ID, as it did the first time.")
                    .font(AppFont.bodySmall)
                    .foregroundStyle(palette.primary)
            }
            VStack(spacing: 10) {
                Button {
                    UpdateInstaller.install(update.url) { handedTo = $0 }
                } label: {
                    Label("Install with SideStore or AltStore", systemImage: "arrow.down.circle.fill")
                        .font(AppFont.labelLarge.weight(.bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(palette.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                HStack(spacing: 10) {
                    Button {
                        openURL(update.url)
                    } label: {
                        Label("Download the file", systemImage: "safari")
                            .font(AppFont.labelLarge)
                            .foregroundStyle(palette.onSurface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay(Capsule().strokeBorder(palette.outline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button {
                        UIPasteboard.general.url = update.url
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                            .font(AppFont.labelLarge)
                            .foregroundStyle(palette.onSurface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay(Capsule().strokeBorder(palette.outline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Button("Later") { dismiss() }
                    .font(AppFont.labelLarge)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            Text("Signed by the Anilili project and checked on this device. Your watch history and settings stay as they are.")
                .font(AppFont.labelSmall)
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(palette.background)
        .presentationDetents([.medium, .large])
        .onAppear { Log.info("update", "showing \(UpdateCenter.offeredLabel(update))") }
    }
}

/// Release notes as Android's `ReleaseNotes` draws them: accent headings, bulleted lines, bold runs.
struct ReleaseNotesView: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ReleaseNotes.parse(text).enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let heading):
                    Text(heading)
                        .font(AppFont.titleSmall.weight(.bold))
                        .foregroundStyle(palette.primary)
                        .padding(.top, index == 0 ? 0 : 8)
                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(palette.primary)
                        Text(Self.styled(line)).foregroundStyle(palette.onSurface)
                    }
                    .font(AppFont.bodyMedium)
                case .paragraph(let line):
                    Text(Self.styled(line))
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
        }
    }

    /// `**bold**` set in bold; anything else as written.
    static func styled(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line.replacingOccurrences(of: "**", with: ""))
    }
}
#endif
