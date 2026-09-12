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
