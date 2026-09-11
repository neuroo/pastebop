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

    /// The rewritten fragment, or `nil` if no text node needed rewriting.
    static func rewrite(_ html: String, rules: RewriteRules = .builtIn) -> String? {
        // If nothing anywhere is rewritable, the markup scan is pure overhead.
        guard TextNormalizer.needsRewrite(html, rules: rules) else { return nil }

        var output = String()
        output.reserveCapacity(html.utf8.count + 32)
        var didRewrite = false
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard let markupStart = html[cursor...].firstIndex(of: "<") else {
                append(text: html[cursor...], to: &output, didRewrite: &didRewrite, rules: rules)
                break
            }
            append(text: html[cursor..<markupStart], to: &output, didRewrite: &didRewrite, rules: rules)
            let markupEnd = endOfMarkup(in: html, startingAt: markupStart)
            output += html[markupStart..<markupEnd]
            cursor = markupEnd
        }

        return didRewrite ? output : nil
    }

    private static func append(
        text: Substring,
        to output: inout String,
        didRewrite: inout Bool,
        rules: RewriteRules
    ) {
        guard !text.isEmpty else { return }
        if let rewritten = TextNormalizer.normalize(String(text), rules: rules, escaping: .html) {
            output += rewritten
            didRewrite = true
        } else {
            output += text
        }
    }

    /// Just past the construct beginning at `start`, a `<`. For `<script>` and
    /// `<style>` that includes the raw body and closing tag.
    private static func endOfMarkup(in html: String, startingAt start: String.Index) -> String.Index {
        let rest = html[start...]

        if rest.hasPrefix("<!--") {
            return rest.range(of: "-->").map(\.upperBound) ?? html.endIndex
        }

        guard let tagEnd = rest.range(of: ">").map(\.upperBound) else { return html.endIndex }

        for element in rawTextElements where rest.hasPrefix("<\(element)", caseInsensitive: true) {
            let body = html[tagEnd...]
            guard let closing = body.range(of: "</\(element)", options: .caseInsensitive) else {
                return html.endIndex
            }
            return html[closing.upperBound...].range(of: ">").map(\.upperBound) ?? html.endIndex
        }

        return tagEnd
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
