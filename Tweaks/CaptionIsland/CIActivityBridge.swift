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
    private static let metadataLogLock = NSLock()
    private static var didReportMissingSupportKey = false
    private static var didReportBundleIdentifierWarning = false
    private static let installedWidgetBundleIdentifierWarning: String? = {
        let appBundle = Bundle.main
        let appBundleID = appBundle.bundleIdentifier ?? "unknown"
        let widgetURL = (appBundle.builtInPlugInsURL ??
            appBundle.bundleURL.appendingPathComponent(
                "PlugIns",
                isDirectory: true
            )).appendingPathComponent(
                "CaptionIslandWidget.appex",
                isDirectory: true
            )
        guard let widgetBundle = Bundle(url: widgetURL) else { return nil }
        let widgetBundleID = widgetBundle.bundleIdentifier ?? "unknown"
        let expectedWidgetBundleID = "\(appBundleID).CaptionIslandWidget"
        guard widgetBundleID != expectedWidgetBundleID else { return nil }
        return "widget bundle ID is \(widgetBundleID), expected "
            + "\(expectedWidgetBundleID). The sideload signer may have "
            + "rewritten the extension identifier; ActivityKit will still be attempted."
    }()
    private static let installedTargetMetadataIssue: String? = {
        let appBundle = Bundle.main
        let appBundleID = appBundle.bundleIdentifier ?? "unknown"
        let appSupportValue = appBundle.object(
            forInfoDictionaryKey: "NSSupportsLiveActivities"
        )
        guard (appSupportValue as? NSNumber)?.boolValue == true else {
            let value = appSupportValue.map { String(describing: $0) } ?? "missing"
            return "main app \(appBundleID) has NSSupportsLiveActivities=\(value)"
        }

        let plugInsURL = appBundle.builtInPlugInsURL ??
            appBundle.bundleURL.appendingPathComponent(
                "PlugIns",
                isDirectory: true
            )
        let widgetURL = plugInsURL.appendingPathComponent(
            "CaptionIslandWidget.appex",
            isDirectory: true
        )
        guard let widgetBundle = Bundle(url: widgetURL) else {
            return "CaptionIslandWidget.appex is missing or has an unreadable Info.plist"
        }

        let widgetBundleID = widgetBundle.bundleIdentifier ?? "unknown"

        let widgetSupportValue = widgetBundle.object(
            forInfoDictionaryKey: "NSSupportsLiveActivities"
        )
        guard (widgetSupportValue as? NSNumber)?.boolValue == true else {
            let value = widgetSupportValue.map { String(describing: $0) } ?? "missing"
            return "widget \(widgetBundleID) has NSSupportsLiveActivities=\(value)"
        }

        let extensionDictionary = widgetBundle.object(
            forInfoDictionaryKey: "NSExtension"
        ) as? [String: Any]
        let extensionPoint = extensionDictionary?[
            "NSExtensionPointIdentifier"
        ] as? String
        guard extensionPoint == "com.apple.widgetkit-extension" else {
            return "widget extension point is \(extensionPoint ?? "missing")"
        }
        return nil
    }()

    @objc(isAvailable)
    public static func isAvailable() -> Bool {
        targetSupportsLiveActivities(logIfMissing: false) &&
            ActivityAuthorizationInfo().areActivitiesEnabled
    }

    @objc(startWithVideoID:title:)
    public static func start(videoID: String, title: String) {
        guard targetSupportsLiveActivities(logIfMissing: true) else { return }
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
        guard targetSupportsLiveActivities(logIfMissing: true) else { return }
        let safeVideoID = sanitizedActivityText(videoID, maximumBytes: 96)
        let safeTitle = sanitizedActivityText(title, maximumBytes: 384)
        enqueue {
            await CIActivityManager.shared.ensure(
                videoID: safeVideoID,
                title: safeTitle
            )
        }
    }

    @objc(updateWithText:source:cueStart:cueEnd:position:playing:nextText:nextCueStart:nextCueEnd:)
    public static func update(
        text: String,
        source: String,
        cueStart: Double,
        cueEnd: Double,
        position: Double,
        playing: Bool,
        nextText: String,
        nextCueStart: Double,
        nextCueEnd: Double
    ) {
        guard targetSupportsLiveActivities(logIfMissing: false) else { return }
        let safeText = sanitizedActivityText(text, maximumBytes: 1_024)
        let safeNextText = sanitizedActivityText(
            nextText,
            maximumBytes: 1_024
        )
        let safeSource = sanitizedActivityText(source, maximumBytes: 64)
        let startMilliseconds = milliseconds(cueStart)
        let endMilliseconds = milliseconds(cueEnd)
        let nextStartMilliseconds = milliseconds(nextCueStart)
        let nextEndMilliseconds = milliseconds(nextCueEnd)
        enqueue {
            await CIActivityManager.shared.update(
                line: safeText,
                source: safeSource,
                cueStartMS: startMilliseconds,
                cueEndMS: endMilliseconds,
                nextLine: safeNextText,
                nextCueStartMS: nextStartMilliseconds,
                nextCueEndMS: nextEndMilliseconds,
                position: position,
                isPlaying: playing
            )
        }
    }

    @objc(configureRemoteTimelineWithCues:source:position:duration:)
    public static func configureRemoteTimeline(
        cues: NSArray,
        source: String,
        position: Double,
        duration: Double
    ) {
        guard JSONSerialization.isValidJSONObject(cues),
              let cueData = try? JSONSerialization.data(
                withJSONObject: cues
              ) else { return }
        let safeSource = sanitizedActivityText(
            source,
            maximumBytes: 64
        )
        enqueue {
            await CIActivityPushClient.shared.configureTimeline(
                cueData: cueData,
                source: safeSource,
                position: position,
                duration: duration
            )
        }
    }

    @objc(syncRemotePlaybackAtPosition:playing:rate:force:)
    public static func syncRemotePlayback(
        position: Double,
        playing: Bool,
        rate: Double,
        force: Bool
    ) {
        enqueue {
            await CIActivityPushClient.shared.synchronizePlayback(
                position: position,
                isPlaying: playing,
                playbackRate: rate,
                force: force
            )
        }
    }

    @objc(syncRemotePlaybackCriticalAtPosition:playing:rate:expectedVideoID:completion:)
    public static func syncRemotePlaybackCritical(
        position: Double,
        playing: Bool,
        rate: Double,
        expectedVideoID: String,
        completion: @escaping (Bool) -> Void
    ) {
        let safeVideoID = sanitizedActivityText(
            expectedVideoID,
            maximumBytes: 128
        )
        guard !safeVideoID.isEmpty else {
            DispatchQueue.main.async {
                completion(false)
            }
            return
        }
        enqueue {
            let attempted = await CIActivityManager.shared
                .synchronizeRemotePlaybackCritical(
                position: position,
                playing: playing,
                rate: rate,
                expectedVideoID: safeVideoID
            )
            DispatchQueue.main.async {
                completion(attempted)
            }
        }
    }

    @objc(clearRemoteTimelineAtPosition:duration:)
    public static func clearRemoteTimeline(
        position: Double,
        duration: Double
    ) {
        enqueue {
            await CIActivityPushClient.shared.clearTimeline(
                position: position,
                duration: duration
            )
        }
    }

    @objc(refreshPushConfiguration)
    public static func refreshPushConfiguration() {
        enqueue {
            await CIActivityManager.shared.refreshPushConfiguration()
        }
    }

    @objc(showGapWithTitle:)
    public static func showGap(title: String) {
        guard targetSupportsLiveActivities(logIfMissing: false) else { return }
        let safeTitle = sanitizedActivityText(title, maximumBytes: 384)
        enqueue {
            await CIActivityManager.shared.showGap(
                title: safeTitle
            )
        }
    }

    @objc(endImmediately:)
    public static func end(immediately: Bool) {
        guard targetSupportsLiveActivities(logIfMissing: false) else { return }
        enqueue {
            await CIActivityManager.shared.end(immediately: immediately)
        }
    }

    /// Process termination has a very small execution window. Bypass the
    /// ordinary serialized command tail so queued lyric updates can't delay
    /// the immediate ActivityKit dismissal request.
    @objc(endAllImmediatelyForTermination)
    public static func endAllImmediatelyForTermination() {
        let completion = DispatchSemaphore(value: 0)
        Task.detached(priority: .high) {
            let activities =
                Activity<CICaptionActivityAttributes>.activities
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + 0.8)
    }

    static func emit(level: String, message: String) {
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

    private static func targetSupportsLiveActivities(
        logIfMissing: Bool
    ) -> Bool {
        if logIfMissing, let warning = installedWidgetBundleIdentifierWarning {
            metadataLogLock.lock()
            let shouldReportWarning = !didReportBundleIdentifierWarning
            didReportBundleIdentifierWarning = true
            metadataLogLock.unlock()
            if shouldReportWarning {
                emit(level: "warning", message: warning)
            }
        }
        guard let issue = installedTargetMetadataIssue else { return true }
        guard logIfMissing else { return false }

        metadataLogLock.lock()
        let shouldReport = !didReportMissingSupportKey
        didReportMissingSupportKey = true
        metadataLogLock.unlock()
        guard shouldReport else { return false }

        emit(
            level: "error",
            message: "Installed target cannot start Live Activities: \(issue). "
                + "Reinstall an IPA that passed the Caption Island metadata check."
        )
        return false
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

private actor CIActivityManager {
    private static let pushSessionID =
        "caption-island-push-v1"
    private static let localSessionID =
        "caption-island-local-v1"

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
    private var lastNextLine = ""
    private var lastNextCueStartMS = 0
    private var lastNextCueEndMS = 0
    private var lastPlaying = true
    private var dismissedVideoID = ""
    private var didLogMissingActivity = false
    private var isStartBlockedByUnsupportedTarget = false
    private var lastUpdateHeartbeatUptime: TimeInterval = 0
    private var pushTokenTask: Task<Void, Never>?
    private var pushTokenTimeoutTask: Task<Void, Never>?
    private var frequentPushPermissionTask: Task<Void, Never>?
    private var activityStateTask: Task<Void, Never>?
    private var pushTokenActivityID = ""
    private var pushObservationGeneration = 0

    func start(videoID: String, title: String) async {
        guard !isStartBlockedByUnsupportedTarget else { return }
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
                lastNextLine = ""
                lastNextCueStartMS = 0
                lastNextCueEndMS = 0
                lastPlaying = true
                await updateState(waitingState())
                await CIActivityPushClient.shared.updateVideo(
                    videoID: videoID,
                    title: self.title
                )
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
                await releaseInactiveActivity(currentActivity)
            case .ended:
                await releaseInactiveActivity(currentActivity)
            default:
                self.videoID = videoID
                self.title = title.isEmpty ? "YouTube" : title
                revision += 1
                lastLine = ""
                lastSource = ""
                lastCueStartMS = 0
                lastCueEndMS = 0
                lastNextLine = ""
                lastNextCueStartMS = 0
                lastNextCueEndMS = 0
                lastPlaying = true
                await updateState(waitingState())
                await CIActivityPushClient.shared.updateVideo(
                    videoID: videoID,
                    title: self.title
                )
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
        self.lastNextLine = ""
        self.lastNextCueStartMS = 0
        self.lastNextCueEndMS = 0
        self.lastPlaying = true
        let state = boundedState(waitingState())

        let relayRequested =
            await CIActivityPushClient.shared.isConfigured()
        let desiredSessionID = relayRequested
            ? Self.pushSessionID
            : Self.localSessionID
        let existingActivity = systemActivities.first {
            $0.attributes.sessionID == desiredSessionID
        }
        if let existingActivity {
            activity = existingActivity
            for duplicate in systemActivities
                where duplicate.id != existingActivity.id {
                await endActivity(duplicate, immediately: true)
            }
            await updateState(state)
            await observePushUpdates(for: existingActivity)
            didLogMissingActivity = false
            CIActivityBridge.emit(
                level: "info",
                message: "Adopted existing Live Activity for video \(videoID)"
            )
            return
        }
        for legacyActivity in systemActivities {
            await endActivity(
                legacyActivity,
                immediately: true
            )
        }

        if relayRequested {
            let pushAttributes = CICaptionActivityAttributes(
                sessionID: Self.pushSessionID
            )
            do {
                activity = try Activity.request(
                    attributes: pushAttributes,
                    content: ActivityContent(
                        state: state,
                        staleDate: nil,
                        relevanceScore: 1
                    ),
                    pushType: .token
                )
                if let activity {
                    await observePushUpdates(for: activity)
                }
                didLogMissingActivity = false
                CIActivityBridge.emit(
                    level: "info",
                    message: "Started token-enabled native Live Activity "
                        + "for video \(videoID)"
                )
                return
            } catch {
                CIActivityBridge.emit(
                    level: "warning",
                    message: "Token-enabled Live Activity request failed "
                        + "(\(error.localizedDescription)); trying the "
                        + "local-update fallback."
                )
            }
        }

        await startLocalActivity(state: state)
    }

    private func startLocalActivity(
        state: CICaptionActivityAttributes.ContentState
    ) async {
        do {
            activity = try Activity.request(
                attributes: CICaptionActivityAttributes(
                    sessionID: Self.localSessionID
                ),
                content: ActivityContent(
                    state: state,
                    staleDate: nil,
                    relevanceScore: 1
                ),
                pushType: nil
            )
            if let activity {
                await observePushUpdates(for: activity)
            }
            didLogMissingActivity = false
            CIActivityBridge.emit(
                level: "info",
                message: "Started local-update Live Activity "
                    + "for video \(videoID)"
            )
        } catch {
            activity = nil
            let description = error.localizedDescription
            let normalizedDescription =
                description.lowercased()
            if normalizedDescription.contains(
                "nssupportsliveactivities"
            ) ||
                normalizedDescription.contains(
                    "unsupportedtarget"
                ) {
                isStartBlockedByUnsupportedTarget = true
            }
            CIActivityBridge.emit(
                level: "error",
                message: "Unable to start Live Activity: "
                    + "\(description)"
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
                await releaseInactiveActivity(currentActivity)
            case .ended:
                await releaseInactiveActivity(currentActivity)
            default:
                if self.videoID == videoID { return }
            }
        }
        await start(videoID: videoID, title: title)
    }

    func refreshPushConfiguration() async {
        await CIActivityPushClient.shared.refreshConfiguration()
        let relayIsConfigured =
            await CIActivityPushClient.shared.isConfigured()
        guard let currentActivity = activity else {
            return
        }
        let desiredSessionID = relayIsConfigured
            ? Self.pushSessionID
            : Self.localSessionID
        guard currentActivity.attributes.sessionID !=
                desiredSessionID else { return }
        let currentVideoID = videoID
        let currentTitle = title
        stopPushObservation()
        if currentActivity.attributes.sessionID ==
            Self.pushSessionID {
            await CIActivityPushClient.shared.endActivity(
                activityID: currentActivity.id
            )
        }
        await endActivity(currentActivity, immediately: true)
        activity = nil
        CIActivityBridge.emit(
            level: "info",
            message: relayIsConfigured
                ? "Recreating the current Live Activity with "
                    + "pushType .token after relay configuration changed."
                : "Recreating the current Live Activity in local-update "
                    + "mode after the push relay was disabled."
        )
        await start(
            videoID: currentVideoID,
            title: currentTitle
        )
    }

    func synchronizeRemotePlaybackCritical(
        position: Double,
        playing: Bool,
        rate: Double,
        expectedVideoID: String
    ) async -> Bool {
        guard !expectedVideoID.isEmpty,
              videoID == expectedVideoID,
              let activity,
              activity.attributes.sessionID == Self.pushSessionID else {
            return false
        }
        switch activity.activityState {
        case .dismissed, .ended:
            return false
        default:
            break
        }
        return await CIActivityPushClient.shared
            .synchronizePlaybackAndFlushCritical(
                position: position,
                isPlaying: playing,
                playbackRate: rate,
                expectedVideoID: expectedVideoID,
                expectedActivityID: activity.id
            )
    }

    private func observePushUpdates(
        for observedActivity:
            Activity<CICaptionActivityAttributes>
    ) async {
        stopPushObservation()
        let observedActivityID = observedActivity.id
        let observationGeneration = pushObservationGeneration
        activityStateTask = Task {
            for await state in observedActivity.activityStateUpdates {
                guard !Task.isCancelled,
                      self.isCurrentPushObservation(
                        activityID: observedActivityID,
                        generation: observationGeneration
                      ) else {
                    return
                }
                switch state {
                case .dismissed:
                    await self.observedActivityBecameInactive(
                        activityID: observedActivityID,
                        dismissed: true
                    )
                    return
                case .ended:
                    await self.observedActivityBecameInactive(
                        activityID: observedActivityID,
                        dismissed: false
                    )
                    return
                default:
                    continue
                }
            }
        }
        guard observedActivity.attributes.sessionID ==
                Self.pushSessionID else {
            return
        }
        pushTokenActivityID = ""
        await CIActivityPushClient.shared.setActivity(
            activityID: observedActivityID,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            videoID: videoID,
            title: title,
            frequentPushesEnabled:
                ActivityAuthorizationInfo()
                    .frequentPushesEnabled
        )
        guard isCurrentPushObservation(
            activityID: observedActivityID,
            generation: observationGeneration
        ) else {
            return
        }
        await CIActivityPushClient.shared.refreshConfiguration()
        guard isCurrentPushObservation(
            activityID: observedActivityID,
            generation: observationGeneration
        ) else {
            return
        }
        if let token = observedActivity.pushToken {
            await didReceivePushToken(
                token,
                activityID: observedActivityID
            )
            guard isCurrentPushObservation(
                activityID: observedActivityID,
                generation: observationGeneration
            ) else {
                return
            }
        }
        pushTokenTask = Task {
            for await token in observedActivity.pushTokenUpdates {
                guard !Task.isCancelled,
                      self.isCurrentPushObservation(
                        activityID: observedActivityID,
                        generation: observationGeneration
                      ) else {
                    return
                }
                await self.didReceivePushToken(
                    token,
                    activityID: observedActivityID
                )
            }
        }
        frequentPushPermissionTask = Task {
            let authorizationInfo = ActivityAuthorizationInfo()
            for await enabled in
                authorizationInfo.frequentPushEnablementUpdates {
                guard !Task.isCancelled,
                      self.isCurrentPushObservation(
                        activityID: observedActivityID,
                        generation: observationGeneration
                      ) else {
                    return
                }
                await CIActivityPushClient.shared
                    .updateFrequentPushesEnabled(enabled)
                CIActivityBridge.emit(
                    level: enabled ? "info" : "warning",
                    message: enabled
                        ? "Frequent Live Activity push updates are enabled."
                        : "Frequent Live Activity push updates are disabled "
                            + "in iOS Settings; the relay will use a "
                            + "lower-priority schedule."
                )
            }
        }
        pushTokenTimeoutTask = Task {
            try? await Task.sleep(
                nanoseconds: 8_000_000_000
            )
            guard !Task.isCancelled,
                  self.isCurrentPushObservation(
                    activityID: observedActivityID,
                    generation: observationGeneration
                  ) else {
                return
            }
            self.reportMissingPushToken(
                activityID: observedActivityID
            )
        }
    }

    private func didReceivePushToken(
        _ token: Data,
        activityID: String
    ) async {
        guard activity?.id == activityID else { return }
        pushTokenActivityID = activityID
        pushTokenTimeoutTask?.cancel()
        pushTokenTimeoutTask = nil
        await CIActivityPushClient.shared.receivePushToken(
            token,
            activityID: activityID
        )
    }

    private func reportMissingPushToken(
        activityID: String
    ) {
        guard UserDefaults.standard.bool(
            forKey: "CaptionIsland.PushRelayEnabled"
        ),
        activity?.id == activityID,
        pushTokenActivityID != activityID else {
            return
        }
        CIActivityBridge.emit(
            level: "warning",
            message: "ActivityKit did not deliver a push token for "
                + "activity \(activityID). Verify the installed host "
                + "signature has a provisioning-authorized "
                + "aps-environment entitlement and uses an App ID "
                + "owned by the relay's Apple Developer Team."
        )
    }

    private func stopPushObservation(
        cancelActivityStateTask: Bool = true
    ) {
        pushObservationGeneration &+= 1
        pushTokenTask?.cancel()
        pushTokenTask = nil
        pushTokenTimeoutTask?.cancel()
        pushTokenTimeoutTask = nil
        frequentPushPermissionTask?.cancel()
        frequentPushPermissionTask = nil
        if cancelActivityStateTask {
            activityStateTask?.cancel()
        }
        activityStateTask = nil
        pushTokenActivityID = ""
    }

    private func isCurrentPushObservation(
        activityID: String,
        generation: Int
    ) -> Bool {
        pushObservationGeneration == generation &&
            activity?.id == activityID
    }

    private func releaseInactiveActivity(
        _ inactiveActivity:
            Activity<CICaptionActivityAttributes>
    ) async {
        let activityID = inactiveActivity.id
        stopPushObservation()
        await CIActivityPushClient.shared.endActivity(
            activityID: activityID
        )
        if activity?.id == activityID {
            activity = nil
        }
    }

    private func observedActivityBecameInactive(
        activityID: String,
        dismissed: Bool
    ) async {
        guard activity?.id == activityID else { return }
        let usesPushRelay =
            activity?.attributes.sessionID == Self.pushSessionID
        if dismissed {
            dismissedVideoID = videoID
        }
        // This method runs inside activityStateTask. Do not cancel that task
        // before its awaited DELETE has finished.
        stopPushObservation(cancelActivityStateTask: false)
        let relayCleanupResult: CIRelayCleanupResult
        if usesPushRelay {
            relayCleanupResult =
                await CIActivityPushClient.shared.endActivity(
                    activityID: activityID
                )
        } else {
            relayCleanupResult = .confirmed
        }
        guard activity?.id == activityID else { return }
        activity = nil
        let lifecycleDescription = dismissed
            ? "Live Activity was dismissed"
            : "Live Activity ended"
        guard usesPushRelay else {
            CIActivityBridge.emit(
                level: "info",
                message: "\(lifecycleDescription)."
            )
            return
        }
        switch relayCleanupResult {
        case .confirmed:
            CIActivityBridge.emit(
                level: "info",
                message: "\(lifecycleDescription); the relay schedule "
                    + "was cleaned up."
            )
        case .queued:
            CIActivityBridge.emit(
                level: "info",
                message: "\(lifecycleDescription); APNs end delivery "
                    + "is queued for relay retry."
            )
        case .unconfirmed:
            CIActivityBridge.emit(
                level: "warning",
                message: "\(lifecycleDescription); immediate relay "
                    + "cleanup could not be confirmed, so the "
                    + "server-side safety expiry remains active."
            )
        }
    }

    func update(
        line: String,
        source: String,
        cueStartMS: Int,
        cueEndMS: Int,
        nextLine: String,
        nextCueStartMS: Int,
        nextCueEndMS: Int,
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
              nextLine != lastNextLine ||
              nextCueStartMS != lastNextCueStartMS ||
              nextCueEndMS != lastNextCueEndMS ||
              isPlaying != lastPlaying else { return }
        let shouldReportSource = lastLine.isEmpty || source != lastSource
        revision += 1
        lastLine = line
        lastSource = source
        lastCueStartMS = cueStartMS
        lastCueEndMS = cueEndMS
        lastNextLine = nextLine
        lastNextCueStartMS = nextCueStartMS
        lastNextCueEndMS = nextCueEndMS
        lastPlaying = isPlaying
        let state = CICaptionActivityAttributes.ContentState(
            line: line,
            source: source,
            videoID: videoID,
            videoTitle: title,
            isPlaying: isPlaying,
            cueStartMS: cueStartMS,
            cueEndMS: cueEndMS,
            nextLine: nextLine.isEmpty ? nil : nextLine,
            nextCueStartMS: nextLine.isEmpty ? nil : nextCueStartMS,
            nextCueEndMS: nextLine.isEmpty ? nil : nextCueEndMS,
            revision: revision
        )
        // Background-audio processes can have subsequent local ActivityKit
        // updates deferred after the screen turns off. Pre-schedule one
        // system-owned handoff so the already-delivered next line can replace
        // the current line at its cue boundary even if the host update is
        // temporarily budgeted. A later normal update clears the stale state.
        let staleDate = nextLineHandoffDate(
            position: position,
            nextCueStartMS: nextCueStartMS,
            isPlaying: isPlaying
        )
        await updateState(state, staleDate: staleDate)
        if shouldReportSource {
            CIActivityBridge.emit(
                level: "info",
                message: "Live Activity is displaying source "
                    + (source.isEmpty ? "unlabeled captions" : source)
            )
        }
    }

    func showGap(title: String) async {
        if !title.isEmpty { self.title = title }
        guard hasUpdatableActivity(), lastLine != "♪" else { return }
        lastLine = "♪"
        lastSource = ""
        lastCueStartMS = 0
        lastCueEndMS = 0
        lastNextLine = ""
        lastNextCueStartMS = 0
        lastNextCueEndMS = 0
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
        stopPushObservation()
        if let endingActivity {
            await CIActivityPushClient.shared.endActivity(
                activityID: endingActivity.id
            )
        }
        self.activity = nil
        self.videoID = ""
        self.lastLine = ""
        self.lastSource = ""
        self.lastCueStartMS = 0
        self.lastCueEndMS = 0
        self.lastNextLine = ""
        self.lastNextCueStartMS = 0
        self.lastNextCueEndMS = 0
        self.lastPlaying = true
        self.dismissedVideoID = ""
        self.didLogMissingActivity = false
        self.lastUpdateHeartbeatUptime = 0
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
        let content = ActivityContent(
            state: safeState,
            staleDate: staleDate,
            relevanceScore: 1
        )
        // Use the baseline ActivityKit update API because some standalone
        // Theos iOS 17.5 SDK distributions don't expose the newer timestamp
        // overload in their Swift interface. Revision remains part of every
        // state, so rapid cue changes are still distinct and ordered.
        await activity.update(content)
        CIActivityBridge.emit(
            level: "debug",
            message: "Submitted Live Activity revision \(safeState.revision) "
                + "(\(safeState.source.isEmpty ? "gap" : safeState.source))"
        )
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastUpdateHeartbeatUptime >= 30 {
            lastUpdateHeartbeatUptime = uptime
            CIActivityBridge.emit(
                level: "info",
                message: "Live Activity update pipeline is active at revision "
                    + "\(safeState.revision) (\(activity.activityState))"
            )
        }
    }

    private func nextLineHandoffDate(
        position: Double,
        nextCueStartMS: Int,
        isPlaying: Bool
    ) -> Date? {
        guard isPlaying, position.isFinite, position >= 0,
              nextCueStartMS > 0 else {
            return nil
        }
        let delay = Double(nextCueStartMS) / 1_000.0 - position
        guard delay >= 0.25, delay <= 120 else { return nil }
        return Date().addingTimeInterval(delay)
    }

    private func boundedState(
        _ initialState: CICaptionActivityAttributes.ContentState,
        attributes explicitAttributes: CICaptionActivityAttributes? = nil
    ) -> CICaptionActivityAttributes.ContentState {
        let attributes = explicitAttributes ??
            activity?.attributes ??
            CICaptionActivityAttributes(
                sessionID: Self.pushSessionID
            )
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
            let nextLineBytes = state.nextLine?.utf8.count ?? 0
            let titleBytes = state.videoTitle.utf8.count
            let videoIDBytes = state.videoID.utf8.count
            let sourceBytes = state.source.utf8.count
            if lineBytes > 128 {
                state.line = clippedUTF8(
                    state.line,
                    maximumBytes: max(128, lineBytes * 3 / 4)
                )
            } else if nextLineBytes > 96, let nextLine = state.nextLine {
                state.nextLine = clippedUTF8(
                    nextLine,
                    maximumBytes: max(96, nextLineBytes * 3 / 4)
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
            state.nextLine = nil
            state.nextCueStartMS = nil
            state.nextCueEndMS = nil
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
            let endedActivityID = activity.id
            dismissedVideoID = videoID
            self.activity = nil
            stopPushObservation()
            Task {
                await CIActivityPushClient.shared.endActivity(
                    activityID: endedActivityID
                )
            }
            CIActivityBridge.emit(
                level: "info",
                message: "Live Activity was dismissed by the user or system"
            )
            return false
        case .ended:
            let endedActivityID = activity.id
            self.activity = nil
            stopPushObservation()
            Task {
                await CIActivityPushClient.shared.endActivity(
                    activityID: endedActivityID
                )
            }
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
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: policy
        )
    }
}
