//
//  RTFTextRewriter.swift
//  PasteBopCore
//

import Foundation

/// Rewrites the text of an RTF document, leaving everything else byte-identical.
///
/// RTF is 7-bit, so the characters PasteBop rewrites arrive encoded: `\'93`
/// is a byte in the document's code page, `\uN` a UTF-16 unit followed by
/// fallback text to skip, `\emdash` a name. Decoding the whole document
/// through AppKit to reach them costs a hundred times more than the scan, and
/// re-encodes formatting AppKit does not model. So this walks the bytes: the
/// text of each group is decoded to UTF-8, scanned with the same scanner as
/// plain text, and the matches spliced back over the tokens they came from.
/// Control words stay where they were, and destinations that are not document
/// text -- the font table, pictures, field instructions, anything under `\*`
/// -- are copied as they are.
///
/// Conservative by construction: a token this cannot decode, such as a byte
/// in an unknown code page or a double-byte font run, ends the text being
/// scanned and is copied as is. The worst case is a character left alone,
/// never one corrupted.
enum RTFTextRewriter {

    /// The rewritten document, or `nil` if no text needed rewriting — or if it
    /// outgrew what `TextNormalizer.outputLimit(for:)` allows it, which
    /// abandons the document whole rather than returning half of it.
    static func rewrite(_ rtf: Data, rules: RewriteRules = .builtIn) -> Data? {
        attempt(rtf, rules: rules).value
    }

    /// The same rewrite, saying whether nothing needed changing or the
    /// document grew past what it was allowed.
    static func attempt(_ rtf: Data, rules: RewriteRules = .builtIn) -> RewriteAttempt<Data> {
        // `Segment` addresses the document with `Int32`, which converting to
        // would *trap* rather than fail. `maximumTextBytes` is three orders of
        // magnitude inside this, so it is here to keep that a fact about the
        // code rather than one about a constant somewhere else.
        guard !rtf.isEmpty else { return .unchanged }
        guard rtf.count <= Int(Int32.max) else { return .tooLarge }
        return rtf.withUnsafeBytes { raw -> RewriteAttempt<Data> in
            var rewriter = RTFRewriter(
                source: raw.bindMemory(to: UInt8.self),
                table: rules.table,
                limit: TextNormalizer.outputLimit(for: rtf.count)
            )
            guard let rewritten = rewriter.run() else {
                return rewriter.ranOutOfRoom ? .tooLarge : .unchanged
            }
            return .rewritten(Data(rewritten))
        }
    }
}
