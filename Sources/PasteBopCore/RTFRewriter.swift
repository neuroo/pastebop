//
//  RTFRewriter.swift
//  PasteBopCore
//
//  One pass over an RTF document. Split from the entry point because its
//  state and every extension that touches it have to share a file: `private`
//  in Swift reaches across extensions only within one.
//

/// One pass over the bytes. Text tokens are decoded into a run, each with a
/// `Segment` remembering the source it stands for; a group boundary, or a
/// token that cannot be decoded, ends the run and the run is scanned.
struct RTFRewriter {

    /// What `{` saves and `}` restores.
    private struct Group {
        /// `\ucN`: fallback characters after each `\uN`. One unless told otherwise.
        var unicodeSkip = 1
        var font = 0
        var codePage = RTFCodePage.windows1252
        /// `\dbch`: the font's bytes come in pairs this does not read.
        var doubleByte = false
    }

    /// A text token: where its decoded bytes sit in the run, and the source
    /// bytes they stand for.
    ///
    /// There is one per text token, and an escape-heavy document has one per
    /// character, so their width is what decides how much a large paste costs
    /// to take apart. Stored narrow and read wide: every offset is inside the
    /// document, and `maximumTextBytes` is far inside what `Int32` holds.
    private struct Segment {
        private let start: Int32
        private let length: Int32
        private let origin: Int32
        private let span: Int32
        /// Plain bytes map one to one; an escape stands for its whole span.
        let isPlain: Bool
        /// The token follows a control word no space delimits, so anything
        /// spliced in front of it needs one or it extends the word.
        let followsControlWord: Bool

        init(
            decodedStart: Int,
            decodedLength: Int,
            sourceStart: Int,
            sourceLength: Int,
            isPlain: Bool,
            followsControlWord: Bool
        ) {
            self.start = Int32(decodedStart)
            self.length = Int32(decodedLength)
            self.origin = Int32(sourceStart)
            self.span = Int32(sourceLength)
            self.isPlain = isPlain
            self.followsControlWord = followsControlWord
        }

        var decodedStart: Int { Int(start) }
        var decodedLength: Int { Int(length) }
        var sourceStart: Int { Int(origin) }
        var sourceLength: Int { Int(span) }
        var decodedEnd: Int { decodedStart + decodedLength }
        var sourceEnd: Int { sourceStart + sourceLength }
    }

    /// Deeper than any real document. Past this the input is treated as
    /// unbalanced and left alone.
    private static let maximumDepth = 4096

    private let source: UnsafeBufferPointer<UInt8>
    private let table: ScalarTable

    private var index = 0
    private var output: [UInt8] = []
    /// Source before here is in `output`, or will be copied in one piece if
    /// nothing ever needs rewriting.
    private var copiedUpTo = 0
    private var didRewrite = false
    private var gaveUp = false
    /// Told apart from the other reasons to give up: an unbalanced document
    /// is left alone, but one that outgrew its room has to take the rest of
    /// the item with it or the flavours disagree.
    private(set) var ranOutOfRoom = false
    private let limit: Int

    private var decoded: [UInt8] = []
    private var segments: [Segment] = []
    private var runHasNonASCII = false
    /// Just past the last control word that ended without a space.
    private var controlWordEnd = -1

    private var group = Group()
    private var stack: [Group] = []
    private var documentCodePage = RTFCodePage.windows1252
    private var fonts: [Int: RTFSyntax.Font] = [:]

    init(source: UnsafeBufferPointer<UInt8>, table: ScalarTable, limit: Int) {
        self.source = source
        self.table = table
        self.limit = limit
    }

    mutating func run() -> [UInt8]? {
        while index < source.count, !gaveUp {
            switch source[index] {
            case RTFSyntax.backslash: control()
            case RTFSyntax.openBrace: openGroup()
            case RTFSyntax.closeBrace: closeGroup()
            default: text()
            }
        }
        flushRun()
        guard didRewrite, !gaveUp else { return nil }
        // The document past the last match is copied in one go, and it is as
        // unbounded as anything spliced before it: checking only the splices
        // let a large untouched tail carry the result over the ceiling.
        guard output.count + (source.count - copiedUpTo) <= limit else {
            ranOutOfRoom = true
            return nil
        }
        output.append(contentsOf: UnsafeBufferPointer(rebasing: source[copiedUpTo...]))
        return output
    }

    // MARK: - Tokens

    /// Plain bytes up to the next construct. Line breaks are not text in RTF,
    /// and a byte outside ASCII is not something this knows how to read.
    private mutating func text() {
        let start = index
        var end = index
        while end < source.count {
            let byte = source[end]
            if byte == RTFSyntax.backslash || byte == RTFSyntax.openBrace || byte == RTFSyntax.closeBrace
                || byte == 0x0D || byte == 0x0A || byte >= 0x80 { break }
            end += 1
        }
        if end > start {
            appendPlain(from: start, to: end)
            index = end
        } else if source[end] < 0x80 {
            // CR or LF: a gap the run continues across.
            index = end + 1
        } else {
            flushRun()
            while index < source.count, source[index] >= 0x80 { index += 1 }
        }
    }

    private mutating func openGroup() {
        flushRun()
        let start = index
        if let destination = RTFSyntax.destination(in: source, ofGroupAt: start) {
            let end = RTFSyntax.endOfGroup(in: source, from: start)
            if destination == .fontTable {
                fonts.merge(RTFSyntax.fonts(in: source, tableFrom: start, to: end)) { _, new in new }
                refreshCodePage()
            }
            index = end
            return
        }
        guard stack.count < Self.maximumDepth else { gaveUp = true; return }
        stack.append(group)
        index = start + 1
    }

    private mutating func closeGroup() {
        flushRun()
        if let saved = stack.popLast() { group = saved }
        index += 1
    }

    private mutating func control() {
        let start = index
        guard start + 1 < source.count else { index = source.count; return }
        let next = source[start + 1]
        if RTFSyntax.isLetter(next) {
            controlWord(RTFSyntax.controlWord(in: source, at: start), from: start)
        } else {
            controlSymbol(next, from: start)
        }
    }

    private mutating func controlWord(_ word: RTFSyntax.ControlWord, from start: Int) {
        let isUnicode = word.nameLength == 1 && source[word.nameStart] == UInt8(ascii: "u")
        if let scalar = RTFSyntax.namedCharacter(source, word) {
            appendScalar(scalar, from: start, to: word.end)
        } else if isUnicode, let parameter = word.parameter {
            unicodeEscape(parameter, from: start, word: word)
            return
        } else {
            index = word.end
            // A paragraph or row boundary is not formatting: the text either
            // side of it is not contiguous, and a substring rule matching
            // across one joins words that were never adjacent — replacing
            // both and deleting whatever followed the break.
            //
            // `\uc` ends a run too. A replacement spliced into the run is
            // written with the skip count in force when the run is flushed,
            // so a `\uc` later in the run would put the wrong number of
            // fallback characters after `\uN` and the surplus would be read
            // as literal text.
            if isSeparator(word) || named(word, "uc") { flushRun() }
            formatting(word)
        }
        controlWordEnd = word.spaceDelimited ? -1 : word.end
    }

    /// Control words that end a run of contiguous text. `\tab` is absent on
    /// purpose: it stands for a tab character, so the text does continue
    /// across it.
    private func isSeparator(_ word: RTFSyntax.ControlWord) -> Bool {
        named(word, "par") || named(word, "line") || named(word, "sect")
            || named(word, "page") || named(word, "column") || named(word, "cell")
            || named(word, "row") || named(word, "nestcell") || named(word, "nestrow")
            || named(word, "lbr")
    }

    /// The control words that change how later bytes are read. Everything
    /// else is formatting, which the run continues across.
    private mutating func formatting(_ word: RTFSyntax.ControlWord) {
        let parameter = word.parameter
        switch source[word.nameStart] {
        case UInt8(ascii: "u") where named(word, "uc"):
            group.unicodeSkip = min(max(parameter ?? 1, 0), 8)
        case UInt8(ascii: "f") where word.nameLength == 1, UInt8(ascii: "d") where named(word, "deff"):
            group.font = parameter ?? 0
            refreshCodePage()
        case UInt8(ascii: "d") where named(word, "dbch"):
            group.doubleByte = true
        case UInt8(ascii: "l") where named(word, "loch"), UInt8(ascii: "h") where named(word, "hich"):
            group.doubleByte = false
        case UInt8(ascii: "b") where named(word, "bin"):
            // Raw bytes follow; they are nobody's text.
            index = min(source.count, index + max(0, parameter ?? 0))
        default:
            documentCodePage(word)
        }
    }

    private mutating func documentCodePage(_ word: RTFSyntax.ControlWord) {
        if named(word, "ansicpg") {
            documentCodePage = RTFCodePage(windows: word.parameter ?? 1252)
        } else if named(word, "mac") {
            documentCodePage = .macRoman
        } else if named(word, "pc") || named(word, "pca") {
            documentCodePage = .unknown
        } else {
            return
        }
        refreshCodePage()
    }

    private mutating func refreshCodePage() {
        group.codePage = RTFCodePage(font: fonts[group.font], document: documentCodePage)
    }

    private func named(_ word: RTFSyntax.ControlWord, _ name: StaticString) -> Bool {
        RTFSyntax.word(source, word.nameStart, word.nameLength, is: name)
    }

    private mutating func controlSymbol(_ symbol: UInt8, from start: Int) {
        switch symbol {
        case UInt8(ascii: "'"):
            hexEscape(from: start)
        case UInt8(ascii: "~"):
            appendScalar(0x00A0, from: start, to: start + 2)
        case UInt8(ascii: "_"):
            appendScalar(0x2011, from: start, to: start + 2)
        case UInt8(ascii: "-"):
            appendScalar(0x00AD, from: start, to: start + 2)
        case RTFSyntax.backslash, RTFSyntax.openBrace, RTFSyntax.closeBrace:
            appendLiteral(symbol, from: start)
        default:
            // `\*`, `\|`, `\:`, a backslash before a line break: formatting.
            index = start + 2
        }
    }

    /// `\'hh`: a byte in the current font's code page.
    private mutating func hexEscape(from start: Int) {
        guard start + 3 < source.count,
              let high = RTFSyntax.hexValue(source[start + 2]),
              let low = RTFSyntax.hexValue(source[start + 3]) else {
            flushRun()
            index = start + 2
            return
        }
        if !group.doubleByte, let scalar = group.codePage.scalar(for: high << 4 | low) {
            appendScalar(scalar, from: start, to: start + 4)
        } else {
            // A byte this cannot read ends the text being scanned around it.
            flushRun()
            index = start + 4
        }
    }

    // MARK: - Splicing

    /// Scans the run collected so far and splices its rewrites into the output.
    private mutating func flushRun() {
        defer {
            decoded.removeAll(keepingCapacity: true)
            segments.removeAll(keepingCapacity: true)
            runHasNonASCII = false
        }
        // Nothing fires on ASCII alone unless a substring rule starts there.
        guard runHasNonASCII || (table.hasASCIISequenceStarts && !decoded.isEmpty) else { return }
        var run: [UInt8] = []
        swap(&run, &decoded)
        var cursor = 0
        run.withUnsafeBufferPointer { buffer in
            TextNormalizer.forEachRewrite(in: buffer, using: table) { range, replacement in
                splice(range, with: replacement, segmentCursor: &cursor)
                return !gaveUp
            }
        }
        swap(&run, &decoded)
    }

    /// Replaces the source behind one match. The match may span formatting
    /// words, which are kept after the replacement: that gives the replacement
    /// the style of the first character it replaces, as the attributed-string
    /// path does.
    private mutating func splice(_ range: Range<Int>, with replacement: String, segmentCursor: inout Int) {
        while segmentCursor < segments.count, segments[segmentCursor].decodedEnd <= range.lowerBound {
            segmentCursor += 1
        }
        guard segmentCursor < segments.count else { return }
        var lastIndex = segmentCursor
        while lastIndex + 1 < segments.count, segments[lastIndex].decodedEnd < range.upperBound {
            lastIndex += 1
        }
        let first = segments[segmentCursor]
        let last = segments[lastIndex]
        let sourceStart = first.isPlain
            ? first.sourceStart + (range.lowerBound - first.decodedStart)
            : first.sourceStart
        let sourceEnd = last.isPlain
            ? last.sourceStart + (range.upperBound - last.decodedStart)
            : last.sourceEnd
        guard sourceStart >= copiedUpTo else { return }

        output.append(contentsOf: UnsafeBufferPointer(rebasing: source[copiedUpTo..<sourceStart]))
        if first.followsControlWord, range.lowerBound == first.decodedStart, copiedUpTo < sourceStart {
            output.append(RTFSyntax.space)
        }
        appendReplacement(replacement)
        appendFormatting(between: segmentCursor, and: lastIndex)
        copiedUpTo = sourceEnd
        didRewrite = true
        // A replacement can be far longer than the source behind it, and an
        // escape-heavy document has many matches per kilobyte. Checked here
        // so the document is abandoned whole: a half-spliced one would be
        // worse than the one that came in.
        if output.count > limit {
            gaveUp = true
            ranOutOfRoom = true
        }
    }

    /// The control words that sat between the text tokens of a match.
    private mutating func appendFormatting(between first: Int, and last: Int) {
        guard last > first else { return }
        for position in (first + 1)...last {
            let gapStart = segments[position - 1].sourceEnd
            let gapEnd = segments[position].sourceStart
            guard gapEnd > gapStart else { continue }
            output.append(contentsOf: UnsafeBufferPointer(rebasing: source[gapStart..<gapEnd]))
            if segments[position].followsControlWord { output.append(RTFSyntax.space) }
        }
    }
}

// MARK: - Unicode escapes

extension RTFRewriter {

    /// `\uN`: a UTF-16 unit, then `\uc` fallback characters to skip. A
    /// surrogate pair arrives as two of them.
    private mutating func unicodeEscape(_ parameter: Int, from start: Int, word: RTFSyntax.ControlWord) {
        var value = parameter < 0 ? parameter + 0x10000 : parameter
        var end = skipFallback(from: word.end)
        if value >= 0xD800, value <= 0xDBFF, let low = lowSurrogate(at: end) {
            value = 0x10000 + ((value - 0xD800) << 10) + (low.value - 0xDC00)
            end = low.end
        } else if value < 0 || value > 0xFFFF || (value >= 0xD800 && value <= 0xDFFF) {
            value = 0xFFFD
        }
        appendScalar(UInt32(value), from: start, to: end)
        // Fallback text, like a space, delimits the word.
        controlWordEnd = end == word.end && !word.spaceDelimited ? end : -1
    }

    /// Past the `\uc` fallback characters after a `\uN`: plain bytes or
    /// `\'hh` escapes. Anything else ends the fallback early.
    private func skipFallback(from position: Int) -> Int {
        var cursor = position
        var remaining = group.unicodeSkip
        while remaining > 0, cursor < source.count {
            let byte = source[cursor]
            if byte == RTFSyntax.backslash {
                guard cursor + 3 < source.count, source[cursor + 1] == UInt8(ascii: "'") else { break }
                cursor += 4
            } else if byte == RTFSyntax.openBrace || byte == RTFSyntax.closeBrace {
                break
            } else {
                cursor += 1
            }
            remaining -= 1
        }
        return cursor
    }

    /// A `\uN` low surrogate at `position`, with the index past its fallback.
    private func lowSurrogate(at position: Int) -> (value: Int, end: Int)? {
        guard position + 2 < source.count,
              source[position] == RTFSyntax.backslash,
              source[position + 1] == UInt8(ascii: "u"),
              !RTFSyntax.isLetter(source[position + 2]) else { return nil }
        let word = RTFSyntax.controlWord(in: source, at: position)
        guard let parameter = word.parameter else { return nil }
        let value = parameter < 0 ? parameter + 0x10000 : parameter
        guard value >= 0xDC00, value <= 0xDFFF else { return nil }
        return (value, skipFallback(from: word.end))
    }
}

// MARK: - The run

extension RTFRewriter {

    private mutating func appendPlain(from start: Int, to end: Int) {
        decoded.append(contentsOf: UnsafeBufferPointer(rebasing: source[start..<end]))
        addSegment(decodedLength: end - start, source: start..<end, isPlain: true)
    }

    /// `\{`, `\}` or `\\`: one literal byte.
    private mutating func appendLiteral(_ byte: UInt8, from start: Int) {
        decoded.append(byte)
        addSegment(decodedLength: 1, source: start..<(start + 2), isPlain: false)
        index = start + 2
    }

    private mutating func appendScalar(_ value: UInt32, from start: Int, to end: Int) {
        let decodedStart = decoded.count
        appendUTF8(value)
        addSegment(decodedLength: decoded.count - decodedStart, source: start..<end, isPlain: false)
        if value >= 0x80 { runHasNonASCII = true }
        index = end
    }

    /// Records the token whose decoded bytes were just appended.
    private mutating func addSegment(decodedLength: Int, source: Range<Int>, isPlain: Bool) {
        segments.append(Segment(
            decodedStart: decoded.count - decodedLength,
            decodedLength: decodedLength,
            sourceStart: source.lowerBound,
            sourceLength: source.count,
            isPlain: isPlain,
            followsControlWord: source.lowerBound == controlWordEnd
        ))
    }

    private mutating func appendUTF8(_ value: UInt32) {
        switch value {
        case ..<0x80:
            decoded.append(UInt8(value))
        case ..<0x800:
            decoded.append(UInt8(0xC0 | value >> 6))
            decoded.append(UInt8(0x80 | value & 0x3F))
        case ..<0x10000:
            decoded.append(UInt8(0xE0 | value >> 12))
            decoded.append(UInt8(0x80 | value >> 6 & 0x3F))
            decoded.append(UInt8(0x80 | value & 0x3F))
        default:
            decoded.append(UInt8(0xF0 | value >> 18))
            decoded.append(UInt8(0x80 | value >> 12 & 0x3F))
            decoded.append(UInt8(0x80 | value >> 6 & 0x3F))
            decoded.append(UInt8(0x80 | value & 0x3F))
        }
    }
}

// MARK: - Output

extension RTFRewriter {

    private mutating func appendReplacement(_ replacement: String) {
        for scalar in replacement.unicodeScalars {
            switch scalar.value {
            case 0x5C, 0x7B, 0x7D:
                output.append(RTFSyntax.backslash)
                output.append(UInt8(scalar.value))
            case 0x0A:
                output.append(contentsOf: "\\line ".utf8)
            case 0x09:
                output.append(contentsOf: "\\tab ".utf8)
            case 0x0D:
                break
            case ..<0x80:
                output.append(UInt8(scalar.value))
            default:
                appendUnicodeEscape(scalar)
            }
        }
    }

    /// `\uN` per UTF-16 unit, each followed by the fallback characters the
    /// current `\uc` promises readers they may skip.
    private mutating func appendUnicodeEscape(_ scalar: Unicode.Scalar) {
        for unit in scalar.utf16 {
            let signed = unit > 0x7FFF ? Int(unit) - 0x10000 : Int(unit)
            output.append(contentsOf: "\\u\(signed)".utf8)
            if group.unicodeSkip == 0 {
                output.append(RTFSyntax.space)
            } else {
                output.append(contentsOf: repeatElement(UInt8(ascii: "?"), count: group.unicodeSkip))
            }
        }
    }
}
