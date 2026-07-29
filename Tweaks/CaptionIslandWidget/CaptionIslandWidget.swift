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
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(captionLabel(), systemImage: "captions.bubble.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.source.isEmpty {
                        sourceBadge(context.state.source)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(displayedLine(context))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                            .minimumScaleFactor(0.78)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(context.state.revision)
                        Text(context.state.videoTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 82,
                        alignment: .topLeading
                    )
                    .padding(.top, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(context.state.videoTitle)，\(displayedLine(context))"
                    )
                }
            } compactLeading: {
                if context.state.source.isEmpty {
                    Image(systemName: "captions.bubble.fill")
                        .foregroundStyle(.white)
                        .accessibilityLabel(captionLabel())
                } else {
                    Text(compactSource(context.state.source))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .accessibilityLabel(context.state.source)
                }
            } compactTrailing: {
                Text(compactText(displayedLine(context)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .id(context.state.revision)
            } minimal: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.white)
                    .accessibilityLabel(captionLabel())
            }
            .keylineTint(.white)
        }
    }

    @ViewBuilder
    private func lockScreenView(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "captions.bubble.fill")
                .font(.title)
                .foregroundStyle(.white)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(context.state.videoTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(displayedLine(context))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(context.state.revision)
                if !context.state.source.isEmpty {
                    sourceBadge(context.state.source)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func compactText(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return captionLabel() }
        return String(cleaned.prefix(12))
    }

    private func displayedLine(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> String {
        // Keep the most recently received lyric visible when iOS temporarily
        // marks a local update stale. This is especially important on an
        // Always-On display, where the system may defer visual refreshes.
        return context.state.line
    }

    @ViewBuilder
    private func sourceBadge(_ source: String) -> some View {
        Text(source)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.16), in: Capsule())
    }

    private func compactSource(_ source: String) -> String {
        if source.hasPrefix("LRCLIB") { return "LRC" }
        if source == "ASR" { return "ASR" }
        if source == "CC" { return "CC" }
        return String(source.prefix(3)).uppercased()
    }

    private func captionLabel() -> String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if language.hasPrefix("zh") { return "字幕" }
        if language.hasPrefix("ja") { return "字幕" }
        return "Captions"
    }
}
