import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct CaptionCue: Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public enum CaptionFormat: Sendable {
    case youtubeJSON3
    case webVTT
    case youtubeTimedTextXML
    case lrc
}

public enum CaptionParserError: Error, Equatable, LocalizedError {
    case invalidUTF8
    case malformedJSON
    case malformedXML(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The caption payload is not valid UTF-8."
        case .malformedJSON:
            return "The caption payload is not valid YouTube JSON3."
        case let .malformedXML(message):
            return "The timed-text XML is malformed: \(message)"
        }
    }
}

public enum CaptionParser {
    public static func parse(_ data: Data, as format: CaptionFormat) throws -> [CaptionCue] {
        switch format {
        case .youtubeJSON3:
            return try parseYouTubeJSON3(data)
        case .webVTT:
            return try parseWebVTT(data)
        case .youtubeTimedTextXML:
            return try parseYouTubeTimedTextXML(data)
        case .lrc:
            return try parseLRC(data)
        }
    }

    public static func parseYouTubeJSON3(_ data: Data) throws -> [CaptionCue] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CaptionParserError.malformedJSON
        }

        guard
            let root = object as? [String: Any],
            let events = root["events"] as? [[String: Any]]
        else {
            throw CaptionParserError.malformedJSON
        }

        var drafts: [CueDraft] = []
        drafts.reserveCapacity(events.count)

        for (order, event) in events.enumerated() {
            guard
                let startMilliseconds = number(event["tStartMs"]),
                let segments = event["segs"] as? [[String: Any]]
            else {
                // JSON3 also contains window/style events without caption text.
                continue
            }

            let rawText = segments.compactMap { $0["utf8"] as? String }.joined()
            let text = normalizePlainText(rawText)
            guard !text.isEmpty else { continue }

            let start = max(0, startMilliseconds / 1_000)
            let end: TimeInterval?
            if let durationMilliseconds = number(event["dDurationMs"]), durationMilliseconds > 0 {
                end = start + durationMilliseconds / 1_000
            } else {
                end = nil
            }

            drafts.append(CueDraft(start: start, end: end, text: text, order: order))
        }

        return finalize(drafts, defaultDuration: 2)
    }

    public static func parseWebVTT(_ data: Data) throws -> [CaptionCue] {
        guard var source = String(data: data, encoding: .utf8) else {
            throw CaptionParserError.invalidUTF8
        }

        source = source.replacingOccurrences(of: "\r\n", with: "\n")
        source = source.replacingOccurrences(of: "\r", with: "\n")
        if source.first == "\u{FEFF}" {
            source.removeFirst()
        }

        let lines = source.components(separatedBy: "\n")
        var drafts: [CueDraft] = []
        var index = 0
        var order = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || line.hasPrefix("WEBVTT ") {
                index += 1
                continue
            }

            let uppercased = line.uppercased()
            if uppercased == "NOTE" || uppercased.hasPrefix("NOTE ") ||
                uppercased == "STYLE" || uppercased == "REGION" {
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }

            let timingLine: String
            if line.contains("-->") {
                timingLine = line
                index += 1
            } else if index + 1 < lines.count && lines[index + 1].contains("-->") {
                // The current line is a WebVTT cue identifier.
                timingLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                index += 2
            } else {
                // Header metadata and malformed blocks are deliberately ignored.
                index += 1
                continue
            }

            guard let timing = parseVTTTimingLine(timingLine) else {
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }

            var payload: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                payload.append(lines[index])
                index += 1
            }

            let text = normalizeVTTText(payload.joined(separator: "\n"))
            guard !text.isEmpty else { continue }
            drafts.append(
                CueDraft(
                    start: timing.start,
                    end: timing.end,
                    text: text,
                    order: order
                )
            )
            order += 1
        }

        return finalize(drafts, defaultDuration: 2)
    }

    public static func parseYouTubeTimedTextXML(_ data: Data) throws -> [CaptionCue] {
        let collector = XMLCueCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw CaptionParserError.malformedXML(
                parser.parserError?.localizedDescription ?? "Unknown XML parser error"
            )
        }

        return finalize(collector.drafts, defaultDuration: 2)
    }

    public static func parseLRC(_ data: Data) throws -> [CaptionCue] {
        guard var source = String(data: data, encoding: .utf8) else {
            throw CaptionParserError.invalidUTF8
        }

        source = source.replacingOccurrences(of: "\r\n", with: "\n")
        source = source.replacingOccurrences(of: "\r", with: "\n")
        if source.first == "\u{FEFF}" {
            source.removeFirst()
        }

        let lines = source.components(separatedBy: "\n")
        let tagExpression = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
        let enhancedTimestampExpression = try! NSRegularExpression(
            pattern: #"<\d{1,3}:\d{2}(?:[\.,:]\d{1,3})?>"#
        )

        var offsetMilliseconds: Double = 0
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in tagExpression.matches(in: line, range: range) {
                guard let tagRange = Range(match.range(at: 1), in: line) else { continue }
                let tag = line[tagRange].trimmingCharacters(in: .whitespaces)
                if tag.lowercased().hasPrefix("offset:") {
                    let value = tag.dropFirst("offset:".count)
                    if let parsed = Double(value.trimmingCharacters(in: .whitespaces)) {
                        offsetMilliseconds = parsed
                    }
                }
            }
        }

        var drafts: [CueDraft] = []
        var order = 0
        for line in lines {
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = tagExpression.matches(in: line, range: fullRange)
            var timestamps: [TimeInterval] = []
            var timestampRanges: [NSRange] = []

            for match in matches {
                guard let tagRange = Range(match.range(at: 1), in: line) else { continue }
                if let timestamp = parseLRCTimestamp(String(line[tagRange])) {
                    timestamps.append(max(0, timestamp + offsetMilliseconds / 1_000))
                    timestampRanges.append(match.range(at: 0))
                }
            }

            guard !timestamps.isEmpty else { continue }

            var lyric = line
            for range in timestampRanges.reversed() {
                if let swiftRange = Range(range, in: lyric) {
                    lyric.removeSubrange(swiftRange)
                }
            }
            lyric = enhancedTimestampExpression.stringByReplacingMatches(
                in: lyric,
                range: NSRange(lyric.startIndex..<lyric.endIndex, in: lyric),
                withTemplate: ""
            )
            let text = normalizePlainText(lyric)

            for timestamp in timestamps {
                drafts.append(CueDraft(start: timestamp, end: nil, text: text, order: order))
                order += 1
            }
        }

        return finalize(drafts, defaultDuration: 4)
    }
}

private struct CueDraft {
    let start: TimeInterval
    let end: TimeInterval?
    let text: String
    let order: Int
}

private func finalize(_ drafts: [CueDraft], defaultDuration: TimeInterval) -> [CaptionCue] {
    let sorted = drafts.sorted {
        if $0.start == $1.start {
            return $0.order < $1.order
        }
        return $0.start < $1.start
    }

    return sorted.enumerated().compactMap { index, draft in
        let end: TimeInterval
        if let explicitEnd = draft.end, explicitEnd > draft.start {
            end = explicitEnd
        } else if let next = sorted[(index + 1)...].first(where: { $0.start > draft.start }) {
            end = next.start
        } else {
            end = draft.start + defaultDuration
        }
        guard !draft.text.isEmpty else { return nil }
        return CaptionCue(startTime: draft.start, endTime: end, text: draft.text)
    }
}

private func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let string = value as? String {
        return Double(string)
    }
    return nil
}

private func normalizePlainText(_ raw: String) -> String {
    let normalizedNewlines = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    return normalizedNewlines
        .components(separatedBy: "\n")
        .map {
            $0.replacingOccurrences(
                of: #"[\t ]+"#,
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func normalizeVTTText(_ raw: String) -> String {
    let withoutTags = raw.replacingOccurrences(
        of: #"<[^>]*>"#,
        with: "",
        options: .regularExpression
    )
    return normalizePlainText(decodeVTTEntities(withoutTags))
}

private func decodeVTTEntities(_ raw: String) -> String {
    var result = raw
    let namedEntities: [(String, String)] = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&lrm;", ""),
        ("&rlm;", ""),
    ]
    for (entity, replacement) in namedEntities {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }

    let expression = try! NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#)
    let matches = expression.matches(
        in: result,
        range: NSRange(result.startIndex..<result.endIndex, in: result)
    )
    for match in matches.reversed() {
        guard
            let fullRange = Range(match.range(at: 0), in: result),
            let valueRange = Range(match.range(at: 1), in: result)
        else { continue }

        let token = String(result[valueRange])
        let scalarValue: UInt32?
        if token.lowercased().hasPrefix("x") {
            scalarValue = UInt32(token.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(token, radix: 10)
        }
        if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
    }
    return result
}

private func parseVTTTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
    guard let arrow = line.range(of: "-->") else { return nil }
    let startToken = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
    let endAndSettings = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
    guard let endToken = endAndSettings.split(whereSeparator: { $0.isWhitespace }).first else {
        return nil
    }
    guard
        let start = parseVTTTimestamp(String(startToken)),
        let end = parseVTTTimestamp(String(endToken)),
        end > start
    else {
        return nil
    }
    return (start, end)
}

private func parseVTTTimestamp(_ token: String) -> TimeInterval? {
    let components = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
    guard components.count == 2 || components.count == 3 else { return nil }

    let hours: Double
    let minutes: Double
    let seconds: Double
    if components.count == 3 {
        guard
            let parsedHours = Double(components[0]),
            let parsedMinutes = Double(components[1]),
            let parsedSeconds = Double(components[2])
        else { return nil }
        hours = parsedHours
        minutes = parsedMinutes
        seconds = parsedSeconds
    } else {
        guard
            let parsedMinutes = Double(components[0]),
            let parsedSeconds = Double(components[1])
        else { return nil }
        hours = 0
        minutes = parsedMinutes
        seconds = parsedSeconds
    }

    guard hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else {
        return nil
    }
    return hours * 3_600 + minutes * 60 + seconds
}

private func parseLRCTimestamp(_ raw: String) -> TimeInterval? {
    let token = raw.trimmingCharacters(in: .whitespaces)
    let components = token.split(separator: ":", omittingEmptySubsequences: false)

    if components.count == 2 {
        guard
            let minutes = Double(components[0]),
            let seconds = Double(components[1].replacingOccurrences(of: ",", with: ".")),
            minutes >= 0,
            seconds >= 0,
            seconds < 60
        else { return nil }
        return minutes * 60 + seconds
    }

    if components.count == 3 {
        let finalComponent = String(components[2])
        if finalComponent.contains(".") || finalComponent.contains(",") {
            // Unofficial but common extension: [h:mm:ss.xxx].
            guard
                let hours = Double(components[0]),
                let minutes = Double(components[1]),
                let seconds = Double(finalComponent.replacingOccurrences(of: ",", with: ".")),
                hours >= 0,
                minutes >= 0,
                minutes < 60,
                seconds >= 0,
                seconds < 60
            else { return nil }
            return hours * 3_600 + minutes * 60 + seconds
        }

        // Legacy LRC syntax: [mm:ss:xx], where xx is a decimal fraction.
        guard
            let minutes = Double(components[0]),
            let seconds = Double(components[1]),
            let fractionDigits = Int(components[2]),
            minutes >= 0,
            seconds >= 0,
            seconds < 60,
            !components[2].isEmpty,
            components[2].count <= 3
        else { return nil }
        let divisor = pow(10, Double(components[2].count))
        return minutes * 60 + seconds + Double(fractionDigits) / divisor
    }

    return nil
}

private final class XMLCueCollector: NSObject, XMLParserDelegate {
    private var currentElement: String?
    private var currentStart: TimeInterval = 0
    private var currentEnd: TimeInterval?
    private var currentText = ""
    private var order = 0

    fileprivate var drafts: [CueDraft] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if currentElement != nil {
            if elementName.lowercased() == "br" {
                currentText.append("\n")
            }
            return
        }

        let lowercasedName = elementName.lowercased()
        guard lowercasedName == "text" || lowercasedName == "p" else { return }

        let start: TimeInterval?
        let duration: TimeInterval?
        if lowercasedName == "text" {
            start = attributeDict["start"].flatMap(Double.init)
            duration = attributeDict["dur"].flatMap(Double.init)
        } else {
            start = attributeDict["t"].flatMap(Double.init).map { $0 / 1_000 }
            duration = attributeDict["d"].flatMap(Double.init).map { $0 / 1_000 }
        }

        guard let start else { return }
        currentElement = lowercasedName
        currentStart = max(0, start)
        if let duration, duration > 0 {
            currentEnd = currentStart + duration
        } else {
            currentEnd = nil
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard currentElement != nil, let text = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        currentText.append(text)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == currentElement else { return }
        let text = normalizePlainText(currentText)
        if !text.isEmpty {
            drafts.append(
                CueDraft(
                    start: currentStart,
                    end: currentEnd,
                    text: text,
                    order: order
                )
            )
            order += 1
        }
        currentElement = nil
        currentEnd = nil
        currentText = ""
    }
}
