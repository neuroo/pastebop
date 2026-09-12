//
//  AttachmentTests.swift
//  PasteBopCoreTests
//

import AppKit
import Testing
@testable import PasteBopCore

@Suite("Attachments")
struct AttachmentTests {

    private func attributed(_ text: String) -> NSMutableAttributedString {
        let attachment = NSTextAttachment()
        attachment.contents = Data("payload".utf8)
        attachment.fileType = "public.plain-text"
        let result = NSMutableAttributedString(string: text)
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    private func attachments(in text: NSAttributedString) -> Int {
        var found = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { found += 1 }
        }
        return found
    }

    @Test("An attachment survives rewriting the text around it")
    func attachmentSurvives() throws {
        // U+FFFC marks where the attachment sits. Rewriting it away deletes
        // the image or file that was copied, leaving nothing to paste.
        let input = attributed("\u{201C}x\u{201D} ")
        #expect(attachments(in: input) == 1)

        let output = try #require(TextNormalizer.normalize(input))
        #expect(output.string.hasPrefix("\"x\""))
        #expect(attachments(in: output) == 1)
    }

    @Test("A flag keeps the tag characters that name it")
    func emojiTagSequenceSurvives() {
        // Tag characters are deleted because they are how hidden instructions
        // are smuggled into copied text. After a black flag they spell a
        // country instead, and deleting them leaves a bare black flag.
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        #expect(TextNormalizer.normalize("from \(england) today") == nil)
    }

    @Test("Tag characters that are not a flag are still removed", arguments: [
        // Stray, with no flag in front: the smuggling vector.
        "a\u{E0067}\u{E0062}b",
        // After a flag but never terminated, so not a sequence.
        "\u{1F3F4}\u{E0067}b",
        // Terminator with nothing before it.
        "\u{1F3F4}\u{E007F}b",
    ])
    func strayTagCharactersAreRemoved(_ text: String) {
        let rewritten = TextNormalizer.normalize(text)
        #expect(rewritten != nil)
        #expect(rewritten?.unicodeScalars.contains { (0xE0000...0xE007F).contains($0.value) } == false)
    }

    @Test("Nothing rewrites the object replacement character")
    func objectReplacementIsNotInTheTable() {
        #expect(RewriteRules.builtIn.rule(for: 0xFFFC) == nil)
        #expect(TextNormalizer.normalize("a\u{FFFC}b") == nil)
    }
}
