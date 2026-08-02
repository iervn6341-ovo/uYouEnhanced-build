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
    let condensed: Bool

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: condensed ? 5 : 8) {
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
                    .lineLimit(nextLineLimit)
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
            return condensed
                ? .headline.weight(.semibold)
                : .title3.weight(.semibold)
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
        switch presentation {
        case .dynamicIsland:
            return condensed ? 2 : 3
        case .lockScreen:
            return 3
        }
    }

    private var nextLineLimit: Int {
        presentation == .dynamicIsland && condensed ? 1 : 2
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
                // The leading/trailing regions sit directly beneath the sensor
                // housing, and the system clips whatever crosses into it. 8pt
                // was not enough headroom: the icon and its text were being cut
                // off along the top edge once the island expanded.
                DynamicIslandExpandedRegion(.leading) {
                    Label(captionLabel(), systemImage: "captions.bubble.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.vertical, 2)
                }
                .contentMargins(.leading, 16)
                .contentMargins(.top, 18)
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.source.isEmpty {
                        sourceBadge(context.state.source)
                            .padding(.vertical, 2)
                    }
                }
                .contentMargins(.trailing, 14)
                .contentMargins(.top, 18)
                DynamicIslandExpandedRegion(.bottom) {
                    ViewThatFits(in: .vertical) {
                        if !hasDenseExpandedLyrics(context) {
                            expandedCaptionBody(
                                context,
                                showsVideoTitle: true,
                                condensed: false
                            )
                        }
                        expandedCaptionBody(
                            context,
                            showsVideoTitle: false,
                            condensed: false
                        )
                        expandedCaptionBody(
                            context,
                            showsVideoTitle: false,
                            condensed: true
                        )
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: expandedMinimumHeight(context),
                        alignment: .topLeading
                    )
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        accessibilityText(context)
                    )
                }
                .contentMargins([.leading, .trailing], 14)
                .contentMargins(.bottom, 12)
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
                    presentation: .lockScreen,
                    condensed: false
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .padding(.leading, 14)
        .padding(.trailing, 10)
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
        return context.state.line
    }

    private func displayedNextLine(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> String {
        return context.state.nextLine?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @ViewBuilder
    private func expandedCaptionBody(
        _ context: ActivityViewContext<CICaptionActivityAttributes>,
        showsVideoTitle: Bool,
        condensed: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: condensed ? 5 : 8) {
            CaptionLyricStack(
                currentLine: displayedLine(context),
                nextLine: displayedNextLine(context),
                revision: context.state.revision,
                presentation: .dynamicIsland,
                condensed: condensed
            )
            if showsVideoTitle {
                Text(context.state.videoTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func hasDenseExpandedLyrics(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> Bool {
        let currentCount = displayedLine(context).count
        let nextCount = displayedNextLine(context).count
        return currentCount > 28 ||
            nextCount > 32 ||
            currentCount + nextCount > 48
    }

    private func expandedMinimumHeight(
        _ context: ActivityViewContext<CICaptionActivityAttributes>
    ) -> CGFloat {
        let totalCharacters =
            displayedLine(context).count + displayedNextLine(context).count
        if totalCharacters > 72 { return 132 }
        if totalCharacters > 36 { return 112 }
        return displayedNextLine(context).isEmpty ? 88 : 100
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
