//
//  FootprintTests.swift
//  PasteBopCoreTests
//
//  What one rewrite costs in memory, as a multiple of the text handed to it.
//  A benchmark, not a test: it reports numbers rather than asserting them, so
//  it stays out of the way of an ordinary run.
//
//      PASTEBOP_BENCHMARK=1 swift test -c release --filter Footprint
//
//  Why it matters: nothing here can ask for memory it might not get. A Swift
//  array traps when an allocation fails, so a copy that overshoots is a crash
//  rather than a slow rewrite. The input is capped at `maximumTextBytes`, so
//  the peak is that times whatever these report -- which is the number to
//  watch after any change to what the rewriters build.
//
//  Two that were found this way: HTML kept a source position for every
//  decoded byte, and RTF a forty-byte record per text token, together putting
//  an ordinary styled paste at twelve times its own size.
//

import Foundation
import Testing
@testable import PasteBopCore

@Suite("Footprint")
struct FootprintTests {

    static let isEnabled = ProcessInfo.processInfo.environment["PASTEBOP_BENCHMARK"] != nil

    /// Resident size now. Sampled from another thread while the work runs,
    /// because what matters is the peak during it, not what survives it.
    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private final class Peak: @unchecked Sendable {
        var bytes = 0
        var done = false
    }

    private func report(_ label: String, input: Int, _ work: () -> Void) {
        let base = Self.residentBytes()
        let peak = Peak()
        peak.bytes = base
        let sampler = Thread {
            while !peak.done { peak.bytes = max(peak.bytes, Self.residentBytes()) }
        }
        sampler.start()
        work()
        peak.done = true
        let held = Double(peak.bytes - base)
        let name = label.padding(toLength: 20, withPad: " ", startingAt: 0)
        let line = String(
            format: "  %@ %.1fx  (%.0f MB over %.0f MB)",
            name,
            held / Double(input),
            held / 1_048_576,
            Double(input) / 1_048_576
        )
        print(line)
    }

    @Test("Footprint per flavour", .enabled(if: isEnabled))
    func footprint() {
        let unit = "The \u{201C}quick\u{201D} brown fox\u{2014}again\u{2026} "
        let text = String(repeating: unit, count: (8 << 20) / unit.utf8.count)
        let html = "<p>\(text)</p>"
        // One reference is enough to make the decoded stream exist, so this is
        // the shape that used to cost four bytes for every byte of the page.
        let entities = "<p>" + String(repeating: "a&amp;b\u{2014}", count: (8 << 20) / 10) + "</p>"
        let rtf = Data(
            ("{\\rtf1\\ansi " + String(repeating: "a\\u8212 b ", count: (8 << 20) / 10) + "}").utf8
        )

        report("plain", input: text.utf8.count) {
            _ = TextNormalizer.normalize(text, rules: .builtIn)
        }
        report("html", input: html.utf8.count) {
            _ = HTMLTextRewriter.rewrite(html, rules: .builtIn)
        }
        report("html with entities", input: entities.utf8.count) {
            _ = HTMLTextRewriter.rewrite(entities, rules: .builtIn)
        }
        report("rtf", input: rtf.count) {
            _ = RTFTextRewriter.rewrite(rtf, rules: .builtIn)
        }
        report("attributed", input: text.utf8.count) {
            _ = TextNormalizer.normalize(NSAttributedString(string: text), rules: .builtIn)
        }
    }
}
