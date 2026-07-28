import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CaptionIslandWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaptionIslandLiveActivity()
    }
}

struct CaptionIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CICaptionActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(videoURL(context.state.videoID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(captionLabel(), systemImage: "captions.bubble.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.source.isEmpty {
                        Text(context.state.source)
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayedLine(context))
                            .font(.headline)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(context.state.videoTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(context.state.videoTitle)，\(displayedLine(context))"
                    )
                }
            } compactLeading: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.white)
                    .accessibilityLabel(captionLabel())
            } compactTrailing: {
                Text(compactText(displayedLine(context)))
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.white)
                    .accessibilityLabel(captionLabel())
            }
            .widgetURL(videoURL(context.state.videoID))
            .keylineTint(.white)
        }
    }

    @ViewBuilder
    private func lockScreenView(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.videoTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(displayedLine(context))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !context.state.source.isEmpty {
                    Text(context.state.source)
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func compactText(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return captionLabel() }
        return String(cleaned.prefix(10))
    }

    private func displayedLine(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> String {
        if context.isStale {
            let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if language.hasPrefix("zh") { return "字幕同步已暫停" }
            if language.hasPrefix("ja") { return "字幕同期が一時停止しました" }
            return "Caption sync paused"
        }
        return context.state.line
    }

    private func captionLabel() -> String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if language.hasPrefix("zh") { return "字幕" }
        if language.hasPrefix("ja") { return "字幕" }
        return "Captions"
    }

    private func videoURL(_ videoID: String) -> URL? {
        URL(string: "youtube://watch?v=\(videoID)")
    }
}
