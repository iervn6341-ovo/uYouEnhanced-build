import ActivityKit
import Foundation

public struct CICaptionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var line: String
        public var source: String
        public var videoID: String
        public var videoTitle: String
        public var isPlaying: Bool
        public var cueStartMS: Int
        public var cueEndMS: Int
        public var nextLine: String?
        public var nextCueStartMS: Int?
        public var nextCueEndMS: Int?
        public var revision: Int

        public init(
            line: String,
            source: String,
            videoID: String,
            videoTitle: String,
            isPlaying: Bool,
            cueStartMS: Int,
            cueEndMS: Int,
            nextLine: String? = nil,
            nextCueStartMS: Int? = nil,
            nextCueEndMS: Int? = nil,
            revision: Int
        ) {
            self.line = line
            self.source = source
            self.videoID = videoID
            self.videoTitle = videoTitle
            self.isPlaying = isPlaying
            self.cueStartMS = cueStartMS
            self.cueEndMS = cueEndMS
            self.nextLine = nextLine
            self.nextCueStartMS = nextCueStartMS
            self.nextCueEndMS = nextCueEndMS
            self.revision = revision
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
