//
//  PasteboardWorkTests.swift
//  PasteBopCoreTests
//

import AppKit
import Testing
@testable import PasteBopCore

/// Supplies data on demand and counts how often it was asked.
private final class CountingProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requests = 0

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requests += 1
        item.setData(Data([0]), forType: type)
    }
}

@MainActor
@Suite("Pasteboard work")
struct PasteboardWorkTests {

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(text.utf8), forType: .string)
        pasteboard.writeObjects([item])
    }

    // MARK: - The three steps

    @Test("The inline budget shrinks as substring rules multiply")
    func inlineBudgetShrinksWithSubstringRules() {
        // Matching tries every candidate sharing a first scalar, so a table
        // full of them costs orders of magnitude more per byte. At the full
        // budget that holds the main thread for seconds.
        #expect(PasteboardWork.inlineBudget(for: .builtIn) == PasteboardNormalizer.inlineTextBytes)

        var many = RuleOverrides()
        for index in 0..<2000 {
            many[.sequence([0x2014, UInt32(0x3000 + index)])] = .output("X")
        }
        let crowded = PasteboardWork.inlineBudget(for: RewriteRules(overrides: many))
        #expect(crowded < PasteboardNormalizer.inlineTextBytes)
        // Small, but never nothing: a budget of zero would mean an empty
        // clipboard took a trip through the queue to come back unchanged.
        #expect(crowded > 0)
    }

    @Test("The inline budget shrinks as replacements grow")
    func inlineBudgetShrinksWithWideReplacements() {
        // A rule may put out far more than it matched, and the rewrite is
        // built inline, so reading a little can allocate a great deal. The
        // budget has to bound what is written, not only what is read.
        let wide = RewriteRules(overrides: RuleOverrides([
            .scalars(0x3000...0x3000): .output(
                String(repeating: "\u{1F600}", count: RuleFile.Limits.replacementScalars)
            ),
        ]))
        let budget = PasteboardWork.inlineBudget(for: wide)
        #expect(budget < PasteboardNormalizer.inlineTextBytes)
        #expect(budget > 0)
    }

    @Test("A selection past the inline budget still comes back rewritten")
    func selectionAboveTheBudgetGoesToTheQueue() {
        // The Services path has nowhere to hand a late answer, so past the
        // budget it dispatches and *waits*. A crowded table is what puts an
        // ordinary selection over that line — it used to take the flat 256 KB
        // ceiling instead, and ran three seconds inline on the main thread,
        // inside a call the system was already blocked on.
        var many = RuleOverrides()
        for index in 0..<2000 {
            many[.sequence([0x2014, UInt32(0x3000 + index)])] = .output("X")
        }
        let rules = RewriteRules(overrides: many)
        let budget = PasteboardWork.inlineBudget(for: rules)
        #expect(budget < PasteboardNormalizer.inlineTextBytes)

        let text = String(repeating: "\u{2014}\u{3000}", count: budget)
        #expect(text.utf8.count > budget)
        withPasteboard { pasteboard in
            write(text, to: pasteboard)
            let outcome = PasteboardWork.normalizeSelection(pasteboard, rules: rules)
            #expect(outcome.rewrittenItems == 1)
            #expect(pasteboard.string(forType: .string) == TextNormalizer.normalize(text, rules: rules))
        }
    }

    @Test("A rewrite that would not fit is left alone rather than truncated")
    func oversizedRewritesAreAbandoned() {
        // One rule may output hundreds of scalars for a single matched one,
        // so an ordinary copy can expand past anything the process can hold.
        // Half a clipboard would be worse than an unrewritten one.
        let replacement = String(repeating: "\u{1F600}", count: RuleFile.Limits.replacementScalars)
        let rules = RewriteRules(overrides: RuleOverrides([
            .scalars(0x3000...0x3000): .output(replacement),
        ]))
        let perMatch = replacement.utf8.count

        let fits = String(repeating: "\u{3000}", count: 64)
        let grew = TextNormalizer.normalize(fits, rules: rules)?.utf8.count ?? 0
        #expect(grew == 64 * perMatch)

        // The limit scales with the input, so this is a few kilobytes rather
        // than the tens of megabytes a flat ceiling would have to be filled to.
        let doesNot = String(repeating: "\u{3000}",
                             count: TextNormalizer.outputLimit(for: 0) / perMatch + 64)
        let abandoned = TextNormalizer.normalize(doesNot, rules: rules)?.utf8.count
        #expect(abandoned == nil, "grew to \(abandoned ?? 0) bytes instead of being left alone")
    }

    @Test("Every flavour abandons an oversized rewrite, not just plain text")
    func oversizedRewritesAreAbandonedInEveryFlavour() {
        // The ceiling has to hold for all four or they diverge: the plain
        // flavour would be left alone while the styled one was rewritten, and
        // one copy would paste differently depending on where it landed.
        let replacement = String(repeating: "\u{1F600}", count: RuleFile.Limits.replacementScalars)
        let rules = RewriteRules(overrides: RuleOverrides([
            .scalars(0x3000...0x3000): .output(replacement),
        ]))
        let count = TextNormalizer.outputLimit(for: 0) / replacement.utf8.count + 64
        let text = String(repeating: "\u{3000}", count: count)
        let rtf = "{\\rtf1\\ansi " + String(repeating: "\\u12288 ", count: count) + "}"

        #expect(HTMLTextRewriter.rewrite("<p>\(text)</p>", rules: rules) == nil)
        #expect(RTFTextRewriter.rewrite(Data(rtf.utf8), rules: rules) == nil)
        let built = TextNormalizer.normalize(NSAttributedString(string: text), rules: rules)?.length
        #expect(built == nil, "built \(built ?? 0) units instead of leaving it alone")

        // Under the limit the same documents come back rewritten — or this
        // would pass just as well if they never rewrote anything at all.
        let small = String(repeating: "\u{3000}", count: 4)
        let smallRTF = "{\\rtf1\\ansi " + String(repeating: "\\u12288 ", count: 4) + "}"
        #expect(HTMLTextRewriter.rewrite("<p>\(small)</p>", rules: rules) != nil)
        #expect(RTFTextRewriter.rewrite(Data(smallRTF.utf8), rules: rules) != nil)
        #expect(TextNormalizer.normalize(NSAttributedString(string: small), rules: rules) != nil)
    }

    @Test("What a rewrite may grow to follows what it was handed")
    func outputLimitScalesWithTheInput() {
        // A flat ceiling can only be reached by filling it, so a small copy
        // would take tens of megabytes to find out it did not fit.
        #expect(TextNormalizer.outputLimit(for: 8 << 20) > TextNormalizer.outputLimit(for: 1 << 10))
        // Never past what PasteBop will read back, however large the input.
        #expect(TextNormalizer.outputLimit(for: PasteboardNormalizer.maximumTextBytes)
                == TextNormalizer.maximumOutputBytes)
        // And never so tight that a short copy cannot grow at all.
        #expect(TextNormalizer.outputLimit(for: 0) >= 1 << 20)
    }

    @Test("The text PasteBop accepts fits the offsets its rewriters store")
    func theInputCeilingFitsTheNarrowOffsets() {
        // HTML and RTF address their input with Int32, which halves what a
        // large paste costs to take apart. Converting to it traps rather than
        // fails, so raising the ceiling past this would turn an enormous copy
        // into a crash.
        #expect(PasteboardNormalizer.maximumTextBytes <= Int(Int32.max))
        #expect(TextNormalizer.maximumOutputBytes <= Int(Int32.max))
    }

    @Test("An item whose flavours cannot all be rewritten is left whole")
    func oneFlavourGivingUpAbandonsTheItem() {
        // Every flavour of an item is the same text, and each is measured
        // against its own serialised size — a styled one is bigger, so it
        // gets a bigger budget. Plain text can run out of room while the HTML
        // beside it does not, and writing back only what fit leaves one copy
        // saying two different things depending on where it is pasted.
        let rules = RewriteRules(overrides: RuleOverrides([
            .scalars(0x3000...0x3000): .output(
                String(repeating: "\u{1F600}", count: RuleFile.Limits.replacementScalars)
            ),
        ]))
        let text = String(repeating: "\u{3000}", count: 1100)
        let padded = String(repeating: "<span style=\"font-weight:400\">x</span>", count: 30_000)
        let html = "<p>\(padded)\(text)</p>"

        // The premise: on their own the two disagree.
        #expect(TextNormalizer.attempt(text, rules: rules).value == nil)
        #expect(HTMLTextRewriter.attempt(html, rules: rules).value != nil)

        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data(text.utf8), forType: .string)
            item.setData(Data(html.utf8), forType: .html)
            pasteboard.writeObjects([item])

            let snapshot = PasteboardNormalizer.snapshot(pasteboard)
            let rewrite = PasteboardNormalizer.rewrite(snapshot, rules: rules)
            #expect(rewrite.items.first?.isEmpty ?? true)
        }
    }

    @Test("What a rewriter returns is never larger than it was allowed")
    func nothingComesBackOverTheLimit() {
        // The untouched tail and the markup are appended after the last
        // match, so checking only the splices let a document come back over
        // its ceiling — 1,111,559 bytes against a 1,048,576 byte limit.
        let rules = RewriteRules(overrides: RuleOverrides([
            .scalars(0x3000...0x3000): .output(
                String(repeating: "\u{1F600}", count: RuleFile.Limits.replacementScalars)
            ),
        ]))
        let count = TextNormalizer.outputLimit(for: 0) / 1024 - 1
        let text = String(repeating: "\u{3000}", count: count)
        let tail = String(repeating: "z", count: 50_000)
        let markup = String(repeating: "<b></b>", count: 2_000)

        let html = "<p>\(text)\(tail)\(markup)</p>"
        let htmlLimit = TextNormalizer.outputLimit(for: html.utf8.count)
        #expect(HTMLTextRewriter.rewrite(html, rules: rules)?.utf8.count ?? 0 <= htmlLimit)

        let rtf = "{\\rtf1\\ansi " + String(repeating: "\\u12288 ", count: count) + tail + "}"
        let rtfLimit = TextNormalizer.outputLimit(for: rtf.utf8.count)
        #expect(RTFTextRewriter.rewrite(Data(rtf.utf8), rules: rules)?.count ?? 0 <= rtfLimit)
    }

    @Test("The inline budget follows how deep substring matching goes")
    func inlineBudgetFollowsSharedPrefixLength() throws {
        // Counting the rules reads these two tables the same. They are not:
        // candidates sharing a first scalar are all tried at every occurrence
        // of it, and each is compared until it fails, so what costs is their
        // total length. The deep one measured 148 ms of main thread at a
        // budget set by rule count alone.
        func table(_ body: String) throws -> RewriteRules {
            RewriteRules(overrides: try RuleFile.decode("version: 1\nrules:\n" + body))
        }
        var spread = "", deep = ""
        for index in 0..<2000 {
            let tail = String(0x3100 + index, radix: 16, uppercase: true)
            spread += "  U+\(String(0x3000 + index, radix: 16, uppercase: true)) U+0061: \"x\"\n"
            deep += "  \(String(repeating: "U+3000 ", count: index % 60 + 2))U+\(tail): \"x\"\n"
        }

        // Two thousand rules that never queue behind each other are free.
        #expect(try PasteboardWork.inlineBudget(for: table(spread))
                == PasteboardNormalizer.inlineTextBytes)
        // Two thousand that do are not, by two orders of magnitude.
        let crowded = try PasteboardWork.inlineBudget(for: table(deep))
        #expect(crowded < PasteboardNormalizer.inlineTextBytes / 100)
    }

    @Test("A snapshot carries the text and nothing else")
    func snapshotIsJustText() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("a\u{2014}b".utf8), forType: .string)
            item.setData(Data([0xDE, 0xAD]), forType: .tiff)
            pasteboard.writeObjects([item])

            let snapshot = PasteboardNormalizer.snapshot(pasteboard)
            #expect(!snapshot.isEmpty)
            #expect(snapshot.changeCount == pasteboard.changeCount)
            // The image is not in the snapshot; it is only read when the
            // item has to be reproduced.
            #expect(snapshot.textBytes == 5)
        }
    }

    @Test("Rewriting a snapshot needs no pasteboard and no main thread")
    func rewriteIsPure() {
        withPasteboard { pasteboard in
            write("a\u{2014}b", to: pasteboard)
            let snapshot = PasteboardNormalizer.snapshot(pasteboard)
            let rewrite = PasteboardNormalizer.rewrite(snapshot, rules: .builtIn)
            #expect(!rewrite.isEmpty)
            #expect(rewrite.characterCount == 3)
            #expect(rewrite.tally.counts["2014"] == 1)
        }
    }

    @Test("A stale rewrite is dropped rather than clobbering a newer copy")
    func staleRewriteIsDropped() {
        withPasteboard { pasteboard in
            write("a\u{2014}b", to: pasteboard)
            let snapshot = PasteboardNormalizer.snapshot(pasteboard)
            let rewrite = PasteboardNormalizer.rewrite(snapshot, rules: .builtIn)

            // The user copies something else while the rewrite is in flight.
            write("something else entirely", to: pasteboard)

            let outcome = PasteboardNormalizer.apply(rewrite, to: pasteboard, from: snapshot)
            #expect(!outcome.didRewrite)
            #expect(pasteboard.string(forType: .string) == "something else entirely")
        }
    }

    @Test("An unchanged pasteboard accepts the rewrite")
    func freshRewriteIsApplied() {
        withPasteboard { pasteboard in
            write("a\u{2014}b", to: pasteboard)
            let snapshot = PasteboardNormalizer.snapshot(pasteboard)
            let rewrite = PasteboardNormalizer.rewrite(snapshot, rules: .builtIn)
            #expect(PasteboardNormalizer.apply(rewrite, to: pasteboard, from: snapshot).didRewrite)
            #expect(pasteboard.string(forType: .string) == "a--b")
        }
    }

    // MARK: - Size

    @Test("Text past the memory ceiling is not even read")
    func oversizedTextIsNotSnapshotted() {
        let huge = String(repeating: "a", count: PasteboardNormalizer.maximumTextBytes + 1)
        withPasteboard { pasteboard in
            write(huge, to: pasteboard)
            #expect(PasteboardNormalizer.snapshot(pasteboard).isEmpty)
        }
    }

    @Test("A selection is rewritten in place")
    func selectionRoundTrip() {
        withPasteboard { pasteboard in
            write("\u{201C}hi\u{201D}\u{2014}there", to: pasteboard)
            let outcome = PasteboardWork.normalizeSelection(pasteboard, rules: .builtIn)
            #expect(outcome.didRewrite)
            #expect(pasteboard.string(forType: .string) == "\"hi\"--there")
        }
    }

    @Test("A clean selection is left untouched")
    func cleanSelectionUntouched() {
        withPasteboard { pasteboard in
            write("already clean", to: pasteboard)
            let before = pasteboard.changeCount
            #expect(!PasteboardWork.normalizeSelection(pasteboard, rules: .builtIn).didRewrite)
            #expect(pasteboard.changeCount == before)
        }
    }

    @Test("A large selection still comes back rewritten, off the main thread")
    func largeSelectionGoesToTheQueue() {
        // Past the inline threshold, so this takes the dispatch-and-wait path.
        let big = String(repeating: "word ", count: 120_000) + "\u{2014}end"
        #expect(big.utf8.count > PasteboardNormalizer.inlineTextBytes)
        withPasteboard { pasteboard in
            write(big, to: pasteboard)
            let outcome = PasteboardWork.normalizeSelection(pasteboard, rules: .builtIn)
            #expect(outcome.didRewrite)
            #expect(pasteboard.string(forType: .string)?.hasSuffix("--end") == true)
        }
    }

    @Test("A selection is read one flavour at a time, never enumerated")
    func selectionReadsOnlyOneFlavour() {
        // The service pasteboard belongs to an app blocked inside the call.
        // Asking it to materialise a second flavour waits on it right back,
        // and the service dies on the system's 30 second timeout. This proves
        // the extra flavour is never touched.
        let decoy = CountingProvider()
        let other = NSPasteboard.PasteboardType("com.example.expensive")
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("a\u{2014}b".utf8), forType: .string)
            item.setDataProvider(decoy, forTypes: [other])
            pasteboard.writeObjects([item])

            #expect(PasteboardWork.normalizeSelection(pasteboard, rules: .builtIn).didRewrite)
            #expect(pasteboard.string(forType: .string) == "a--b")
            #expect(decoy.requests == 0)
        }
    }

    @Test("A styled selection comes back styled")
    func selectionKeepsStyling() throws {
        let styled = NSMutableAttributedString(string: "x \u{201C}bold\u{201D} y")
        styled.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 2, length: 6)
        )
        let rtf = try #require(styled.rtf(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [:]
        ))

        try withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(rtf, forType: .rtf)
            pasteboard.writeObjects([item])

            #expect(PasteboardWork.normalizeSelection(pasteboard, rules: .builtIn).didRewrite)
            let out = try #require(pasteboard.data(forType: .rtf))
            let decoded = try #require(NSAttributedString(rtf: out, documentAttributes: nil))
            #expect(decoded.string == "x \"bold\" y")
            let font = decoded.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }
    }

    @Test("The clipboard path reports back on the main actor")
    func clipboardCompletionRunsOnMain() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        write("a\u{2026}b", to: pasteboard)

        let outcome: PasteboardNormalizer.Outcome = await withCheckedContinuation { continuation in
            PasteboardWork.normalizeClipboard(pasteboard, rules: .builtIn) { outcome in
                MainActor.assertIsolated()
                continuation.resume(returning: outcome)
            }
        }
        #expect(outcome.didRewrite)
        #expect(pasteboard.string(forType: .string) == "a...b")
    }
}
