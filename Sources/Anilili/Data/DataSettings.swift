#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Data (Android's section): back up and restore in the Android app's format through
/// the Files picker, MyAnimeList XML both ways, the caches, and the viewing history.
struct DataSettings: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette

    /// One line of feedback under the row that caused it, as Android places them.
    struct Notice: Equatable {
        var row: String
        var text: String
        var tone: SettingsNotice.Tone
    }

    enum Importing { case backup, mal }

    @State private var confirmingClear = false
    @State private var backingUp = false
    @State private var includeLogin = false
    @State private var passphrase = BackupCrypto.generatePassphrase()
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var importing: Importing?
    @State private var pending: BackupDocument?
    @State private var restorePassphrase = ""
    @State private var restoring = false
    @State private var notice: Notice?
    @State private var malImport: Task<Void, Never>?
    @State private var malImportStage: String?
    @State private var cacheBytes: Int?
    @State private var confirmingMetadata = false
    @State private var metadataProgress: Double?
    @State private var metadataStage: String?

    var body: some View {
        ActionRow(title: "Back up to a file", detail: "Settings, saved anime, Continue Watching — and your login if you want it") {
            notice = nil
            includeLogin = false
            passphrase = BackupCrypto.generatePassphrase()
            backingUp = true
        }
        noticeRow("Back up to a file")
        ActionRow(title: "Restore from a backup", detail: "Replaces settings; adds saved anime and history to this device", busy: restoring) {
            notice = nil
            importing = .backup
        }
        noticeRow("Restore from a backup")
        ActionRow(title: "Export MyAnimeList XML", detail: "Save your list as a MAL-compatible file") { exportMAL() }
        noticeRow("Export MyAnimeList XML")
        ActionRow(title: malImport == nil ? "Import MyAnimeList XML" : "Cancel import",
                  detail: malImportStage ?? "Add a MAL export to your watchlist", chevron: malImport == nil) {
            if let malImport {
                malImport.cancel()
            } else {
                notice = nil
                importing = .mal
            }
        }
        noticeRow("Import MyAnimeList XML")
        ActionRow(title: "Clear cache", detail: "Images and catalogue pages kept on storage",
                  value: cacheBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                  disabled: (cacheBytes ?? 0) == 0, chevron: false) { clearCache() }
        noticeRow("Clear cache")
        metadataRow
        noticeRow("Re-download metadata")
        ActionRow(title: "Clear viewing history", detail: "Empties Continue Watching on this device", destructive: true,
                  disabled: library.history.shows.isEmpty, chevron: false) {
            confirmingClear = true
        }
        Color.clear.frame(height: 0)
            .task { measureCache() }
            .confirmationDialog("Clear viewing history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { library.clearHistory() }
            } message: {
                Text("Continue Watching and every saved position on this device. Your AniList or MyAnimeList progress stays.")
            }
            .confirmationDialog("Re-download metadata?", isPresented: $confirmingMetadata, titleVisibility: .visible) {
                Button("Re-download") { redownloadMetadata() }
            } message: {
                Text("Fetches the newest catalogue, title IDs and dub info from the metadata index (about 2 MB) and clears cached title details. Your lists, history, downloads and settings stay as they are.")
            }
            .sheet(isPresented: $backingUp) { backupSheet }
            .sheet(item: $pending) { document in restoreSheet(document) }
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportFile?.type ?? .json,
                          defaultFilename: exportFile?.name) { result in
                let row = exportFile?.type == .xml ? "Export MyAnimeList XML" : "Back up to a file"
                switch result {
                case .success(let url):
                    Log.info("backup", "saved \(url.lastPathComponent)")
                    let said = notice?.row == row ? notice?.text : nil
                    notice = Notice(row: row, text: said ?? "Saved \(url.lastPathComponent).", tone: .success)
                case .failure(let error):
                    Log.error("backup", "save failed: \(Log.describe(error))")
                    notice = Notice(row: row, text: "Couldn't save the file: \(error.localizedDescription)", tone: .error)
                }
            }
            .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                          allowedContentTypes: importing == .mal ? [.xml, .gzip, .data] : [.json, .data]) { result in
                let kind = importing ?? .backup
                importing = nil
                switch result {
                case .success(let url):
                    if kind == .mal { importMAL(url) } else { read(url) }
                case .failure(let error):
                    notice = Notice(row: kind == .mal ? "Import MyAnimeList XML" : "Restore from a backup",
                                    text: "Couldn't open the file: \(error.localizedDescription)", tone: .error)
                }
            }
    }

    @ViewBuilder
    private func noticeRow(_ row: String) -> some View {
        if let notice, notice.row == row { SettingsNotice(text: notice.text, tone: notice.tone) }
    }

    /// Android's `MetadataRefreshRow`: while it runs, the row fills from the left like a download.
    private var metadataRow: some View {
        ActionRow(title: metadataProgress == nil ? "Re-download metadata" : "Re-downloading metadata",
                  detail: metadataStage ?? "Get the newest catalogue, title IDs and dub info from the index",
                  value: metadataProgress.map { "\(Int($0 * 100))%" }, disabled: metadataProgress != nil, chevron: metadataProgress == nil) {
            confirmingMetadata = true
        }
        .overlay(alignment: .leading) {
            if let metadataProgress {
                GeometryReader { proxy in
                    palette.primary.opacity(0.16)
                        .frame(width: proxy.size.width * metadataProgress)
                        .animation(.easeOut(duration: 0.25), value: metadataProgress)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Caches and metadata

    private func measureCache() {
        cacheBytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
    }

    private func clearCache() {
        let before = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        URLCache.shared.removeAllCachedResponses()
        let after = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        measureCache()
        let freed = ByteCountFormatter.string(fromByteCount: Int64(max(0, before - after)), countStyle: .file)
        notice = Notice(row: "Clear cache", text: "Freed \(freed)", tone: .success)
        Log.info("data", "cache cleared: \(freed)")
    }

    private func redownloadMetadata() {
        notice = nil
        metadataProgress = 0
        Task {
            func step(_ fraction: Double, _ stage: String) {
                metadataProgress = fraction
                metadataStage = stage
            }
            step(0.05, "Clearing cached title details…")
            await MediaIndex.shared.clear()
            await ScheduleService.shared.clear()
            step(0.2, "Dub index…")
            await DubIndexStore.shared.load()
            step(0.45, "Catalogue of every title…")
            let titles = await LocalCatalog.shared.refresh()
            step(0.75, "Recommendations graph…")
            _ = await MediaIndex.shared.neighbourGraph()
            step(1, "Done")
            try? await Task.sleep(for: .milliseconds(700))
            metadataProgress = nil
            metadataStage = nil
            if let titles {
                notice = Notice(row: "Re-download metadata",
                                text: "Metadata is up to date: \(titles.formatted()) titles, \(DubIndexStore.shared.ids.count.formatted()) with an English dub.",
                                tone: .success)
            } else {
                notice = Notice(row: "Re-download metadata",
                                text: "Couldn't reach the metadata index. Nothing was lost; try again when the connection is better.",
                                tone: .error)
            }
        }
    }

    // MARK: - MyAnimeList import

    /// Android's import: read the export, match its MAL ids with AniList 50 at a time, then save
    /// the matches to the watchlist. Nothing is written until every batch has answered.
    private func importMAL(_ url: URL) {
        malImportStage = "Reading the file…"
        malImport = Task {
            defer {
                malImport = nil
                malImportStage = nil
            }
            let row = "Import MyAnimeList XML"
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                malImportStage = "Reading the export…"
                let entries = try await Task.detached(priority: .userInitiated) { try MALImport.parse(data) }.value
                guard !entries.isEmpty else { throw MALImport.Failure.empty }
                let ids = entries.map(\.malID)
                let batches = stride(from: 0, to: ids.count, by: 50).map { Array(ids[$0..<min($0 + 50, ids.count)]) }
                var found: [Media] = []
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    malImportStage = "Matching titles with AniList · \(index + 1) of \(batches.count)"
                    found += try await AniListClient.shared.media(malIDs: batch)
                }
                try Task.checkCancellation()
                malImportStage = "Saving…"
                var byMAL: [Int: Media] = [:]
                for media in found { if let mal = media.idMal, byMAL[mal] == nil { byMAL[mal] = media } }
                let matched = entries.compactMap { byMAL[$0.malID] }
                let added = library.importWatchlist(matched)
                let summary = MALImport.Summary(total: entries.count, added: added, alreadySaved: matched.count - added,
                                                unmatched: entries.count - matched.count)
                Log.info("mal_import", summary.text)
                notice = Notice(row: row, text: summary.text, tone: .success)
            } catch is CancellationError {
                notice = Notice(row: row, text: "MyAnimeList import cancelled", tone: .info)
            } catch {
                Log.error("mal_import", "failed: \(Log.describe(error))")
                notice = Notice(row: row, text: error.localizedDescription, tone: .error)
            }
        }
    }

    // MARK: - Backing up

    private var backupSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Include my AniList login", isOn: $includeLogin)
                        .tint(palette.switchTint)
                        .disabled(AccountCredentials.shared.anilistToken == nil)
                } footer: {
                    Text(AccountCredentials.shared.anilistToken == nil
                         ? "Sign in to AniList to carry the login in a backup. A MyAnimeList login can't travel in a file made on iOS yet."
                         : "The login is sealed under a passphrase the file never contains. Without it, the backup signs nobody in.")
                }
                if includeLogin {
                    Section {
                        TextField("Passphrase", text: $passphrase)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Suggest another") { passphrase = BackupCrypto.generatePassphrase() }
                    } header: {
                        Text("Passphrase")
                    } footer: {
                        Text("Write it down: you'll need it to restore the login, on iOS or Android. At least \(BackupCrypto.minPassphraseLength) characters.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Back up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { backingUp = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save…") { makeBackup() }
                        .disabled(includeLogin && passphrase.count < BackupCrypto.minPassphraseLength)
                }
            }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
    }

    private func makeBackup() {
        do {
            let document = try BackupService.document(library: library, passphrase: includeLogin ? passphrase : nil)
            exportFile = ExportFile(data: try document.encoded(), type: .json, name: BackupDocument.fileName())
            backingUp = false
            // The exporter can't open while the sheet is still closing.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                exporting = true
            }
        } catch {
            Log.error("backup", "couldn't make a backup: \(Log.describe(error))")
            notice = Notice(row: "Back up to a file", text: error.localizedDescription, tone: .error)
            backingUp = false
        }
    }

    private func exportMAL() {
        let account = AccountStore.shared
        let (entries, skipped) = MALExport.entries(account: account.isSignedIn ? account.library : nil,
                                                   history: library.history, watchlist: library.watchlist)
        guard !entries.isEmpty else {
            notice = Notice(row: "Export MyAnimeList XML", text: "Nothing to export yet: save or watch something first. MyAnimeList only accepts titles with a MAL id.", tone: .info)
            return
        }
        let xml = MALExport.xml(username: account.profile?.name, entries: entries)
        exportFile = ExportFile(data: Data(xml.utf8), type: .xml, name: MALExport.fileName())
        notice = Notice(row: "Export MyAnimeList XML", text: "Exported \(entries.count) anime" + (skipped > 0 ? "; skipped \(skipped) without MAL IDs" : ""), tone: .success)
        Log.info("backup", "MAL export: \(entries.count) entries, \(skipped) skipped")
        exporting = true
    }

    // MARK: - Restoring

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pending = try BackupDocument.decode(data)
            restorePassphrase = ""
            Log.info("backup", "chose \(url.lastPathComponent): \(pending?.summary ?? "")")
        } catch {
            Log.error("backup", "\(url.lastPathComponent) isn't a backup: \(Log.describe(error))")
            notice = Notice(row: "Restore from a backup", text: error.localizedDescription, tone: .error)
        }
    }

    private func restoreSheet(_ document: BackupDocument) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text(document.summary)
                    if document.createdAt > 0 {
                        LabeledContent("Made", value: Date(timeIntervalSince1970: TimeInterval(document.createdAt) / 1000).formatted(date: .abbreviated, time: .shortened))
                    }
                    if !document.appVersion.isEmpty { LabeledContent("By", value: "Anilili \(document.appVersion)") }
                } footer: {
                    Text("Settings become the file's. Saves and history are added to what's here; the newer of two rows wins.")
                }
                if let sealed = document.credentials, !sealed.services.isEmpty {
                    Section {
                        SecureField("Passphrase", text: $restorePassphrase)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Logins: " + sealed.services.map(Self.serviceLabel).joined(separator: ", "))
                    } footer: {
                        Text("Leave it empty to restore everything but the logins.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { pending = nil }.disabled(restoring) }
                ToolbarItem(placement: .topBarTrailing) {
                    if restoring { ProgressView() } else { Button("Restore") { restore(document) } }
                }
            }
        }
        .tint(palette.primary)
        .interactiveDismissDisabled(restoring)
    }

    private func restore(_ document: BackupDocument) {
        restoring = true
        Task {
            do {
                let phrase = restorePassphrase.trimmingCharacters(in: .whitespaces)
                let summary = try await BackupService.restore(document, passphrase: phrase.isEmpty ? nil : phrase, library: library)
                notice = Notice(row: "Restore from a backup",
                                text: "Restored " + summary.text + (summary.warnings.isEmpty ? "" : ". " + summary.warnings.joined(separator: ". ")),
                                tone: summary.warnings.isEmpty ? .success : .warning)
                pending = nil
            } catch {
                Log.error("backup", "restore failed: \(Log.describe(error))")
                // A wrong passphrase keeps the sheet up for another try.
                notice = Notice(row: "Restore from a backup", text: error.localizedDescription, tone: .error)
                if (error as? BackupDocument.BackupError) != .wrongPassphrase { pending = nil }
            }
            restoring = false
        }
    }

    static func serviceLabel(_ name: String) -> String {
        switch name {
        case "anilist": return "AniList"
        case "mal": return "MyAnimeList"
        case "opensubtitles": return "OpenSubtitles"
        default: return name
        }
    }
}

extension BackupDocument: Identifiable {
    public var id: Int64 { createdAt }
}

/// A file handed to the Files exporter.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .xml] }
    var data: Data
    var type: UTType
    var name: String

    init(data: Data, type: UTType, name: String) {
        self.data = data
        self.type = type
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
        name = configuration.file.filename ?? "Anilili"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
