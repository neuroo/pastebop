//
//  RTFTextRewriterTests.swift
//  PasteBopCoreTests
//

import AppKit
import Testing
@testable import PasteBopCore

@Suite("RTF rewriter")
struct RTFTextRewriterTests {

    private func rewrite(_ rtf: String, rules: RewriteRules = .builtIn) -> String? {
        RTFTextRewriter.rewrite(Data(rtf.utf8), rules: rules).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func rules(_ body: String) throws -> RewriteRules {
        // defaults: [] so the table is exactly what the test declared,
        // rather than the built-in table with it laid over the top.
        RewriteRules(overrides: try RuleFile.decode("version: 1\nrules:\n" + body), defaults: [])
    }

    /// What a reader makes of it, which is what the user pastes.
    private func text(of rtf: String) -> String? {
        NSAttributedString(rtf: Data(rtf.utf8), documentAttributes: nil)?.string
    }

    /// What TextEdit, Mail, Safari and every other Cocoa app writes: code page
    /// 1252 bytes, `\uc0` and `\uN` for the rest.
    private static let cocoa = #"""
        {\rtf1\ansi\ansicpg1252\cocoartf2870
        {\fonttbl\f0\fswiss\fcharset0 Helvetica;}
        {\colortbl;\red255\green255\blue255;}
        {\*\expandedcolortbl;;}
        \pard\pardirnatural\partightenfactor0

        \f0\fs24 \cf0 Plain \'93quoted\'94 \'97 it\'92s\'85 zw\uc0\u8203 sp caf\'e9 \u8594  end}
        """#

    @Test("A later \\uc does not change how a replacement is written", arguments: [
        "{\\rtf1\\ansi\\uc1 \\'22xy}",
        "{\\rtf1\\ansi\\uc2 \\'22xy}",
        "{\\rtf1\\ansi \\'22xy\\uc2 }",
    ])
    func fallbackCountMatchesThePositionNotTheEnd(_ rtf: String) throws {
        // The escape is written with the skip count in force when the run is
        // flushed. A \uc later in the run put the wrong number of fallback
        // characters after \uN, and the surplus was read as literal text —
        // "éy" came back as "é?y".
        let table = try rules(#"  U+0022 U+0078: "\#u{00E9}""#)
        let out = try #require(RTFTextRewriter.rewrite(Data(rtf.utf8), rules: table))
        let read = try #require(NSAttributedString(rtf: out, documentAttributes: nil)).string
        #expect(read == "\u{00E9}y")
    }

    @Test("A substring rule does not match across a paragraph break", arguments: [
        "\\par", "\\line", "\\cell", "\\row", "\\sect", "\\page",
    ])
    func substringsDoNotCrossSeparators(_ separator: String) throws {
        // Matching across one joins words that were never adjacent: the run
        // was replaced at the first half and the second half deleted, so
        // "foo<break>bar" came back as "X<break>" with bar gone.
        let table = try rules(#"  U+0066 U+006F U+006F U+0062 U+0061 U+0072: "X""#)
        let rtf = "{\\rtf1\\ansi foo\(separator) bar}"
        #expect(RTFTextRewriter.rewrite(Data(rtf.utf8), rules: table) == nil)
    }

    @Test("A substring rule still matches across formatting")
    func substringsCrossFormatting() throws {
        // Bold in the middle of a word is formatting, not a boundary.
        let table = try rules(#"  U+0066 U+006F U+006F U+0062 U+0061 U+0072: "X""#)
        let rtf = "{\\rtf1\\ansi foo\\b bar}"
        let out = try #require(RTFTextRewriter.rewrite(Data(rtf.utf8), rules: table))
        #expect(try #require(String(bytes: out, encoding: .utf8)).contains("X"))
    }

    @Test("Rewrites only the text of a Cocoa document")
    func cocoaDocument() {
        let result = rewrite(Self.cocoa)
        #expect(result == #"""
            {\rtf1\ansi\ansicpg1252\cocoartf2870
            {\fonttbl\f0\fswiss\fcharset0 Helvetica;}
            {\colortbl;\red255\green255\blue255;}
            {\*\expandedcolortbl;;}
            \pard\pardirnatural\partightenfactor0

            \f0\fs24 \cf0 Plain "quoted" -- it's... zw\uc0 sp caf\'e9 -> end}
            """#)
        #expect(result.flatMap(text) == "Plain \"quoted\" -- it's... zwsp caf\u{e9} -> end")
    }

    @Test("Rewrites what Word writes: uc1 fallbacks and named characters")
    func wordDocument() {
        let input = #"{\rtf1\ansi\ansicpg1252\uc1\deff0{\fonttbl{\f0\fnil\fcharset0 Calibri;}}"#
            + #"\pard\f0 He said \u8220\'93hi\u8221\'94 \emdash\~now\rquote s\par}"#
        #expect(rewrite(input) == #"{\rtf1\ansi\ansicpg1252\uc1\deff0{\fonttbl{\f0\fnil\fcharset0 Calibri;}}"#
                + #"\pard\f0 He said "hi" -- now's\par}"#)
    }

    @Test("Leaves destinations that are not document text alone")
    func skipsDestinations() {
        let input = #"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 Foo\'92s Font;}}"#
            + #"{\*\generator Riched20 \'93x\'94;}{\colortbl;\red0\green0\blue0;}"#
            + #"\pard{\listtext\'95\tab}{\field{\*\fldinst{HYPERLINK "x\'97y"}}"#
            + #"{\fldrslt a\'97b}} \'93done\'94}"#
        #expect(rewrite(input) == #"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 Foo\'92s Font;}}"#
                + #"{\*\generator Riched20 \'93x\'94;}{\colortbl;\red0\green0\blue0;}"#
                + #"\pard{\listtext\'95\tab}{\field{\*\fldinst{HYPERLINK "x\'97y"}}{\fldrslt a--b}} "done"}"#)
    }

    @Test("Reads code page bytes only where it knows the code page", arguments: [
        // A Japanese document: the pairs are untouched, the unicode escape and
        // its fallback are rewritten together.
        (#"{\rtf1\ansi\ansicpg932\deff0{\fonttbl{\f0\fcharset128 Mincho;}}\pard\f0 \'93\'fa \u8220\'93 x}"#,
         #"{\rtf1\ansi\ansicpg932\deff0{\fonttbl{\f0\fcharset128 Mincho;}}\pard\f0 \'93\'fa " x}"#),
        // The font in force decides, and a group restores the one before it.
        (#"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 A;}{\f1\fcharset128 B;}}\pard\f1 \'93\'fa\f0 \'93}"#,
         #"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 A;}{\f1\fcharset128 B;}}\pard\f1 \'93\'fa\f0 "}"#),
        (#"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 A;}{\f1\fcharset128 B;}}\pard\f0 {\f1 \'93}\'93}"#,
         #"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 A;}{\f1\fcharset128 B;}}\pard\f0 {\f1 \'93}"}"#),
        // A double-byte run in an ANSI font.
        (#"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 A;}}\pard\dbch\f0 \'93\'fa\loch\f0 \'93}"#,
         #"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 A;}}\pard\dbch\f0 \'93\'fa\loch\f0 "}"#),
        // Mac Roman.
        (#"{\rtf1\mac\deff0{\fonttbl{\f0\fcharset77 Geneva;}}\pard\f0 \'d2quoted\'d3 \'d1 dash}"#,
         #"{\rtf1\mac\deff0{\fonttbl{\f0\fcharset77 Geneva;}}\pard\f0 "quoted" -- dash}"#),
    ])
    func codePages(input: String, expected: String) {
        #expect(rewrite(input) == expected)
    }

    @Test("Delimits a control word the replacement would otherwise extend")
    func delimitsControlWords() throws {
        let table = try rules(#"  U+00BD: "1/2""#)
        #expect(rewrite(#"{\rtf1\ansi\uc0\b\'bd x}"#, rules: table) == #"{\rtf1\ansi\uc0\b 1/2 x}"#)
        #expect(rewrite(#"{\rtf1\ansi\uc0\b \'bd}"#, rules: table) == #"{\rtf1\ansi\uc0\b 1/2}"#)
        #expect(rewrite(#"{\rtf1\ansi\uc0 a\'bd\'bd}"#, rules: table) == #"{\rtf1\ansi\uc0 a1/21/2}"#)
        // Deleting leaves the word needing a delimiter; a space replacement
        // must not become the delimiter.
        #expect(rewrite(#"{\rtf1\ansi\uc0\b\u8203 x}"#) == #"{\rtf1\ansi\uc0\b x}"#)
        #expect(rewrite(#"{\rtf1\ansi\uc0\b\~x}"#) == #"{\rtf1\ansi\uc0\b  x}"#)
        #expect(text(of: #"{\rtf1\ansi\uc0\b  x}"#) == " x")
    }

    @Test("Joins surrogate pairs, in either sign convention")
    func surrogates() throws {
        let table = try rules(#"  U+1F600: "smile""#)
        #expect(rewrite(#"{\rtf1\ansi\uc0 \u55357 \u56832  x}"#, rules: table)
                == #"{\rtf1\ansi\uc0 smile x}"#)
        #expect(rewrite(#"{\rtf1\ansi\uc0 \u-10179 \u-8704  x}"#, rules: table)
                == #"{\rtf1\ansi\uc0 smile x}"#)
        #expect(rewrite(#"{\rtf1\ansi\uc1 \u-10179 ?\u-8704 ? x}"#, rules: table)
                == #"{\rtf1\ansi\uc1 smile x}"#)
        #expect(rewrite(#"{\rtf1\ansi\uc0 \u55357 \u56832  x}"#) == nil)
        #expect(rewrite(#"{\rtf1\ansi\uc0 \u55357 x}"#, rules: table) == nil)
    }

    @Test("Encodes a replacement outside ASCII with the fallback count in force")
    func unicodeReplacement() throws {
        let table = try rules("  U+00AB: \"\u{201C}\"")
        let zero = rewrite(#"{\rtf1\ansi\uc0 \'abx}"#, rules: table)
        #expect(zero == #"{\rtf1\ansi\uc0 \u8220 x}"#)
        #expect(zero.flatMap(text) == "\u{201C}x")
        let one = rewrite(#"{\rtf1\ansi\uc1 \'abx}"#, rules: table)
        #expect(one == #"{\rtf1\ansi\uc1 \u8220?x}"#)
        #expect(one.flatMap(text) == "\u{201C}x")
    }

    @Test("Escapes braces and backslashes a replacement introduces")
    func escapesReplacementSyntax() throws {
        let table = try rules(#"  U+2014: "a{b}c\\""#)
        let result = rewrite(#"{\rtf1\ansi\uc0 \'97}"#, rules: table)
        #expect(result == #"{\rtf1\ansi\uc0 a\{b\}c\\}"#)
        #expect(result.flatMap(text) == #"a{b}c\"#)
    }

    @Test("Keeps formatting that sits inside a substring match")
    func formattingInsideMatch() throws {
        let table = try rules(#"  " \#u{2014} ": " - ""#)
        let result = rewrite(#"{\rtf1\ansi\uc0 a \'97\b  b}"#, rules: table)
        #expect(result == #"{\rtf1\ansi\uc0 a - \b b}"#)
        #expect(result.flatMap(text) == "a - b")
    }

    @Test("Returns nil when no text needs rewriting")
    func unchanged() {
        #expect(rewrite(#"{\rtf1\ansi caf\'e9 plain}"#) == nil)
        #expect(rewrite(#"{\rtf1\ansi\uc0 \u233 }"#) == nil)
        #expect(rewrite("") == nil)
        #expect(RTFTextRewriter.rewrite(Data()) == nil)
    }

    @Test("Rewriting is idempotent")
    func idempotent() {
        let once = rewrite(Self.cocoa)
        #expect(once != nil)
        #expect(once.flatMap { rewrite($0) } == nil)
    }

    @Test("Survives malformed input", arguments: [
        #"\"#, #"\'9"#, #"{\rtf1 \'zz\'93}"#, #"{{{\'93"#, #"}}}\'93"#, #"{\rtf1\bin99999 \'93}"#,
        #"{\rtf1\u"#, #"{\rtf1\u8220"#, #"{\rtf1\uc-5\u8220\'93}"#, #"{\rtf1\fonttbl"#,
        #"{\rtf1{\fonttbl{\f0"#,
        #"{\rtf1\u55357 \u"#, #"{\rtf1\u55357 \u5"#, #"{\rtf1\ansicpg \'93}"#, #"{\rtf1\f \'93}"#,
    ])
    func malformed(_ input: String) {
        let result = rewrite(input)
        // Whatever comes back reads the same or shorter than the plain rewrite
        // would; the point is that it came back.
        #expect(result == nil || result?.isEmpty == false)
    }

    @Test("Agrees with the attributed-string path on what AppKit writes")
    func matchesAppKit() {
        let styled = NSMutableAttributedString(
            string: "Plain \u{201C}quoted\u{201D} \u{2014} it\u{2019}s\u{2026} "
        )
        styled.append(NSAttributedString(
            string: "bold\u{2013}dash \u{4F60}\u{597D} \u{1F600}",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        ))
        let range = NSRange(location: 0, length: styled.length)
        guard let rtf = styled.rtf(from: range, documentAttributes: [:]),
              let rewritten = RTFTextRewriter.rewrite(rtf),
              let result = NSAttributedString(rtf: rewritten, documentAttributes: nil) else {
            Issue.record("AppKit could not round-trip the sample")
            return
        }
        #expect(result.string == TextNormalizer.normalized(styled.string))
        var boldRuns: [String] = []
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                boldRuns.append(result.attributedSubstring(from: range).string)
            }
        }
        #expect(boldRuns == ["bold-dash \u{4F60}\u{597D} \u{1F600}"])
    }
}
