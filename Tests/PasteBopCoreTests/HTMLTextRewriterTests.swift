//
//  HTMLTextRewriterTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("HTML rewriter")
struct HTMLTextRewriterTests {

    @Test("Rewrites a character written as a reference", arguments: [
        "a&mdash;b", "a&#8212;b", "a&#x2014;b", "a&#X2014;b",
    ])
    func rewritesCharacterReferences(_ html: String) {
        // Left alone, the HTML flavour keeps an em dash where the plain one
        // has `--`, so the same copy pastes differently depending on target.
        #expect(HTMLTextRewriter.rewrite(html) == "a--b")
    }

    @Test("Leaves references it has no rule for alone", arguments: [
        "a&amp;b", "a&nope;b", "a&#65;b", "a & b", "a&b", "a&;b",
    ])
    func leavesOtherReferencesAlone(_ html: String) {
        #expect(HTMLTextRewriter.rewrite(html) == nil)
    }

    @Test("A rule spanning a reference matches, as it does in plain text")
    func substringAcrossAReference() throws {
        // References used to be looked up one scalar at a time, so a rule
        // whose first character arrived as `&mdash;` never matched — the HTML
        // flavour of a copy came out different from the plain one.
        let rules = RewriteRules(
            overrides: RuleOverrides([.sequence([0x2014, 0x0078]): .output("X")])
        )
        for html in ["a&mdash;xb", "a&#8212;xb", "a\u{2014}xb"] {
            #expect(HTMLTextRewriter.rewrite(html, rules: rules) == "aXb")
        }
        #expect(TextNormalizer.normalize("a\u{2014}xb", rules: rules) == "aXb")
    }

    @Test("References of different widths keep everything after them in place")
    func severalReferencesInOneNode() {
        // The map from the decoded stream back to the source drifts at every
        // reference, and each of these drifts by a different amount. Get it
        // wrong and the splices after the first one land on the wrong bytes.
        #expect(HTMLTextRewriter.rewrite("a&mdash;b&hellip;c&#8212;d\u{2014}e")
                == "a--b...c--d--e")
    }

    @Test("A reference with no rule survives beside ones that have")
    func unrewrittenReferencesAreLeftAsWritten() {
        // `&amp;` has no rule, so it must come back spelled exactly as it was
        // rather than as the character it decodes to.
        #expect(HTMLTextRewriter.rewrite("a&amp;b&mdash;c&amp;d\u{2026}e")
                == "a&amp;b--c&amp;d...e")
    }

    @Test("A reference inside an attribute is left alone")
    func referenceInsideAnAttributeIsUntouched() {
        #expect(HTMLTextRewriter.rewrite("<a title=\"a&mdash;b\">c</a>") == nil)
    }

    @Test("A tag still ends when the text after it begins with a combining scalar", arguments: [
        "\u{200D}",  // zero-width joiner, as an emoji sequence begins with
        "\u{FE0F}",  // variation selector, on any emoji written for colour
        "\u{0301}",  // a combining acute, from decomposed accented text
        "\u{E0041}", // a tag character, the block PasteBop deletes
    ])
    func markupEndsBeforeACombiningScalar(_ joiner: String) throws {
        // These join the `>` before them into one Character, so scanning the
        // markup by character never sees the tag end: the rest of the page is
        // taken for markup and comes back unrewritten. Found by fuzzing HTML
        // against plain text, which until then was only checked for crashes.
        // Against plain text rather than a literal, because some of these are
        // themselves rewritten — a tag character is deleted on sight.
        let text = joiner + "\u{2014}"
        let plain = try #require(TextNormalizer.normalize(text, escaping: .html))
        #expect(HTMLTextRewriter.rewrite("<p>\(text)</p>") == "<p>\(plain)</p>")
        #expect(HTMLTextRewriter.rewrite("<!-- x -->\(text)") == "<!-- x -->\(plain)")
    }

    @Test("A > inside an attribute does not end the tag")
    func greaterThanInsideAnAttribute() {
        // Taking the first > ended the tag early, and everything after it was
        // rewritten as text — which rewrote the quotes inside the attribute
        // and corrupted the markup.
        let html = "<a title=\"x > \u{201C}q\u{201D}\">t\u{2014}u</a>"
        #expect(HTMLTextRewriter.rewrite(html) == "<a title=\"x > \u{201C}q\u{201D}\">t--u</a>")
    }

    @Test("A > inside a single-quoted attribute does not end the tag either")
    func greaterThanInsideSingleQuotes() {
        let html = "<a title='a > b'>x\u{2014}y</a>"
        #expect(HTMLTextRewriter.rewrite(html) == "<a title='a > b'>x--y</a>")
    }

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
