import ActivityKit
import SwiftUI
import WidgetKit
import AnililiCore

@main
struct AnililiWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                    Text("تنزيل الحلقة")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.headline.monospacedDigit())
                }
                Text("\(context.attributes.title) · الحلقة \(context.state.episode)")
                    .lineLimit(1)
                ProgressView(value: context.state.progress)
                if !context.state.source.isEmpty {
                    Text(context.state.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("تنزيل الحلقة \(context.state.episode)")
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
            }
        }
    }
}
