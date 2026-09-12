//
//  PasteboardNormalizerTests.swift
//  PasteBopCoreTests
//
//  These run against a private pasteboard, never the user's own.
//

import AppKit
import Testing
@testable import PasteBopCore

@MainActor
@Suite("Pasteboard normalizer")
struct PasteboardNormalizerTests {

    /// A scratch pasteboard, released when the body returns.
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private func write(_ types: [(NSPasteboard.PasteboardType, Data)], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
    }

    // MARK: - Plain text

    @Test("Rewrites plain text")
    func rewritesPlainText() {
        withPasteboard { pasteboard in
            write([(.string, Data("\u{201C}hi\u{201D}\u{2014}there".utf8))], to: pasteboard)

            let outcome = PasteboardNormalizer.normalize(pasteboard)

            #expect(outcome.didRewrite)
            #expect(outcome.rewrittenItems == 1)
            #expect(pasteboard.string(forType: .string) == "\"hi\"--there")
            #expect(outcome.changeCount == pasteboard.changeCount)
        }
    }

    @Test("Leaves a clean pasteboard completely alone")
    func leavesCleanPasteboardAlone() {
        withPasteboard { pasteboard in
            write([(.string, Data("already clean, caf\u{e9}".utf8))], to: pasteboard)
            let before = pasteboard.changeCount

            let outcome = PasteboardNormalizer.normalize(pasteboard)

            #expect(!outcome.didRewrite)
            // The change count must not move, or the monitor would see its own
            // no-op as a new copy.
            #expect(pasteboard.changeCount == before)
            #expect(pasteboard.string(forType: .string) == "already clean, caf\u{e9}")
        }
    }

    @Test("Does nothing to an empty pasteboard")
    func emptyPasteboard() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let before = pasteboard.changeCount
            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == before)
        }
    }

    @Test("Rewriting is idempotent")
    func idempotent() {
        withPasteboard { pasteboard in
            write([(.string, Data("a\u{2014}b".utf8))], to: pasteboard)
            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)
            let after = pasteboard.changeCount
            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == after)
        }
    }

    // MARK: - Other flavours

    @Test("Preserves flavours it does not understand")
    func preservesUnknownFlavours() throws {
        let custom = NSPasteboard.PasteboardType("com.example.binary")
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        try withPasteboard { pasteboard in
            write([(.string, Data("\u{2014}".utf8)), (custom, payload)], to: pasteboard)

            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)

            #expect(pasteboard.string(forType: .string) == "--")
            let recovered = try #require(pasteboard.data(forType: custom))
            #expect(recovered == payload)
        }
    }

    @Test("Rewrites RTF and keeps its styling")
    func rewritesRTF() throws {
        let styled = NSMutableAttributedString(string: "x \u{201C}bold\u{201D} y")
        let bold = NSRange(location: 3, length: 4)
        styled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: bold)
        let rtf = try #require(styled.rtf(from: NSRange(location: 0, length: styled.length),
                                          documentAttributes: [:]))

        try withPasteboard { pasteboard in
            write([(.rtf, rtf)], to: pasteboard)

            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)

            let data = try #require(pasteboard.data(forType: .rtf))
            let result = try #require(NSAttributedString(rtf: data, documentAttributes: nil))
            #expect(result.string == "x \"bold\" y")

            let font = result.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }
    }

    @Test("Rewrites HTML text without touching its markup")
    func rewritesHTML() throws {
        let html = "<p title=\"\u{2014}\">\u{201C}hi\u{201D}</p>"

        try withPasteboard { pasteboard in
            write([(.html, Data(html.utf8))], to: pasteboard)

            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)

            let data = try #require(pasteboard.data(forType: .html))
            #expect(String(data: data, encoding: .utf8) == "<p title=\"\u{2014}\">\"hi\"</p>")
        }
    }

    @Test("Rewrites UTF-16 plain text, which some apps write instead")
    func rewritesUTF16PlainText() throws {
        // A flavour in `textTypes` that nothing was covering. It is the one
        // whose rewrite has to be re-encoded on the way out, so a failure
        // there would read as "nothing changed".
        let utf16 = PasteboardNormalizer.utf16PlainText
        try withPasteboard { pasteboard in
            let text = "a\u{2014}b\u{2026}"
            write([(utf16, try #require(text.data(using: .utf16)))], to: pasteboard)

            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)
            let back = try #require(pasteboard.data(forType: utf16))
            #expect(String(data: back, encoding: .utf16) == "a--b...")
        }
    }

    @Test("Rewrites UTF-16 in the host's order, with a mark and without")
    func rewritesNativeUTF16PlainText() throws {
        // It sits beside the UTF-8 flavour of the same copy, so leaving it
        // out meant one item saying two different things: the UTF-8 rewritten
        // and this still holding the em dash. Without a mark it must be read
        // in the host's order -- `.utf16` alone assumes big endian and would
        // decode every character wrongly.
        for marked in [true, false] {
            let text = "a\u{2014}b"
            let data = marked
                ? try #require(text.data(using: .utf16))
                : try #require(text.data(using: .utf16LittleEndian))

            try withPasteboard { pasteboard in
                write([(PasteboardNormalizer.utf16NativePlainText, data)], to: pasteboard)
                #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)

                let back = try #require(
                    pasteboard.data(forType: PasteboardNormalizer.utf16NativePlainText)
                )
                let encoding: String.Encoding = marked ? .utf16 : .utf16LittleEndian
                #expect(String(data: back, encoding: encoding) == "a--b")
                // And the UTF-8 flavour beside it says the same thing.
                #expect(pasteboard.string(forType: .string) == "a--b")
            }
        }
    }

    @Test("Rewrites RTFD, keeping the attachment it carries")
    func rewritesRTFD() throws {
        // The attributed path, through the pasteboard rather than directly:
        // it is the one flavour built by Cocoa rather than spliced as bytes.
        let attributed = NSMutableAttributedString(string: "a\u{2014}b")
        attributed.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 12),
            range: NSRange(location: 0, length: 1)
        )
        let whole = NSRange(location: 0, length: attributed.length)
        let rtfd = try #require(attributed.rtfd(from: whole, documentAttributes: [:]))

        try withPasteboard { pasteboard in
            write([(.rtfd, rtfd)], to: pasteboard)
            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)

            let back = try #require(pasteboard.data(forType: .rtfd))
            let read = try #require(NSAttributedString(rtfd: back, documentAttributes: nil))
            #expect(read.string == "a--b")
            // The styling of what was replaced is still on the first run.
            #expect(read.attribute(.font, at: 0, effectiveRange: nil) != nil)
        }
    }

    @Test("Handles several items")
    func multipleItems() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let items = ["a\u{2014}b", "clean", "c\u{2026}d"].map { text -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setData(Data(text.utf8), forType: .string)
                return item
            }
            pasteboard.writeObjects(items)

            let outcome = PasteboardNormalizer.normalize(pasteboard)

            #expect(outcome.rewrittenItems == 2)
            let strings = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }
            #expect(strings == ["a--b", "clean", "c...d"])
        }
    }

    // MARK: - Non-text payloads

    @Test("Leaves a picture alone without reading it")
    func imageIsNeverRead() {
        let picture = CountingDataProvider(bytes: [0x89, 0x50, 0x4E, 0x47])
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(picture, forTypes: [.png])
            pasteboard.writeObjects([item])
            let before = pasteboard.changeCount

            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == before)
            // The whole point: a 50 MB image must not be pulled into memory
            // just to discover there is no text beside it.
            #expect(picture.requests == 0)
        }
    }

    @Test("Does not read a picture beside text that needs no change")
    func imageBesideCleanTextIsNotRead() {
        let picture = CountingDataProvider(bytes: [1, 2, 3])
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("already clean".utf8), forType: .string)
            item.setDataProvider(picture, forTypes: [.tiff])
            pasteboard.writeObjects([item])

            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(picture.requests == 0)
        }
    }

    @Test("Reads a picture only when the text beside it changed, and keeps it intact")
    func imageBesideDirtyTextIsPreserved() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF]
        let picture = CountingDataProvider(bytes: bytes)
        try withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("a\u{2014}b".utf8), forType: .string)
            item.setDataProvider(picture, forTypes: [.tiff])
            pasteboard.writeObjects([item])

            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.string(forType: .string) == "a--b")
            #expect(picture.requests == 1)
            let preserved = try #require(pasteboard.data(forType: .tiff))
            #expect(preserved == Data(bytes))
        }
    }

    @Test("Never rewrites a copied file, whose text is its path", arguments: [
        NSPasteboard.PasteboardType.fileURL, .URL,
    ])
    func filesAndLinksAreLeftAlone(_ addressType: NSPasteboard.PasteboardType) {
        withPasteboard { pasteboard in
            // A file named with an em dash: the path must paste exactly.
            write([
                (addressType, Data("file:///tmp/report%E2%80%94final.pdf".utf8)),
                (.string, Data("/tmp/report\u{2014}final.pdf".utf8)),
            ], to: pasteboard)
            let before = pasteboard.changeCount

            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == before)
            #expect(pasteboard.string(forType: .string) == "/tmp/report\u{2014}final.pdf")
        }
    }

    @Test("A file beside ordinary text still protects the whole clipboard")
    func fileItemBlocksNothingElse() {
        // Two items: a file, and a separate plain-text item. Only the text
        // item is rewritten; the file item is reproduced untouched.
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let file = NSPasteboardItem()
            file.setData(Data("file:///tmp/x\u{2014}y".utf8), forType: .fileURL)
            file.setData(Data("/tmp/x\u{2014}y".utf8), forType: .string)
            let text = NSPasteboardItem()
            text.setData(Data("note\u{2026}".utf8), forType: .string)
            pasteboard.writeObjects([file, text])

            #expect(PasteboardNormalizer.normalize(pasteboard).rewrittenItems == 1)
            let strings = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }
            #expect(strings == ["/tmp/x\u{2014}y", "note..."])
        }
    }

    @Test("Leaves text too large to handle on the main thread alone")
    func oversizedTextIsLeftAlone() {
        // One byte over the limit: rewriting it would stall whatever app the
        // Services entry was invoked from.
        let huge = String(repeating: "a", count: PasteboardNormalizer.maximumTextBytes)
            + "\u{2014}"
        withPasteboard { pasteboard in
            write([(.string, Data(huge.utf8))], to: pasteboard)
            let before = pasteboard.changeCount

            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == before)
            #expect(pasteboard.string(forType: .string)?.hasSuffix("\u{2014}") == true)
        }
    }

    @Test("Still rewrites text just under the limit")
    func largeButAcceptableText() {
        let big = String(repeating: "a", count: 1 << 20) + "\u{2014}"
        withPasteboard { pasteboard in
            write([(.string, Data(big.utf8))], to: pasteboard)
            #expect(PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.string(forType: .string)?.hasSuffix("--") == true)
        }
    }

    // MARK: - Safety

    @Test("Never rewrites content a password manager concealed")
    func skipsConcealed() {
        withPasteboard { pasteboard in
            write([
                (.string, Data("p\u{2014}ssword".utf8)),
                (PasteboardNormalizer.concealedType, Data()),
            ], to: pasteboard)
            let before = pasteboard.changeCount

            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == before)
            #expect(pasteboard.string(forType: .string) == "p\u{2014}ssword")
        }
    }

    @Test("Never rewrites content marked transient")
    func skipsTransient() {
        withPasteboard { pasteboard in
            write([
                (.string, Data("a\u{2014}b".utf8)),
                (PasteboardNormalizer.transientType, Data()),
            ], to: pasteboard)

            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.string(forType: .string) == "a\u{2014}b")
        }
    }

    @Test("Bails out rather than dropping a flavour it cannot read")
    func bailsOnUnreadableFlavour() {
        let provider = SilentDataProvider()
        let opaque = NSPasteboard.PasteboardType("com.example.promised")

        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("a\u{2014}b".utf8), forType: .string)
            // Declares a type but never supplies bytes for it, the way a
            // promise from an unresponsive app behaves.
            item.setDataProvider(provider, forTypes: [opaque])
            pasteboard.writeObjects([item])

            let before = pasteboard.changeCount
            #expect(!PasteboardNormalizer.normalize(pasteboard).didRewrite)
            #expect(pasteboard.changeCount == before)
            #expect(pasteboard.string(forType: .string) == "a\u{2014}b")
        }
    }
}

/// Supplies bytes on demand and counts how often it was asked, so a test can
/// prove a payload was never read.
private final class CountingDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let bytes: [UInt8]
    private(set) var requests = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requests += 1
        item.setData(Data(bytes), forType: type)
    }
}

/// Declares a type and then supplies nothing for it.
private final class SilentDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {}
}
