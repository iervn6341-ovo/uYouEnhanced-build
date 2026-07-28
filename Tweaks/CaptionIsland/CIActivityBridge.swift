import ActivityKit
import Foundation

private func activityText(
    traditionalChinese: String,
    english: String,
    japanese: String
) -> String {
    let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
    if language.hasPrefix("zh") { return traditionalChinese }
    if language.hasPrefix("ja") { return japanese }
    return english
}

private func clippedUTF8(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    let ellipsis = "…"
    let budget = max(0, maximumBytes - ellipsis.utf8.count)
    var result = ""
    var usedBytes = 0
    for character in value {
        let fragment = String(character)
        let fragmentBytes = fragment.utf8.count
        guard usedBytes + fragmentBytes <= budget else { break }
        result.append(character)
        usedBytes += fragmentBytes
    }
    return result + ellipsis
}

private func sanitizedActivityText(
    _ value: String,
    maximumBytes: Int
) -> String {
    var sanitized = ""
    var previousWasReplacementSpace = false
    for scalar in value.unicodeScalars {
        if CharacterSet.controlCharacters.contains(scalar) {
            if !previousWasReplacementSpace {
                sanitized.append(" ")
            }
            previousWasReplacementSpace = true
        } else {
            sanitized.unicodeScalars.append(scalar)
            previousWasReplacementSpace = false
        }
    }
    return clippedUTF8(sanitized, maximumBytes: maximumBytes)
}

@objc(CIActivityBridge)
public final class CIActivityBridge: NSObject {
    private static let commandQueue = DispatchQueue(
        label: "com.captionisland.activity.commands"
    )
    private static var commandTail: Task<Void, Never>?

    @objc(isAvailable)
    public static func isAvailable() -> Bool {
        guard #available(iOS 16.1, *) else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    @objc(startWithVideoID:title:)
    public static func start(videoID: String, title: String) {
        guard #available(iOS 16.1, *) else {
            emit(level: "warning", message: "Live Activities require iOS 16.1 or later")
            return
        }
        let safeVideoID = sanitizedActivityText(videoID, maximumBytes: 96)
        let safeTitle = sanitizedActivityText(title, maximumBytes: 384)
        enqueue {
            await CIActivityManager.shared.start(
                videoID: safeVideoID,
                title: safeTitle
            )
        }
    }

    @objc(ensureWithVideoID:title:)
    public static func ensure(videoID: String, title: String) {
        guard #available(iOS 16.1, *) else { return }
        let safeVideoID = sanitizedActivityText(videoID, maximumBytes: 96)
        let safeTitle = sanitizedActivityText(title, maximumBytes: 384)
        enqueue {
            await CIActivityManager.shared.ensure(
                videoID: safeVideoID,
                title: safeTitle
            )
        }
    }

    @objc(updateWithText:source:cueStart:cueEnd:position:playing:)
    public static func update(
        text: String,
        source: String,
        cueStart: Double,
        cueEnd: Double,
        position: Double,
        playing: Bool
    ) {
        guard #available(iOS 16.1, *) else { return }
        let safeText = sanitizedActivityText(text, maximumBytes: 1_024)
        let safeSource = sanitizedActivityText(source, maximumBytes: 64)
        let startMilliseconds = milliseconds(cueStart)
        let endMilliseconds = milliseconds(cueEnd)
        enqueue {
            await CIActivityManager.shared.update(
                line: safeText,
                source: safeSource,
                cueStartMS: startMilliseconds,
                cueEndMS: endMilliseconds,
                position: position,
                isPlaying: playing
            )
        }
    }

    @objc(showGapWithTitle:)
    public static func showGap(title: String) {
        guard #available(iOS 16.1, *) else { return }
        let safeTitle = sanitizedActivityText(title, maximumBytes: 384)
        enqueue {
            await CIActivityManager.shared.showGap(
                title: safeTitle
            )
        }
    }

    @objc(endImmediately:)
    public static func end(immediately: Bool) {
        guard #available(iOS 16.1, *) else { return }
        enqueue {
            await CIActivityManager.shared.end(immediately: immediately)
        }
    }

    fileprivate static func emit(level: String, message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("CIActivityBridgeLogNotification"),
                object: nil,
                userInfo: ["level": level, "message": message]
            )
        }
    }

    private static func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        commandQueue.sync {
            let previous = commandTail
            commandTail = Task {
                if let previous {
                    await previous.value
                }
                await operation()
            }
        }
    }

    private static func milliseconds(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let converted = value * 1000.0
        guard converted.isFinite, converted < Double(Int.max) else {
            return Int.max
        }
        return Int(converted)
    }
}

@available(iOS 16.1, *)
private actor CIActivityManager {
    private struct PayloadEnvelope: Encodable {
        let attributes: CICaptionActivityAttributes
        let state: CICaptionActivityAttributes.ContentState
    }

    static let shared = CIActivityManager()

    private var activity: Activity<CICaptionActivityAttributes>?
    private var videoID = ""
    private var title = "YouTube"
    private var revision = 0
    private var lastLine = ""
    private var lastSource = ""
    private var lastCueStartMS = 0
    private var lastCueEndMS = 0
    private var lastPlaying = true
    private var dismissedVideoID = ""
    private var didLogMissingActivity = false

    func start(videoID: String, title: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            CIActivityBridge.emit(
                level: "warning",
                message: "Live Activities are disabled in iOS Settings"
            )
            return
        }
        if let currentActivity = activity {
            switch currentActivity.activityState {
            case .active, .stale:
                let changedVideo = self.videoID != videoID
                self.videoID = videoID
                self.title = title.isEmpty ? "YouTube" : title
                revision += 1
                lastLine = ""
                lastSource = ""
                lastCueStartMS = 0
                lastCueEndMS = 0
                lastPlaying = true
                await updateState(waitingState())
                didLogMissingActivity = false
                CIActivityBridge.emit(
                    level: changedVideo ? "info" : "debug",
                    message: changedVideo
                        ? "Reused Live Activity for video \(videoID)"
                        : "Reused existing Live Activity"
                )
                return
            case .dismissed:
                dismissedVideoID = self.videoID
                activity = nil
            case .ended:
                activity = nil
            default:
                self.videoID = videoID
                self.title = title.isEmpty ? "YouTube" : title
                revision += 1
                lastLine = ""
                lastSource = ""
                lastCueStartMS = 0
                lastCueEndMS = 0
                lastPlaying = true
                await updateState(waitingState())
                didLogMissingActivity = false
                CIActivityBridge.emit(
                    level: "debug",
                    message: "Deferred reuse while Live Activity is pending"
                )
                return
            }
        }
        if dismissedVideoID == videoID {
            CIActivityBridge.emit(
                level: "debug",
                message: "Live Activity remains dismissed for the current video"
            )
            return
        }
        if dismissedVideoID != videoID {
            dismissedVideoID = ""
        }
        let systemActivities = Activity<CICaptionActivityAttributes>.activities

        self.videoID = videoID
        self.title = title.isEmpty ? "YouTube" : title
        self.revision = 1
        self.lastLine = ""
        self.lastSource = ""
        self.lastCueStartMS = 0
        self.lastCueEndMS = 0
        self.lastPlaying = true
        let state = boundedState(waitingState())

        if let existingActivity = systemActivities.first {
            activity = existingActivity
            for duplicate in systemActivities.dropFirst() {
                await endActivity(duplicate, immediately: true)
            }
            await updateState(state)
            didLogMissingActivity = false
            CIActivityBridge.emit(
                level: "info",
                message: "Adopted existing Live Activity for video \(videoID)"
            )
            return
        }

        let attributes = CICaptionActivityAttributes(sessionID: "caption-island")
        do {
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            } else {
                activity = try Activity.request(
                    attributes: attributes,
                    contentState: state,
                    pushType: nil
                )
            }
            didLogMissingActivity = false
            CIActivityBridge.emit(
                level: "info",
                message: "Started native Live Activity for video \(videoID)"
            )
        } catch {
            activity = nil
            CIActivityBridge.emit(
                level: "error",
                message: "Unable to start Live Activity: \(error.localizedDescription)"
            )
        }
    }

    func ensure(videoID: String, title: String) async {
        if let currentActivity = activity {
            switch currentActivity.activityState {
            case .active, .stale:
                if self.videoID == videoID { return }
            case .dismissed:
                dismissedVideoID = self.videoID
                activity = nil
            case .ended:
                activity = nil
            default:
                if self.videoID == videoID { return }
            }
        }
        await start(videoID: videoID, title: title)
    }

    func update(
        line: String,
        source: String,
        cueStartMS: Int,
        cueEndMS: Int,
        position: Double,
        isPlaying: Bool
    ) async {
        guard hasUpdatableActivity() else {
            if !didLogMissingActivity {
                didLogMissingActivity = true
                CIActivityBridge.emit(
                    level: "warning",
                    message: "Skipped lyric update because no Live Activity is active"
                )
            }
            return
        }
        guard line != lastLine ||
              source != lastSource ||
              cueStartMS != lastCueStartMS ||
              cueEndMS != lastCueEndMS ||
              isPlaying != lastPlaying else { return }
        revision += 1
        lastLine = line
        lastSource = source
        lastCueStartMS = cueStartMS
        lastCueEndMS = cueEndMS
        lastPlaying = isPlaying
        let state = CICaptionActivityAttributes.ContentState(
            line: line,
            source: source,
            videoID: videoID,
            videoTitle: title,
            isPlaying: isPlaying,
            cueStartMS: cueStartMS,
            cueEndMS: cueEndMS,
            revision: revision
        )
        let remaining = max(5.0, min(300.0, Double(cueEndMS) / 1000.0 - position + 12.0))
        await updateState(
            state,
            staleDate: Date().addingTimeInterval(remaining)
        )
    }

    func showGap(title: String) async {
        if !title.isEmpty { self.title = title }
        guard hasUpdatableActivity(), lastLine != "♪" else { return }
        lastLine = "♪"
        lastSource = ""
        lastCueStartMS = 0
        lastCueEndMS = 0
        lastPlaying = true
        revision += 1
        await updateState(
            CICaptionActivityAttributes.ContentState(
                line: "♪",
                source: "",
                videoID: videoID,
                videoTitle: self.title,
                isPlaying: true,
                cueStartMS: 0,
                cueEndMS: 0,
                revision: revision
            )
        )
    }

    func end(immediately: Bool) async {
        let endingActivity = activity
        if let endingActivity {
            await endActivity(endingActivity, immediately: immediately)
        }
        self.activity = nil
        self.videoID = ""
        self.lastLine = ""
        self.lastSource = ""
        self.lastCueStartMS = 0
        self.lastCueEndMS = 0
        self.lastPlaying = true
        self.dismissedVideoID = ""
        self.didLogMissingActivity = false
        if endingActivity != nil {
            CIActivityBridge.emit(level: "info", message: "Ended native Live Activity")
        }
    }

    private func waitingState() -> CICaptionActivityAttributes.ContentState {
        CICaptionActivityAttributes.ContentState(
            line: activityText(
                traditionalChinese: "正在取得字幕…",
                english: "Loading captions…",
                japanese: "字幕を取得中…"
            ),
            source: "",
            videoID: videoID,
            videoTitle: title,
            isPlaying: true,
            cueStartMS: 0,
            cueEndMS: 0,
            revision: revision
        )
    }

    private func updateState(
        _ state: CICaptionActivityAttributes.ContentState,
        staleDate: Date? = nil
    ) async {
        guard let activity else { return }
        let safeState = boundedState(state, attributes: activity.attributes)
        if #available(iOS 16.2, *) {
            await activity.update(
                ActivityContent(state: safeState, staleDate: staleDate)
            )
        } else {
            await activity.update(using: safeState)
        }
    }

    private func boundedState(
        _ initialState: CICaptionActivityAttributes.ContentState,
        attributes explicitAttributes: CICaptionActivityAttributes? = nil
    ) -> CICaptionActivityAttributes.ContentState {
        let attributes = explicitAttributes ??
            activity?.attributes ??
            CICaptionActivityAttributes(sessionID: "caption-island")
        var state = initialState
        let originalState = initialState

        func encodedSize(
            _ candidate: CICaptionActivityAttributes.ContentState
        ) -> Int {
            let envelope = PayloadEnvelope(
                attributes: attributes,
                state: candidate
            )
            return (try? JSONEncoder().encode(envelope).count) ?? Int.max
        }

        for _ in 0..<16 {
            if encodedSize(state) <= 3_200 { break }
            let lineBytes = state.line.utf8.count
            let titleBytes = state.videoTitle.utf8.count
            let videoIDBytes = state.videoID.utf8.count
            let sourceBytes = state.source.utf8.count
            if lineBytes > 128 {
                state.line = clippedUTF8(
                    state.line,
                    maximumBytes: max(128, lineBytes * 3 / 4)
                )
            } else if titleBytes > 64 {
                state.videoTitle = clippedUTF8(
                    state.videoTitle,
                    maximumBytes: max(64, titleBytes * 3 / 4)
                )
            } else if videoIDBytes > 32 {
                state.videoID = clippedUTF8(
                    state.videoID,
                    maximumBytes: max(32, videoIDBytes * 3 / 4)
                )
            } else if sourceBytes > 16 {
                state.source = clippedUTF8(
                    state.source,
                    maximumBytes: max(16, sourceBytes * 3 / 4)
                )
            } else {
                break
            }
        }

        if encodedSize(state) > 3_200 {
            state.line = "…"
            state.source = ""
            state.videoID = clippedUTF8(state.videoID, maximumBytes: 32)
            state.videoTitle = clippedUTF8(state.videoTitle, maximumBytes: 48)
        }
        if state != originalState {
            CIActivityBridge.emit(
                level: "warning",
                message: "Live Activity payload was shortened to stay below 4 KB"
            )
        }
        return state
    }

    private func hasUpdatableActivity() -> Bool {
        guard let activity else { return false }
        switch activity.activityState {
        case .active, .stale:
            return true
        case .dismissed:
            dismissedVideoID = videoID
            self.activity = nil
            CIActivityBridge.emit(
                level: "info",
                message: "Live Activity was dismissed by the user or system"
            )
            return false
        case .ended:
            self.activity = nil
            return false
        default:
            return true
        }
    }

    private func endActivity(
        _ activity: Activity<CICaptionActivityAttributes>,
        immediately: Bool
    ) async {
        let finalState = CICaptionActivityAttributes.ContentState(
            line: lastLine.isEmpty
                ? activityText(
                    traditionalChinese: "播放結束",
                    english: "Playback ended",
                    japanese: "再生終了"
                )
                : lastLine,
            source: lastSource,
            videoID: videoID,
            videoTitle: title,
            isPlaying: false,
            cueStartMS: 0,
            cueEndMS: 0,
            revision: revision + 1
        )
        let state = boundedState(
            finalState,
            attributes: activity.attributes
        )
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .default
        if #available(iOS 16.2, *) {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: policy
            )
        } else {
            await activity.end(using: state, dismissalPolicy: policy)
        }
    }
}
