import ActivityKit
import Foundation
import Security

private func CIClippedPushText(
    _ value: String,
    maximumBytes: Int
) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    let ellipsis = "…"
    let budget = max(0, maximumBytes - ellipsis.utf8.count)
    var result = ""
    var usedBytes = 0
    for character in value {
        let fragment = String(character)
        let byteCount = fragment.utf8.count
        guard usedBytes + byteCount <= budget else { break }
        result.append(character)
        usedBytes += byteCount
    }
    return result + ellipsis
}

private final class CINoRedirectSessionDelegate:
    NSObject,
    URLSessionTaskDelegate
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct CIRelayConfiguration: Equatable {
    let endpoint: URL
    let accessToken: String
}

private struct CIRelayCue: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

private struct CIRelayActivitySnapshot: Encodable {
    let clientSessionID: String
    let pushToken: String
    let bundleID: String
    let videoID: String
    let title: String
    let source: String
    let position: Double
    let isPlaying: Bool
    let playbackRate: Double
    let duration: Double
    let anchorTimestampMS: Int64
    let generation: Int
    let frequentPushesEnabled: Bool
    let cues: [CIRelayCue]
}

private enum CIRelayDeliveryStatus: String {
    case accepted
    case retrying
    case rejected
}

enum CIRelayCleanupResult {
    case confirmed
    case queued
    case unconfirmed
}

private struct CIRelayDeliveryResponse: Decodable {
    let deliveryStatus: String?
    let reason: String?
    let apnsReason: String?
    let error: String?
    let ended: Bool?
}

actor CIActivityPushClient {
    static let shared = CIActivityPushClient()

    private static let enabledDefaultsKey =
        "CaptionIsland.PushRelayEnabled"
    private static let URLDefaultsKey =
        "CaptionIsland.PushRelayURL"
    private static let keychainAccount =
        "relay-access-token"
    private static let maximumPUTAttempts = 3
    private static let maximumRetryDelay = 5.0
    private static let fallbackRetryDelays = [0.35, 0.8]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: CINoRedirectSessionDelegate(),
            delegateQueue: nil
        )
    }()
    private let clientSessionID =
        UUID().uuidString.lowercased()

    private var activityID = ""
    private var pushToken = ""
    private var bundleID = ""
    private var videoID = ""
    private var videoTitle = "YouTube"
    private var source = ""
    private var position = 0.0
    private var isPlaying = true
    private var playbackRate = 1.0
    private var duration = 0.0
    private var anchorDate = Date()
    private var generation = 0
    private var frequentPushesEnabled = false
    private var cues: [CIRelayCue] = []
    private var uploadTask: Task<Void, Never>?
    private var lastUploadDate: Date?
    private var didRegisterCurrentActivity = false
    private var lastConfiguration: CIRelayConfiguration?
    private var didLogUnsupportedHostBundleID = false

    func setActivity(
        activityID: String,
        bundleID: String,
        videoID: String,
        title: String,
        frequentPushesEnabled: Bool
    ) {
        guard !activityID.isEmpty else { return }
        let changedActivity = self.activityID != activityID
        self.activityID = activityID
        self.bundleID = bundleID
        self.videoID = videoID
        self.videoTitle = title.isEmpty ? "YouTube" : title
        self.frequentPushesEnabled = frequentPushesEnabled
        if changedActivity {
            uploadTask?.cancel()
            uploadTask = nil
            pushToken = ""
            cues = []
            source = ""
            position = 0
            duration = 0
            isPlaying = true
            playbackRate = 1
            anchorDate = Date()
            generation += 1
            didRegisterCurrentActivity = false
            lastUploadDate = nil
        }
    }

    func updateVideo(videoID: String, title: String) {
        guard !activityID.isEmpty else { return }
        if self.videoID != videoID {
            generation += 1
            cues = []
            source = ""
            position = 0
            duration = 0
            isPlaying = true
            playbackRate = 1
            anchorDate = Date()
        }
        self.videoID = videoID
        self.videoTitle = title.isEmpty ? "YouTube" : title
        scheduleUpload()
    }

    func receivePushToken(
        _ token: Data,
        activityID: String
    ) {
        guard self.activityID == activityID else { return }
        let tokenString = token.map {
            String(format: "%02x", $0)
        }.joined()
        guard !tokenString.isEmpty, pushToken != tokenString else {
            return
        }
        pushToken = tokenString
        generation += 1
        didRegisterCurrentActivity = false
        CIActivityBridge.emit(
            level: "info",
            message: "Received a \(token.count)-byte Live Activity "
                + "push token for activity \(activityID); raw token "
                + "was not logged."
        )
        scheduleUpload()
    }

    func configureTimeline(
        cueData: Data,
        source: String,
        position: Double,
        duration: Double
    ) {
        guard !activityID.isEmpty else { return }
        guard let rawCues = try? JSONSerialization.jsonObject(
            with: cueData
        ) as? [[String: Any]] else { return }
        var parsed: [CIRelayCue] = []
        parsed.reserveCapacity(min(rawCues.count, 512))
        for rawCue in rawCues.prefix(512) {
            guard
                let start = rawCue["startMS"] as? NSNumber,
                let end = rawCue["endMS"] as? NSNumber,
                let rawLine = rawCue["line"] as? String
            else { continue }
            let startMS = max(0, start.intValue)
            let endMS = max(startMS + 1, end.intValue)
            let line = CIClippedPushText(
                rawLine,
                // Keep the worst-case JSON escaping of 512 cues below the
                // relay's 1 MiB request limit.
                maximumBytes: 768
            )
            guard !line.isEmpty else { continue }
            parsed.append(
                CIRelayCue(
                    start: Double(startMS) / 1_000.0,
                    end: Double(endMS) / 1_000.0,
                    text: line
                )
            )
        }
        guard !parsed.isEmpty else { return }
        parsed.sort {
            $0.start == $1.start
                ? $0.end < $1.end
                : $0.start < $1.start
        }
        cues = parsed
        self.source = CIClippedPushText(
            source,
            maximumBytes: 64
        )
        self.position = max(0, position.isFinite ? position : 0)
        let declaredDuration =
            duration.isFinite ? max(0, duration) : 0
        self.duration = max(
            declaredDuration,
            parsed.last?.end ?? 0
        )
        anchorDate = Date()
        generation += 1
        scheduleUpload()
    }

    func clearTimeline(
        position newPosition: Double,
        duration newDuration: Double
    ) {
        guard !activityID.isEmpty else { return }
        cues = []
        source = ""
        position = newPosition.isFinite
            ? max(0, newPosition)
            : 0
        duration = newDuration.isFinite
            ? max(0, newDuration)
            : 0
        anchorDate = Date()
        generation += 1
        scheduleUpload()
    }

    func synchronizePlayback(
        position newPosition: Double,
        isPlaying newIsPlaying: Bool,
        playbackRate newPlaybackRate: Double,
        force: Bool
    ) {
        guard !activityID.isEmpty, newPosition.isFinite,
              newPosition >= 0 else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(anchorDate))
        let predictedPosition = isPlaying
            ? position + elapsed * playbackRate
            : position
        let safeRate =
            newPlaybackRate.isFinite && newPlaybackRate > 0
                ? min(4, max(0.25, newPlaybackRate))
                : 1
        let stateChanged =
            isPlaying != newIsPlaying ||
            abs(playbackRate - safeRate) >= 0.01
        let drifted = abs(predictedPosition - newPosition) >= 1.0
        let heartbeatDue =
            lastUploadDate.map {
                now.timeIntervalSince($0) >= 60
            } ?? true
        guard force || stateChanged || drifted || heartbeatDue else {
            return
        }
        position = newPosition
        isPlaying = newIsPlaying
        playbackRate = safeRate
        anchorDate = now
        generation += 1
        scheduleUpload()
    }

    func refreshConfiguration() async {
        reportUnsupportedHostBundleIDIfNeeded()
        let current = Self.loadConfiguration()
        if current != lastConfiguration,
           let previous = lastConfiguration,
           !activityID.isEmpty {
            await sendDelete(
                activityID: activityID,
                configuration: previous
            )
            didRegisterCurrentActivity = false
        }
        lastConfiguration = current
        if current != nil {
            scheduleUpload()
        } else if !activityID.isEmpty {
            CIActivityBridge.emit(
                level: "debug",
                message: "Live Activity push relay is disabled or "
                    + "not fully configured."
            )
        }
    }

    func isConfigured() -> Bool {
        reportUnsupportedHostBundleIDIfNeeded()
        return Self.loadConfiguration() != nil
    }

    func updateFrequentPushesEnabled(_ enabled: Bool) {
        guard frequentPushesEnabled != enabled else { return }
        frequentPushesEnabled = enabled
        generation += 1
        scheduleUpload()
    }

    /// Validates the exact video and Activity, applies the playback state, and
    /// performs one relay request as a single actor operation. Restricting the
    /// network path to one request keeps it inside the short UIKit background
    /// assertion used during PiP teardown.
    func synchronizePlaybackAndFlushCritical(
        position newPosition: Double,
        isPlaying newIsPlaying: Bool,
        playbackRate newPlaybackRate: Double,
        expectedVideoID: String,
        expectedActivityID: String
    ) async -> Bool {
        guard activityID == expectedActivityID,
              videoID == expectedVideoID,
              !pushToken.isEmpty,
              newPosition.isFinite,
              newPosition >= 0,
              Self.loadConfiguration() != nil else {
            return false
        }
        uploadTask?.cancel()
        uploadTask = nil
        let safeRate =
            newPlaybackRate.isFinite && newPlaybackRate > 0
                ? min(4, max(0.25, newPlaybackRate))
                : 1
        position = newPosition
        isPlaying = newIsPlaying
        playbackRate = safeRate
        anchorDate = Date()
        generation += 1
        await uploadSnapshot(maximumAttempts: 1)
        return true
    }

    @discardableResult
    func endActivity(
        activityID endingActivityID: String
    ) async -> CIRelayCleanupResult {
        uploadTask?.cancel()
        uploadTask = nil
        let configuration =
            Self.loadConfiguration() ?? lastConfiguration
        var relayCleanupResult: CIRelayCleanupResult =
            endingActivityID.isEmpty ? .confirmed : .unconfirmed
        if !endingActivityID.isEmpty, let configuration {
            relayCleanupResult = await sendDelete(
                activityID: endingActivityID,
                configuration: configuration
            )
        }
        if activityID == endingActivityID {
            activityID = ""
            pushToken = ""
            videoID = ""
            videoTitle = "YouTube"
            source = ""
            cues = []
            duration = 0
            generation += 1
            didRegisterCurrentActivity = false
            lastUploadDate = nil
        }
        return relayCleanupResult
    }

    private func scheduleUpload() {
        uploadTask?.cancel()
        uploadTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await uploadSnapshot()
        }
    }

    private func uploadSnapshot(
        maximumAttempts: Int =
            CIActivityPushClient.maximumPUTAttempts
    ) async {
        guard !activityID.isEmpty, !pushToken.isEmpty else {
            return
        }
        guard let configuration = Self.loadConfiguration() else {
            return
        }
        lastConfiguration = configuration
        let activityIDForRequest = activityID
        let snapshotGeneration = generation

        let attemptLimit = min(
            Self.maximumPUTAttempts,
            max(1, maximumAttempts)
        )
        for attempt in 0..<attemptLimit {
            guard isCurrentSnapshot(
                activityID: activityIDForRequest,
                generation: snapshotGeneration,
                configuration: configuration
            ), !Task.isCancelled else {
                return
            }

            // A retry can occur many seconds after its first request. Project
            // the clock again and issue a fresh anchor so a late retry cannot
            // rewind the server-owned schedule.
            let now = Date()
            let elapsed = max(
                0,
                now.timeIntervalSince(anchorDate)
            )
            let projectedPosition = isPlaying
                ? position + elapsed * playbackRate
                : position
            let snapshotPosition = min(
                duration,
                max(0, projectedPosition)
            )
            let snapshot = CIRelayActivitySnapshot(
                clientSessionID: clientSessionID,
                pushToken: pushToken,
                bundleID: bundleID,
                videoID: videoID,
                title: videoTitle,
                source: source,
                position: snapshotPosition,
                isPlaying: isPlaying,
                playbackRate: playbackRate,
                duration: duration,
                anchorTimestampMS: Int64(
                    now.timeIntervalSince1970 * 1_000
                ),
                generation: snapshotGeneration,
                frequentPushesEnabled: frequentPushesEnabled,
                cues: cues
            )
            let requestBody: Data
            do {
                requestBody = try JSONEncoder().encode(snapshot)
            } catch {
                CIActivityBridge.emit(
                    level: "warning",
                    message: "Push relay snapshot encoding failed for "
                        + "activity \(activityIDForRequest)."
                )
                return
            }

            do {
                var request = URLRequest(
                    url: Self.activityURL(
                        configuration.endpoint,
                        activityID: activityIDForRequest
                    )
                )
                request.httpMethod = "PUT"
                request.setValue(
                    "Bearer \(configuration.accessToken)",
                    forHTTPHeaderField: "Authorization"
                )
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Content-Type"
                )
                request.httpBody = requestBody
                let (data, response) = try await session.data(
                    for: request
                )
                guard isCurrentSnapshot(
                    activityID: activityIDForRequest,
                    generation: snapshotGeneration,
                    configuration: configuration
                ), !Task.isCancelled else {
                    return
                }
                guard let HTTPResponse =
                        response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if Self.isTransientStatus(
                    HTTPResponse.statusCode
                ),
                attempt + 1 < attemptLimit {
                    let delay = Self.retryDelay(
                        for: HTTPResponse,
                        attempt: attempt
                    )
                    CIActivityBridge.emit(
                        level: "debug",
                        message: "Push relay temporarily returned HTTP "
                            + "\(HTTPResponse.statusCode) for activity "
                            + "\(activityIDForRequest); retrying attempt "
                            + "\(attempt + 2) of "
                            + "\(attemptLimit)."
                    )
                    guard await waitBeforeRetry(
                        delay,
                        activityID: activityIDForRequest,
                        generation: snapshotGeneration,
                        configuration: configuration
                    ) else {
                        return
                    }
                    continue
                }

                guard (200..<300).contains(
                    HTTPResponse.statusCode
                ) else {
                    let reason = Self.safeRelayReason(
                        from: data
                    )
                    let suffix = reason.map {
                        " (\($0))"
                    } ?? ""
                    CIActivityBridge.emit(
                        level: "warning",
                        message: "Push relay rejected activity "
                            + "\(activityIDForRequest) with HTTP "
                            + "\(HTTPResponse.statusCode)\(suffix)."
                    )
                    return
                }

                guard let relayResponse =
                        try? JSONDecoder().decode(
                            CIRelayDeliveryResponse.self,
                            from: data
                        ),
                      let rawStatus =
                        relayResponse.deliveryStatus?
                            .lowercased(),
                      let deliveryStatus =
                        CIRelayDeliveryStatus(
                            rawValue: rawStatus
                        ) else {
                    CIActivityBridge.emit(
                        level: "warning",
                        message: "Push relay accepted the snapshot for "
                            + "activity \(activityIDForRequest), but did "
                            + "not return a recognized deliveryStatus; "
                            + "APNs registration remains unconfirmed."
                    )
                    return
                }

                let reason = Self.safeRelayReason(
                    relayResponse.reason ??
                        relayResponse.apnsReason ??
                        relayResponse.error
                )
                let reasonSuffix = reason.map {
                    " (\($0))"
                } ?? ""
                switch deliveryStatus {
                case .accepted:
                    lastUploadDate = Date()
                    let firstRegistration =
                        !didRegisterCurrentActivity
                    didRegisterCurrentActivity = true
                    CIActivityBridge.emit(
                        level: firstRegistration
                            ? "info" : "debug",
                        message: firstRegistration
                            ? "Registered token-enabled Live Activity "
                                + "\(activityIDForRequest) with the "
                                + "AOD push relay."
                            : "Synchronized Live Activity "
                                + "\(activityIDForRequest) with the "
                                + "AOD push relay."
                    )
                case .retrying:
                    lastUploadDate = Date()
                    didRegisterCurrentActivity = false
                    CIActivityBridge.emit(
                        level: "warning",
                        message: "Push relay is retrying APNs delivery "
                            + "for activity \(activityIDForRequest)"
                            + "\(reasonSuffix); registration is not "
                            + "confirmed yet."
                    )
                case .rejected:
                    didRegisterCurrentActivity = false
                    CIActivityBridge.emit(
                        level: "warning",
                        message: "Push relay could not deliver activity "
                            + "\(activityIDForRequest) to APNs"
                            + "\(reasonSuffix)."
                    )
                }
                return
            } catch {
                guard isCurrentSnapshot(
                    activityID: activityIDForRequest,
                    generation: snapshotGeneration,
                    configuration: configuration
                ), !Task.isCancelled else {
                    return
                }
                let URLCode = (error as? URLError)?.code
                let transientNetworkFailure =
                    URLCode.map(Self.isTransientURLCode) ?? false
                if transientNetworkFailure,
                   attempt + 1 < attemptLimit {
                    let delay = Self.fallbackRetryDelay(
                        attempt: attempt
                    )
                    CIActivityBridge.emit(
                        level: "debug",
                        message: "Push relay request was interrupted for "
                            + "activity \(activityIDForRequest); retrying "
                            + "attempt \(attempt + 2) of "
                            + "\(attemptLimit)."
                    )
                    guard await waitBeforeRetry(
                        delay,
                        activityID: activityIDForRequest,
                        generation: snapshotGeneration,
                        configuration: configuration
                    ) else {
                        return
                    }
                    continue
                }
                CIActivityBridge.emit(
                    level: "warning",
                    message: "Push relay synchronization failed for "
                        + "activity \(activityIDForRequest)"
                        + (URLCode.map {
                            " (URL error \($0.rawValue))."
                        } ?? ".")
                )
                return
            }
        }
    }

    private func isCurrentSnapshot(
        activityID expectedActivityID: String,
        generation expectedGeneration: Int,
        configuration expectedConfiguration:
            CIRelayConfiguration
    ) -> Bool {
        activityID == expectedActivityID &&
            generation == expectedGeneration &&
            Self.loadConfiguration() == expectedConfiguration
    }

    private func waitBeforeRetry(
        _ delay: TimeInterval,
        activityID: String,
        generation: Int,
        configuration: CIRelayConfiguration
    ) async -> Bool {
        guard isCurrentSnapshot(
            activityID: activityID,
            generation: generation,
            configuration: configuration
        ), !Task.isCancelled else {
            return false
        }
        do {
            try await Task.sleep(
                nanoseconds: UInt64(
                    max(0, delay) * 1_000_000_000
                )
            )
        } catch {
            return false
        }
        return !Task.isCancelled && isCurrentSnapshot(
            activityID: activityID,
            generation: generation,
            configuration: configuration
        )
    }

    private func reportUnsupportedHostBundleIDIfNeeded() {
        guard !Self.hostBundleSupportsPushRelay,
              !didLogUnsupportedHostBundleID,
              UserDefaults.standard.bool(
                forKey: Self.enabledDefaultsKey
              ) else {
            return
        }
        didLogUnsupportedHostBundleID = true
        CIActivityBridge.emit(
            level: "warning",
            message: "AOD remote push is unavailable because the "
                + "installed host still uses Google's "
                + "com.google.ios.youtube bundle ID. Re-sign the app "
                + "with a custom explicit App ID owned by your Apple "
                + "Developer account."
        )
    }

    private static func isTransientStatus(
        _ statusCode: Int
    ) -> Bool {
        statusCode == 408 ||
            statusCode == 425 ||
            statusCode == 429 ||
            (500...599).contains(statusCode)
    }

    private static func isTransientURLCode(
        _ code: URLError.Code
    ) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    private static func fallbackRetryDelay(
        attempt: Int
    ) -> TimeInterval {
        let index = min(
            max(0, attempt),
            fallbackRetryDelays.count - 1
        )
        return fallbackRetryDelays[index]
    }

    private static func retryDelay(
        for response: HTTPURLResponse,
        attempt: Int
    ) -> TimeInterval {
        guard let rawValue = response.value(
            forHTTPHeaderField: "Retry-After"
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !rawValue.isEmpty else {
            return fallbackRetryDelay(attempt: attempt)
        }
        if let seconds = Double(rawValue), seconds.isFinite {
            return min(
                maximumRetryDelay,
                max(0, seconds)
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat =
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let retryDate = formatter.date(
            from: rawValue
        ) else {
            return fallbackRetryDelay(attempt: attempt)
        }
        return min(
            maximumRetryDelay,
            max(0, retryDate.timeIntervalSinceNow)
        )
    }

    private static func safeRelayReason(
        from data: Data
    ) -> String? {
        guard let response = try? JSONDecoder().decode(
            CIRelayDeliveryResponse.self,
            from: data
        ) else {
            return nil
        }
        return safeRelayReason(
            response.reason ??
                response.apnsReason ??
                response.error
        )
    }

    private static func safeRelayReason(
        _ rawValue: String?
    ) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
              !value.isEmpty,
              value.utf8.count <= 64 else {
            return nil
        }
        let allowedPunctuation =
            CharacterSet(charactersIn: "._-:")
        let allowedCharacters =
            CharacterSet.alphanumerics
                .union(allowedPunctuation)
        guard value.unicodeScalars.allSatisfy({
            $0.isASCII &&
                allowedCharacters.contains($0)
        }) else {
            return nil
        }
        let hexadecimalCharacters =
            CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let resemblesSecret =
            value.utf8.count >= 24 &&
            value.unicodeScalars.allSatisfy({
                hexadecimalCharacters.contains($0)
            })
        return resemblesSecret ? nil : value
    }

    @discardableResult
    private func sendDelete(
        activityID: String,
        configuration: CIRelayConfiguration
    ) async -> CIRelayCleanupResult {
        do {
            var request = URLRequest(
                url: Self.activityURL(
                    configuration.endpoint,
                    activityID: activityID
                )
            )
            request.httpMethod = "DELETE"
            request.setValue(
                "Bearer \(configuration.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            let (data, response) = try await session.data(for: request)
            guard let HTTPResponse =
                    response as? HTTPURLResponse else {
                return .unconfirmed
            }
            if HTTPResponse.statusCode == 404 {
                return .confirmed
            }
            let relayResponse = try? JSONDecoder().decode(
                CIRelayDeliveryResponse.self,
                from: data
            )
            if (200..<300).contains(HTTPResponse.statusCode) {
                switch relayResponse?.deliveryStatus?.lowercased() {
                case CIRelayDeliveryStatus.accepted.rawValue,
                     "not_found":
                    return .confirmed
                case CIRelayDeliveryStatus.retrying.rawValue:
                    return .queued
                case CIRelayDeliveryStatus.rejected.rawValue:
                    return .unconfirmed
                default:
                    // Compatibility with the first relay revision, which
                    // returned only {"ended": true/false}. Either value
                    // means no active server schedule remains.
                    if relayResponse?.ended != nil {
                        return .confirmed
                    }
                    return .unconfirmed
                }
            } else {
                CIActivityBridge.emit(
                    level: "warning",
                    message: "Push relay cleanup returned HTTP "
                        + "\(HTTPResponse.statusCode) for activity "
                        + "\(activityID)."
                )
            }
            return .unconfirmed
        } catch {
            CIActivityBridge.emit(
                level: "debug",
                message: "Push relay cleanup could not be delivered for "
                    + "activity \(activityID). The server-side expiry "
                    + "remains responsible for final cleanup."
            )
            return .unconfirmed
        }
    }

    private static func loadConfiguration()
        -> CIRelayConfiguration?
    {
        let defaults = UserDefaults.standard
        guard hostBundleSupportsPushRelay,
        defaults.object(
            forKey: enabledDefaultsKey
        ) != nil,
        defaults.bool(forKey: enabledDefaultsKey),
        let rawURL = defaults.string(forKey: URLDefaultsKey),
        let endpoint = URL(string: rawURL),
        endpoint.scheme?.lowercased() == "https",
        endpoint.host?.isEmpty == false,
        endpoint.user == nil,
        endpoint.password == nil,
        endpoint.query == nil,
        endpoint.fragment == nil,
        let accessToken = keychainAccessToken(),
        accessToken.utf8.count >= 32 else {
            return nil
        }
        return CIRelayConfiguration(
            endpoint: endpoint,
            accessToken: accessToken
        )
    }

    private static var hostBundleSupportsPushRelay: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }
        return !bundleID.isEmpty &&
            bundleID != "com.google.ios.youtube"
    }

    private static func keychainAccessToken() -> String? {
        let bundleID =
            Bundle.main.bundleIdentifier ?? "CaptionIsland"
        let service =
            "\(bundleID).CaptionIslandPushRelay"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
        let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func activityURL(
        _ endpoint: URL,
        activityID: String
    ) -> URL {
        endpoint
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(
                "activities",
                isDirectory: true
            )
            .appendingPathComponent(
                activityID,
                isDirectory: false
            )
    }
}
