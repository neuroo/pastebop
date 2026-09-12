//
//  HTMLTextRewriter.swift
//  PasteBopCore
//

import Foundation

/// Rewrites the text of an HTML fragment, leaving its markup byte-identical.
///
/// Substituting blindly is unsafe: `«` to `"` inside `title="«x»"` breaks the
/// attribute, and `←` to `<-` in a text node opens a tag. So only text nodes
/// are rewritten, with markup characters in the output escaped. This is a
/// splitter, not a parser: it recognises comments, tags, and the raw bodies of
/// `<script>` and `<style>`, and nothing else.
enum HTMLTextRewriter {

    private static let rawTextElements = ["script", "style"]

    /// The rewritten fragment, or `nil` if no text node needed rewriting — or
    /// if it outgrew what `TextNormalizer.outputLimit(for:)` allows it, which
    /// abandons the fragment whole rather than returning half of it.
    static func rewrite(_ html: String, rules: RewriteRules = .builtIn) -> String? {
        attempt(html, rules: rules).value
    }

    /// The same rewrite, saying whether nothing needed changing or the
    /// fragment grew past what it was allowed.
    static func attempt(_ html: String, rules: RewriteRules = .builtIn) -> RewriteAttempt<String> {
        // If nothing anywhere is rewritable, the markup scan is pure
        // overhead. A character reference spells a character the scanner
        // cannot see, so an `&` is enough reason to look.
        guard TextNormalizer.needsRewrite(html, rules: rules)
            || html.utf8.contains(UInt8(ascii: "&"))
        else { return .unchanged }
        // `Shifts` addresses the fragment with `Int32`, which converting to
        // would *trap* rather than fail. `maximumTextBytes` is far inside
        // this; the guard keeps that a fact about the code.
        guard html.utf8.count <= Int(Int32.max) else { return .tooLarge }

        var output = Output(
            limit: TextNormalizer.outputLimit(for: html.utf8.count),
            reserving: TextNormalizer.reservation(for: html.utf8.count) + 32
        )
        var cursor = html.startIndex

        while cursor < html.endIndex, !output.gaveUp {
            guard let markupStart = html[cursor...].firstIndex(of: "<") else {
                append(text: html[cursor...], to: &output, rules: rules)
                break
            }
            append(text: html[cursor..<markupStart], to: &output, rules: rules)
            let markupEnd = endOfMarkup(in: html, startingAt: markupStart)
            output.append(html[markupStart..<markupEnd])
            cursor = markupEnd
        }

        if output.gaveUp { return .tooLarge }
        return output.didRewrite ? .rewritten(output.text) : .unchanged
    }

    /// The fragment being built, and the two things that decide whether it is
    /// worth returning. `gaveUp` is counted across every text node rather than
    /// within one: a document of a million small nodes grows exactly as fast
    /// as one large node, and a per-node ceiling would bound neither.
    private struct Output {
        private(set) var text = String()
        var didRewrite = false
        private(set) var gaveUp = false
        let limit: Int

        init(limit: Int, reserving: Int) {
            self.limit = limit
            text.reserveCapacity(reserving)
        }

        /// The only way in, so nothing reaches the fragment without being
        /// counted. Markup and untouched text used to be appended straight
        /// past the ceiling because only the splices were checked.
        mutating func append<S: StringProtocol>(_ piece: S) {
            guard !gaveUp else { return }
            text += piece
            gaveUp = text.utf8.count > limit
        }

        /// How much more will fit, for a caller building a run of its own.
        var remaining: Int { limit - text.utf8.count }
    }

    /// Where the decoded stream sits relative to the source it came from.
    ///
    /// A reference decodes to fewer bytes than it was written with, so the two
    /// drift apart — but only at a reference. Recording the drift there rather
    /// than a source position for every decoded byte makes this cost one entry
    /// per reference instead of four bytes for every byte of the page, which
    /// is what a single `&amp;` in a large node used to cost. Matches arrive
    /// in order, so reading it is a walk rather than a search.
    private struct Shifts {
        private var drifts: [(decoded: Int32, drift: Int32)] = []
        private var cursor = 0

        mutating func record(decoded: Int, source: Int) {
            drifts.append((Int32(decoded), Int32(source - decoded)))
        }

        /// Positions land on scalar boundaries, never inside a reference, so
        /// the drift in force at one is the whole story.
        mutating func source(of index: Int) -> Int {
            guard !drifts.isEmpty else { return index }
            if cursor >= drifts.count || drifts[cursor].decoded > index {
                cursor = 0
            }
            while cursor + 1 < drifts.count, drifts[cursor + 1].decoded <= index {
                cursor += 1
            }
            return drifts[cursor].decoded <= index ? index + Int(drifts[cursor].drift) : index
        }
    }

    /// Rewrites one text node.
    ///
    /// References are decoded into a scanning stream first, so `&mdash;x`
    /// matches the same rules as a literal em dash followed by `x` —
    /// including substring rules, which a per-reference lookup cannot see.
    /// Matches are spliced back over the source they came from, so anything
    /// untouched keeps the spelling the document used.
    private static func append(text: Substring, to output: inout Output, rules: RewriteRules) {
        guard !text.isEmpty else { return }

        let source = Array(text.utf8)

        // Without a reference in the node there is nothing to decode: the
        // scanning stream *is* the source. That is every text node in most
        // documents, and decoding them would copy the whole page for nothing.
        var decoded: [UInt8] = []
        var shifts = Shifts()
        if source.contains(UInt8(ascii: "&")) {
            decoded.reserveCapacity(TextNormalizer.reservation(for: source.count))

            var index = text.startIndex
            var offset = 0
            while index < text.endIndex {
                let next = text.index(after: index)
                if text[index] == "&", let reference = reference(in: text, startingAt: index),
                   let scalar = Unicode.Scalar(reference.scalar) {
                    let width = text.utf8.distance(from: index, to: reference.end)
                    for byte in String(scalar).utf8 { decoded.append(byte) }
                    offset += width
                    shifts.record(decoded: decoded.count, source: offset)
                    index = reference.end
                    continue
                }
                for byte in text[index..<next].utf8 {
                    decoded.append(byte)
                    offset += 1
                }
                index = next
            }
        }
        let isDecoded = !decoded.isEmpty

        var cursor = 0
        var rewritten: [UInt8] = []
        let room = output.remaining
        (isDecoded ? decoded : source).withUnsafeBufferPointer { buffer in
            TextNormalizer.forEachRewrite(in: buffer, using: rules.table) { range, replacement in
                let from = shifts.source(of: range.lowerBound)
                let to = shifts.source(of: range.upperBound)
                guard from >= cursor else { return true }
                rewritten.append(contentsOf: source[cursor..<from])
                // Escaping comes from the table in force, never the built-in one.
                rewritten.append(contentsOf: rules.table.htmlEscaped(replacement).utf8)
                cursor = to
                return rewritten.count <= room
            }
        }
        guard cursor > 0 else {
            output.append(text)
            return
        }
        rewritten.append(contentsOf: source[cursor...])
        // Bytes rather than a string per run: the runs are spliced at scalar
        // boundaries and every byte is either the input's own UTF-8 or one of
        // the table's outputs, so one decode at the end is enough and there is
        // nothing for a repairing initialiser to hide.
        // swiftlint:disable:next optional_data_string_conversion
        output.append(String(decoding: rewritten, as: UTF8.self))
        output.didRewrite = true
    }

    /// The scalar a character reference stands for, and where it ends.
    /// Numeric references are resolved exactly; named ones come from a list
    /// of the typographic names, which is the only kind worth spelling out
    /// for a table of typography.
    private static func reference(
        in text: Substring,
        startingAt start: Substring.Index
    ) -> (scalar: UInt32, end: Substring.Index)? {
        let after = text.index(after: start)
        guard after < text.endIndex else { return nil }
        // `&` … `;` with nothing absurd in between.
        guard let semicolon = text[after...].prefix(32).firstIndex(of: ";") else { return nil }
        let body = text[after..<semicolon]
        guard !body.isEmpty else { return nil }
        let end = text.index(after: semicolon)

        if body.first == "#" {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, Unicode.Scalar(value) != nil else { return nil }
            return (value, end)
        }
        guard let named = namedReferences[String(body)] else { return nil }
        return (named, end)
    }

    /// Only the typographic names. Anything else either has no rule in the
    /// table or is spelled numerically.
    private static let namedReferences: [String: UInt32] = [
        "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C,
        "rdquo": 0x201D, "bdquo": 0x201E, "laquo": 0x00AB, "raquo": 0x00BB,
        "lsaquo": 0x2039, "rsaquo": 0x203A, "prime": 0x2032, "Prime": 0x2033,
        "ndash": 0x2013, "mdash": 0x2014, "horbar": 0x2015, "minus": 0x2212,
        "hellip": 0x2026, "nbsp": 0x00A0, "ensp": 0x2002, "emsp": 0x2003,
        "thinsp": 0x2009, "bull": 0x2022, "times": 0x00D7, "divide": 0x00F7,
        "ne": 0x2260, "le": 0x2264, "ge": 0x2265, "asymp": 0x2248,
        "larr": 0x2190, "rarr": 0x2192, "harr": 0x2194,
        "lArr": 0x21D0, "rArr": 0x21D2, "hArr": 0x21D4,
    ]

    /// Just past the construct beginning at `start`, a `<`. For `<script>` and
    /// `<style>` that includes the raw body and closing tag.
    private static func endOfMarkup(in html: String, startingAt start: String.Index) -> String.Index {
        let rest = html[start...]

        if rest.hasPrefix("<!--") {
            return end(of: "-->", in: html, from: start) ?? html.endIndex
        }

        guard let tagEnd = endOfTag(in: html, startingAt: start) else { return html.endIndex }

        for element in rawTextElements where rest.hasPrefix("<\(element)", caseInsensitive: true) {
            let body = html[tagEnd...]
            guard let closing = body.range(of: "</\(element)", options: .caseInsensitive) else {
                return html.endIndex
            }
            return endOfTag(in: html, startingAt: closing.lowerBound) ?? html.endIndex
        }

        return tagEnd
    }

    /// Just past the `>` that closes the tag beginning at `start`, skipping
    /// any inside an attribute value. Taking the first `>` in the string ends
    /// the tag early on `<a title="a > b">`, and everything after it is then
    /// rewritten as if it were text — which corrupts the attribute.
    private static func endOfTag(in html: String, startingAt start: String.Index) -> String.Index? {
        // Scalars, not characters. A combining mark, ZWJ, variation selector
        // or tag character right after the `>` joins it into one `Character`,
        // which then equals neither `>` nor anything else — so the tag never
        // appears to end and the rest of the document is swallowed as markup
        // and returned unrewritten. `<p>` before an emoji is enough.
        let scalars = html.unicodeScalars
        var index = scalars.index(after: start)
        var quote: Unicode.Scalar?
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return scalars.index(after: index)
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    /// Just past `terminator`, found by scalar for the same reason as above:
    /// `-->` followed by a combining mark is not the `Character` sequence
    /// `-->`, and a comment that never appears to end eats the document.
    private static func end(
        of terminator: String,
        in html: String,
        from start: String.Index
    ) -> String.Index? {
        let scalars = Array(terminator.unicodeScalars)
        let view = html.unicodeScalars
        var index = start
        while index < view.endIndex {
            var probe = index
            var matched = 0
            while matched < scalars.count, probe < view.endIndex, view[probe] == scalars[matched] {
                matched += 1
                probe = view.index(after: probe)
            }
            if matched == scalars.count { return probe }
            index = view.index(after: index)
        }
        return nil
    }
}

private extension Substring {
    /// Case-insensitive, and the name must end there: `<styles>` is not `<style>`.
    func hasPrefix(_ prefix: String, caseInsensitive: Bool) -> Bool {
        guard caseInsensitive else { return hasPrefix(prefix) }
        guard let match = range(of: prefix, options: [.caseInsensitive, .anchored]) else { return false }
        guard match.upperBound < endIndex else { return true }
        return !self[match.upperBound].isLetter && !self[match.upperBound].isNumber
    }
}
