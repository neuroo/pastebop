//
//  HTMLTextRewriterTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("HTML rewriter")
struct HTMLTextRewriterTests {

    @Test("Rewrites text nodes")
    func rewritesText() {
        #expect(HTMLTextRewriter.rewrite("<p>\u{201C}hi\u{201D}</p>") == "<p>\"hi\"</p>")
        #expect(HTMLTextRewriter.rewrite("a\u{2014}b <b>c\u{2026}</b> d") == "a--b <b>c...</b> d")
    }

    @Test("Leaves attribute values alone")
    func preservesAttributes() {
        // Rewriting the guillemets here would produce title="a "b" c" and break
        // the attribute.
        let input = "<a title=\"a \u{ab}b\u{bb} c\">x</a>"
        #expect(HTMLTextRewriter.rewrite(input) == nil)
    }

    @Test("Rewrites text without disturbing the tag around it")
    func rewritesTextNotTag() {
        let input = "<a title=\"\u{2014}\">\u{2014}</a>"
        #expect(HTMLTextRewriter.rewrite(input) == "<a title=\"\u{2014}\">--</a>")
    }

    @Test("Escapes markup characters a replacement introduces")
    func escapesReplacementMarkup() {
        // LEFTWARDS ARROW becomes "<-", which must not read as a tag.
        #expect(HTMLTextRewriter.rewrite("<p>a \u{2190} b</p>") == "<p>a &lt;- b</p>")
        #expect(HTMLTextRewriter.rewrite("<p>\u{21d4}</p>") == "<p>&lt;=&gt;</p>")
        #expect(HTMLTextRewriter.rewrite("<p>\u{2192}</p>") == "<p>-&gt;</p>")
    }

    @Test("Leaves comments alone")
    func preservesComments() {
        #expect(HTMLTextRewriter.rewrite("<!-- \u{2014} -->") == nil)
        #expect(HTMLTextRewriter.rewrite("<!-- \u{2014} -->\u{2014}") == "<!-- \u{2014} -->--")
    }

    @Test("Leaves script and style bodies alone")
    func preservesRawText() {
        // A curly quote inside a CSS or JS string is part of that string.
        #expect(HTMLTextRewriter.rewrite("<style>p::after{content:\"\u{201C}\"}</style>") == nil)
        #expect(HTMLTextRewriter.rewrite("<script>var s = \"a\u{2014}b\";</script>") == nil)
        #expect(HTMLTextRewriter.rewrite("<SCRIPT>\u{2014}</SCRIPT>\u{2014}")
                == "<SCRIPT>\u{2014}</SCRIPT>--")
    }

    @Test("A tag whose name merely starts with script is not raw text")
    func scriptPrefixIsNotScript() {
        #expect(HTMLTextRewriter.rewrite("<scripting>\u{2014}</scripting>")
                == "<scripting>--</scripting>")
    }

    @Test("Returns nil when no text node changes")
    func unchanged() {
        #expect(HTMLTextRewriter.rewrite("<p>plain ascii</p>") == nil)
        #expect(HTMLTextRewriter.rewrite("<p>caf\u{e9}</p>") == nil)
        #expect(HTMLTextRewriter.rewrite("") == nil)
    }

    @Test("Survives malformed markup", arguments: [
        "<p>\u{2014}",
        "<p \u{2014}",
        "<!-- unterminated \u{2014}",
        "<style>\u{2014}",
        "\u{2014}<",
        "<<\u{2014}>>",
    ])
    func malformed(_ input: String) {
        // No crash and no invented markup: whatever comes back must still
        // contain every angle bracket the input had.
        let result = HTMLTextRewriter.rewrite(input) ?? input
        #expect(result.filter { $0 == "<" }.count == input.filter { $0 == "<" }.count)
    }

    @Test("Rewriting is idempotent")
    func idempotent() {
        let input = "<p title=\"\u{2014}\">a \u{2014} b \u{2190} c</p><!-- \u{2026} -->"
        let once = HTMLTextRewriter.rewrite(input) ?? input
        #expect(HTMLTextRewriter.rewrite(once) == nil)
    }
}
