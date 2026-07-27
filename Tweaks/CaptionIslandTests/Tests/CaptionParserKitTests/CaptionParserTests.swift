import Foundation
import XCTest
@testable import CaptionParserKit

final class CaptionParserTests: XCTestCase {
    func testYouTubeJSON3CoalescesSegmentsAndSkipsWindowEvents() throws {
        let cues = try CaptionParser.parse(fixture("youtube-json3", extension: "json"), as: .youtubeJSON3)

        XCTAssertEqual(cues.count, 3)
        assertCue(cues[0], start: 0, end: 1.2, text: "Hello 世界")
        assertCue(cues[1], start: 1.5, end: 2.5, text: "Second\nline")
        assertCue(cues[2], start: 3, end: 5, text: "No duration")
    }

    func testYouTubeJSON3RejectsWrongRootShape() throws {
        let data = try XCTUnwrap(#"{"events":"not-an-array"}"#.data(using: .utf8))
        XCTAssertThrowsError(try CaptionParser.parseYouTubeJSON3(data)) { error in
            XCTAssertEqual(error as? CaptionParserError, .malformedJSON)
        }
    }

    func testWebVTTAcceptsBOMCRLFIdentifiersSettingsAndEntities() throws {
        let fixtureData = try fixture("sample", extension: "vtt")
        let fixtureText = try XCTUnwrap(String(data: fixtureData, encoding: .utf8))
        let crlfData = try XCTUnwrap(("\u{FEFF}" + fixtureText.replacingOccurrences(of: "\n", with: "\r\n")).data(using: .utf8))

        let cues = try CaptionParser.parseWebVTT(crlfData)

        XCTAssertEqual(cues.count, 3)
        assertCue(cues[0], start: 0.5, end: 2, text: "Hello & welcome\nsecond line")
        assertCue(cues[1], start: 2, end: 4.25, text: "Music ♫")
        assertCue(cues[2], start: 4.25, end: 5, text: "Comma timestamp accepted")
    }

    func testWebVTTSkipsMalformedAndBackwardsTiming() throws {
        let source = """
        WEBVTT

        bad
        not-a-time --> 00:01.000
        ignored

        00:03.000 --> 00:02.000
        backwards

        00:04.000 --> 00:05.000
        kept
        """
        let data = try XCTUnwrap(source.data(using: .utf8))
        let cues = try CaptionParser.parseWebVTT(data)

        XCTAssertEqual(cues.count, 1)
        assertCue(cues[0], start: 4, end: 5, text: "kept")
    }

    func testTimedTextSupportsTranscriptAndSRV3Forms() throws {
        let cues = try CaptionParser.parse(
            fixture("timedtext", extension: "xml"),
            as: .youtubeTimedTextXML
        )

        XCTAssertEqual(cues.count, 3)
        assertCue(cues[0], start: 0.5, end: 1.75, text: "Rock & Roll\n第二行")
        assertCue(cues[1], start: 2, end: 3.5, text: "日本語")
        assertCue(cues[2], start: 4, end: 6, text: "No duration")
    }

    func testTimedTextRejectsMalformedXML() throws {
        let data = try XCTUnwrap("<transcript><text start=\"1\">oops".data(using: .utf8))
        XCTAssertThrowsError(try CaptionParser.parseYouTubeTimedTextXML(data))
    }

    func testLRCAppliesOffsetMultipleTimestampsAndEnhancedTags() throws {
        let cues = try CaptionParser.parseLRC(fixture("sample", extension: "lrc"))

        XCTAssertEqual(cues.count, 6)
        assertCue(cues[0], start: 1.25, end: 3.75, text: "First line")
        assertCue(cues[1], start: 3.75, end: 5.25, text: "Repeated line")
        assertCue(cues[2], start: 5.25, end: 7.25, text: "Repeated line")
        assertCue(cues[3], start: 7.25, end: 62.75, text: "Enhanced words")
        assertCue(cues[4], start: 62.75, end: 3_723.7, text: "Long minute timestamp")
        assertCue(cues[5], start: 3_723.7, end: 3_727.7, text: "Hour extension")
    }

    func testLRCClampsNegativeOffsetAndSupportsLegacyFraction() throws {
        let source = """
        [offset:-500]
        [00:00.20]clamped
        [00:01:25]legacy hundredths
        """
        let data = try XCTUnwrap(source.data(using: .utf8))
        let cues = try CaptionParser.parseLRC(data)

        XCTAssertEqual(cues.count, 2)
        assertCue(cues[0], start: 0, end: 0.75, text: "clamped")
        assertCue(cues[1], start: 0.75, end: 4.75, text: "legacy hundredths")
    }

    func testLRCEmptyTimestampCreatesDisplayGap() throws {
        let source = """
        [00:01.00]First line
        [00:03.00]
        [00:05.00]Second line
        """
        let data = try XCTUnwrap(source.data(using: .utf8))
        let cues = try CaptionParser.parseLRC(data)

        XCTAssertEqual(cues.count, 2)
        assertCue(cues[0], start: 1, end: 3, text: "First line")
        assertCue(cues[1], start: 5, end: 9, text: "Second line")
    }

    func testTextFormatsRejectInvalidUTF8() {
        let invalidUTF8 = Data([0xC3, 0x28])
        XCTAssertThrowsError(try CaptionParser.parseWebVTT(invalidUTF8))
        XCTAssertThrowsError(try CaptionParser.parseLRC(invalidUTF8))
    }

    private func fixture(_ name: String, extension fileExtension: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func assertCue(
        _ cue: CaptionCue,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(cue.startTime, start, accuracy: 0.000_1, file: file, line: line)
        XCTAssertEqual(cue.endTime, end, accuracy: 0.000_1, file: file, line: line)
        XCTAssertEqual(cue.text, text, file: file, line: line)
    }
}
