#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UIKit

/// The in-app copy of `Log`, for reading on the device and copying out to whoever is debugging.
struct DebugLogView: View {
    @State private var entries: [Log.Entry] = []
    @State private var minimum: Log.Level = .debug
    @State private var copied = false

    private var shown: [Log.Entry] { entries.filter { $0.level >= minimum } }

    var body: some View {
        List {
            Picker("Level", selection: $minimum) {
                Text("All").tag(Log.Level.debug)
                Text("Info").tag(Log.Level.info)
                Text("Warnings").tag(Log.Level.warning)
                Text("Errors").tag(Log.Level.error)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            ForEach(shown.reversed()) { entry in
                Text(entry.line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(color(entry.level))
                    .textSelection(.enabled)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .background(Theme.background)
        .navigationTitle("Debug log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = Log.export(header: AppInfo.summary)
                    copied = true
                }
                ShareLink(item: Log.export(header: AppInfo.summary)) { Image(systemName: "square.and.arrow.up") }
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        Log.clear()
                        refresh()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: refresh)
        .refreshable { refresh() }
    }

    private func refresh() {
        entries = Log.entries
        copied = false
    }

    private func color(_ level: Log.Level) -> Color {
        switch level {
        case .debug: return Theme.secondaryText
        case .info: return .white
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

/// Facts about the build and device for the top of a copied log.
enum AppInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @MainActor static var summary: String {
        let device = UIDevice.current
        #if targetEnvironment(simulator)
        let kind = "Simulator"
        #else
        let kind = "Device"
        #endif
        return "Anilili iOS \(version) · \(device.model) \(kind) · \(device.systemName) \(device.systemVersion) · \(Date().formatted(.iso8601))"
    }
}
#endif
