import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CaptionIslandWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaptionIslandLiveActivity()
    }
}

private struct CaptionLyricStack: View {
    enum Presentation {
        case dynamicIsland
        case lockScreen
    }

    let currentLine: String
    let nextLine: String
    let revision: Int
    let presentation: Presentation

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentLine)
                .font(currentFont)
                .foregroundStyle(.white)
                .lineLimit(currentLineLimit)
                .minimumScaleFactor(0.76)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("current-\(revision)")
                .transition(
                    .asymmetric(
                        insertion: .push(from: .bottom).combined(with: .opacity),
                        removal: .push(from: .top).combined(with: .opacity)
                    )
                )

            if !nextLine.isEmpty {
                Text(nextLine)
                    .font(nextFont)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("next-\(revision)")
                    .transition(
                        .asymmetric(
                            insertion: .push(from: .bottom).combined(with: .opacity),
                            removal: .push(from: .top).combined(with: .opacity)
                        )
                    )
            }
        }
        // WidgetKit intentionally disables animations on Always-On displays.
        // Supplying nil there avoids asking the renderer to do work it will
        // discard; awake Lock Screen and Dynamic Island updates still slide.
        .animation(
            isLuminanceReduced ? nil : .easeInOut(duration: 0.42),
            value: revision
        )
    }

    private var currentFont: Font {
        switch presentation {
        case .dynamicIsland:
            return .title3.weight(.semibold)
        case .lockScreen:
            return .title3.weight(.bold)
        }
    }

    private var nextFont: Font {
        switch presentation {
        case .dynamicIsland:
            return .subheadline.weight(.medium)
        case .lockScreen:
            return .subheadline.weight(.medium)
        }
    }

    private var currentLineLimit: Int {
        presentation == .dynamicIsland ? 2 : 3
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
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionLyricStack(
                            currentLine: displayedLine(context),
                            nextLine: displayedNextLine(context),
                            revision: context.state.revision,
                            presentation: .dynamicIsland
                        )
                        Text(context.state.videoTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 110,
                        alignment: .topLeading
                    )
                    .padding(.top, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        accessibilityText(context)
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
                HStack(spacing: 8) {
                    Text(context.state.videoTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !context.state.source.isEmpty {
                        sourceBadge(context.state.source)
                    }
                }
                CaptionLyricStack(
                    currentLine: displayedLine(context),
                    nextLine: displayedNextLine(context),
                    revision: context.state.revision,
                    presentation: .lockScreen
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(context))
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

    private func displayedNextLine(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> String {
        context.state.nextLine?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func accessibilityText(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> String {
        let next = displayedNextLine(context)
        if next.isEmpty {
            return "\(context.state.videoTitle)，\(displayedLine(context))"
        }
        return "\(context.state.videoTitle)，\(displayedLine(context))，下一句，\(next)"
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
