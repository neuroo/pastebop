//
//  ActivityReportTests.swift
//  PasteBopCoreTests
//

import Foundation
import Testing
@testable import PasteBopCore

@Suite("Activity report")
struct ActivityReportTests {

    /// Pinned to one locale: the report deliberately formats numbers for the
    /// reader, and this machine's locale writes "75 %" and groups with a
    /// narrow no-break space.
    private static let locale = Locale(identifier: "en_US")

    private func report(_ text: String, copies: Int = 1, enabled: Bool = true) -> ActivityReport {
        ActivityReport(
            isEnabled: enabled,
            copyCount: copies,
            tally: TextNormalizer.tally(text),
            locale: Self.locale
        )
    }

    @Test("Says what it is doing when there is nothing to show")
    func emptyStates() {
        #expect(report("", copies: 0).activityLine == "Watching the clipboard")
        #expect(report("", copies: 0, enabled: false).activityLine == "Paused")
        #expect(report("\u{2014}", enabled: false).activityLine == "Paused")
        #expect(report("", copies: 0).summaryLine == "Nothing cleaned yet")
        #expect(report("", copies: 0).dominantFamilyLine == nil)
    }

    @Test("Gets singular and plural right")
    func plurals() {
        #expect(report("\u{2014}", copies: 1).activityLine == "Cleaned 1 character in 1 copy")
        #expect(report("\u{2014}\u{2026}", copies: 2).activityLine == "Cleaned 2 characters in 2 copies")
    }

    @Test("Names the dominant family with a share")
    func dominantFamily() {
        // Three quotes, one dash: quotes are 75%.
        let line = report("\u{201C}\u{201D}\u{2019}\u{2014}").dominantFamilyLine
        #expect(line == "Mostly quotes and apostrophes (75%)")
    }

    @Test("Lists the commonest characters, commonest first")
    func offenders() {
        let lines = report(String(repeating: "\u{2019}", count: 3) + "\u{2014}").offenderLines()
        #expect(lines == ["3 \u{d7} Right single quotation mark \u{2019}", "1 \u{d7} Em dash \u{2014}"])
    }

    @Test("Leaves the glyph off invisible characters")
    func invisibleOffenders() {
        let lines = report("a\u{200b}b").offenderLines()
        #expect(lines == ["1 \u{d7} Zero width space"])
    }

    @Test("Honours the offender limit")
    func offenderLimit() {
        let text = "\u{2014}\u{2026}\u{201C}\u{201D}\u{2019}\u{2022}\u{2192}\u{2248}"
        #expect(report(text).offenderLines(limit: 3).count == 3)
    }

    @Test("Formats large counts with separators")
    func largeCounts() {
        var tally = RewriteTally()
        tally.record("2014", times: 12_345)
        let report = ActivityReport(
            isEnabled: true, copyCount: 1_200, tally: tally, locale: Self.locale
        )
        #expect(report.activityLine == "Cleaned 12,345 characters in 1,200 copies")
        #expect(report.offenderLines().first?.contains("Em dash") == true)
    }
}
