//
//  ThroughputTests.swift
//  PasteBopCoreTests
//
//  Profiles the scanner across the shapes of text people actually copy.
//  A benchmark, not a test: it reports numbers rather than asserting them, so
//  it stays out of the way of an ordinary run.
//
//      PASTEBOP_BENCHMARK=1 swift test -c release --filter Throughput
//
//  The bounded regression tripwires live in TextNormalizerTests.
//

import AppKit
import Foundation
import Testing
@testable import PasteBopCore

@Suite("Throughput")
struct ThroughputTests {

    static let isEnabled = ProcessInfo.processInfo.environment["PASTEBOP_BENCHMARK"] != nil

    static let profiles: [(name: String, unit: String)] = [
        // The overwhelmingly common case: source code, logs, URLs.
        ("pure ascii", "let value = compute(a, b) // plain ascii source line\n"),
        // The case PasteBop exists for: prose with a few typographic marks.
        ("ai prose",
         "The \u{201C}quick\u{201D} brown fox jumped over the lazy dog\u{2014}again\u{2026} "),
        // Non-ASCII that must survive untouched, so every scalar is decoded
        // and looked up and none of them hit.
        ("cjk", "日本語のテキストです。これは書き換えられません。"),
        ("accented prose", "Le renard brun rapide saute par-dessus le chien paresseux. Très bien. "),
        // Pathological: every scalar is a rewrite.
        ("all rewrites", "\u{2014}\u{201C}\u{201D}\u{2026}\u{2022}"),
    ]

    @Test("RTF throughput", .enabled(if: isEnabled))
    func rtfThroughput() {
        // A styled document the size of a long article, as Cocoa writes it.
        let unit = "The \u{201C}quick\u{201D} brown fox jumped over the lazy dog\u{2014}again\u{2026} "
        let styled = NSMutableAttributedString()
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12)]
        for position in 0..<((2 << 20) / unit.utf8.count) {
            let attributes = position.isMultiple(of: 2) ? [:] : bold
            styled.append(NSAttributedString(string: unit, attributes: attributes))
        }
        let whole = NSRange(location: 0, length: styled.length)
        guard let rtf = styled.rtf(from: whole, documentAttributes: [:]) else {
            Issue.record("AppKit could not write the sample")
            return
        }

        var best = Duration.seconds(1000)
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let result = RTFTextRewriter.rewrite(rtf)
            best = min(best, ContinuousClock.now - started)
            _ = result
        }
        let seconds = Double(best.components.attoseconds) / 1e18 + Double(best.components.seconds)
        print(String(
            format: "  %@ %7.1f MB/s   (%.3f ms for %d KB)",
            "rtf".padding(toLength: 16, withPad: " ", startingAt: 0),
            Double(rtf.count) / seconds / 1_048_576,
            seconds * 1000,
            rtf.count / 1024
        ))
    }

    @Test("Scanner throughput", .enabled(if: isEnabled), arguments: profiles)
    func throughput(profile: (name: String, unit: String)) {
        let target = 4 << 20  // about 4 MB
        let repeats = max(1, target / max(1, profile.unit.utf8.count))
        let input = String(repeating: profile.unit, count: repeats)
        let bytes = input.utf8.count

        // Warm the string up so the first touch is not part of the measurement.
        _ = TextNormalizer.needsRewrite(input)

        var best = Duration.seconds(1000)
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let result = TextNormalizer.normalize(input)
            let elapsed = ContinuousClock.now - started
            best = min(best, elapsed)
            _ = result
        }

        let seconds = Double(best.components.attoseconds) / 1e18 + Double(best.components.seconds)
        let throughput = Double(bytes) / seconds / 1_048_576
        let name = profile.name.padding(toLength: 16, withPad: " ", startingAt: 0)
        print(String(
            format: "  %@ %7.1f MB/s   (%.3f ms for %d KB)",
            name,
            throughput,
            seconds * 1000,
            bytes / 1024
        ))
    }
}
