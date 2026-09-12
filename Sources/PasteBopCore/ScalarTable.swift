//
//  ScalarTable.swift
//  PasteBopCore
//

/// O(1) lookup from a scalar to its replacement, plus substring rules indexed
/// by first scalar.
///
/// Latin-1 and General Punctuation, which hold most of the rules, are dense
/// arrays; everything else goes through a page bitmap and then a dictionary.
/// A value rather than static properties, because each `static let` costs a
/// `swift_once` check per read and the scanner reads several per character.
struct ScalarTable: Sendable {

    /// No single-scalar rule fires below this, which is what lets the scanner
    /// skip ASCII on one compare.
    static let floor: UInt32 = 0x00A0

    struct Sequence: Sendable {
        let scalars: [UInt32]
        let output: String
    }

    private static let latin1Range: ClosedRange<UInt32> = 0x00A0...0x00FF
    private static let punctuationRange: ClosedRange<UInt32> = 0x2000...0x206F

    /// Ranges wider than this stay ranges instead of becoming dictionary
    /// entries, so a rules file cannot ask for a million of them.
    private static let maximumExpandedRange = 512

    private let latin1: [String?]
    private let punctuation: [String?]
    /// One flag per 256-scalar page, so CJK, Cyrillic and emoji are rejected
    /// without hashing into the dictionary.
    private let longTailPages: [Bool]
    private let longTail: [UInt32: String]
    private let wideRanges: [(range: ClosedRange<UInt32>, output: String)]

    /// Flat, so a hit can name a rule by index and stay a plain value.
    private let allSequences: [Sequence]
    /// Indices into `allSequences` by first scalar, longest first.
    private let sequencesByFirst: [UInt32: [Int]]
    let hasSequences: Bool
    /// The most scalars substring matching can compare at one character.
    ///
    /// Every candidate sharing a first scalar is tried, and each is compared
    /// until it fails, so what costs is the *total length* of the largest
    /// such group — not how many rules there are. Two thousand rules spread
    /// across two thousand first scalars are free; two thousand sharing one
    /// long prefix are not, and counting rules alone reads them the same.
    let worstSequenceScan: Int
    /// The most bytes any one rule can put out for a single match. A rule may
    /// output far more than it matched, so this is how much bigger a rewrite
    /// can get than the text it was handed.
    let widestOutput: Int
    /// The one case where ASCII bytes cannot be skipped blind.
    let hasASCIISequenceStarts: Bool
    private let asciiStarts: [Bool]
    /// Built from this table's own rules, never the built-in ones, so a user
    /// rule that outputs markup is escaped like any other.
    private let htmlEscapedOutputs: [String: String]

    init(_ replacements: [Replacement]) {
        var latin1 = [String?](repeating: nil, count: Self.latin1Range.count)
        var punctuation = [String?](repeating: nil, count: Self.punctuationRange.count)
        var longTail: [UInt32: String] = [:]
        var wideRanges: [(ClosedRange<UInt32>, String)] = []
        var pages = [Bool](repeating: false, count: Int(0x10FFFF >> 8) + 1)
        var allSequences: [Sequence] = []
        var sequencesByFirst: [UInt32: [Int]] = [:]
        var asciiStarts = [Bool](repeating: false, count: 0x80)
        var anyASCIIStart = false

        // Ranges first, then single scalars over the top. `rule(for:)` asks
        // byScalar before ranged, so a table that let a later range overwrite
        // a single-scalar rule would rewrite one thing and describe another.
        let ordered = replacements.filter { $0.isRange } + replacements.filter { !$0.isRange }
        for rule in ordered {
            switch rule.pattern {
            case .sequence(let scalars):
                guard let first = scalars.first, scalars.count > 1 else { continue }
                sequencesByFirst[first, default: []].append(allSequences.count)
                allSequences.append(Sequence(scalars: scalars, output: rule.output))
                if first < 0x80 {
                    asciiStarts[Int(first)] = true
                    anyASCIIStart = true
                }

            case .scalars(let range):
                if range.count > Self.maximumExpandedRange {
                    wideRanges.append((range, rule.output))
                    for page in (range.lowerBound >> 8)...(range.upperBound >> 8) {
                        pages[Int(page)] = true
                    }
                    continue
                }
                for value in range {
                    if Self.latin1Range.contains(value) {
                        latin1[Int(value - Self.latin1Range.lowerBound)] = rule.output
                    } else if Self.punctuationRange.contains(value) {
                        punctuation[Int(value - Self.punctuationRange.lowerBound)] = rule.output
                    } else {
                        longTail[value] = rule.output
                        pages[Int(value >> 8)] = true
                    }
                }
            }
        }

        Self.fillDenseBlocks(from: wideRanges, latin1: &latin1, punctuation: &punctuation)

        Self.orderLongestFirst(&sequencesByFirst, in: allSequences)
        self.worstSequenceScan = Self.worstScan(of: sequencesByFirst, in: allSequences)
        self.widestOutput = replacements.reduce(0) { max($0, $1.output.utf8.count) }
        self.latin1 = latin1
        self.punctuation = punctuation
        self.longTail = longTail
        self.wideRanges = wideRanges
        self.longTailPages = pages
        self.allSequences = allSequences
        self.sequencesByFirst = sequencesByFirst
        self.hasSequences = !allSequences.isEmpty
        self.hasASCIISequenceStarts = anyASCIIStart
        self.asciiStarts = asciiStarts
        self.htmlEscapedOutputs = Self.htmlEscapes(for: replacements)
    }

    private static func htmlEscapes(for replacements: [Replacement]) -> [String: String] {
        var escaped: [String: String] = [:]
        for rule in replacements
        where rule.output.contains(where: { $0 == "<" || $0 == ">" || $0 == "&" }) {
            escaped[rule.output] = rule.output
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return escaped
    }

    /// Longest first, so a substring always beats a shorter one starting at
    /// the same scalar.
    private static func orderLongestFirst(
        _ byFirst: inout [UInt32: [Int]],
        in sequences: [Sequence]
    ) {
        for first in byFirst.keys {
            byFirst[first]?.sort { sequences[$0].scalars.count > sequences[$1].scalars.count }
        }
    }

    /// The most scalars one character can cost: every candidate sharing it is
    /// tried, and each is compared until it fails.
    private static func worstScan(of byFirst: [UInt32: [Int]], in sequences: [Sequence]) -> Int {
        byFirst.values.reduce(0) { worst, indices in
            max(worst, indices.reduce(0) { $0 + sequences[$1].scalars.count })
        }
    }

    /// A wide range is only consulted in the long tail, but the dense arrays
    /// are read first and answer with whatever is in the slot — so a range
    /// covering Latin-1 or the punctuation block would silently rewrite the
    /// characters past them and miss the ones inside. Single-scalar rules are
    /// left in place: the more specific rule wins, here and in
    /// `RewriteRules.rule(for:)`.
    private static func fillDenseBlocks(
        from wideRanges: [(ClosedRange<UInt32>, String)],
        latin1: inout [String?],
        punctuation: inout [String?]
    ) {
        for (range, output) in wideRanges {
            if range.overlaps(latin1Range) {
                for value in range.clamped(to: latin1Range) {
                    let slot = Int(value - latin1Range.lowerBound)
                    if latin1[slot] == nil { latin1[slot] = output }
                }
            }
            if range.overlaps(punctuationRange) {
                for value in range.clamped(to: punctuationRange) {
                    let slot = Int(value - punctuationRange.lowerBound)
                    if punctuation[slot] == nil { punctuation[slot] = output }
                }
            }
        }
    }

    @inline(__always)
    func htmlEscaped(_ output: String) -> String {
        htmlEscapedOutputs.isEmpty ? output : (htmlEscapedOutputs[output] ?? output)
    }

    /// `nil` passes through unchanged; an empty string deletes. Replacements
    /// are short enough to be small strings, so returning one allocates nothing.
    @inline(__always)
    func replacement(forValue value: UInt32) -> String? {
        if value < Self.floor { return nil }
        if value <= Self.latin1Range.upperBound {
            return latin1[Int(value - Self.latin1Range.lowerBound)]
        }
        if value >= Self.punctuationRange.lowerBound, value <= Self.punctuationRange.upperBound {
            return punctuation[Int(value - Self.punctuationRange.lowerBound)]
        }
        guard longTailPages[Int(value >> 8)] else { return nil }
        if let output = longTail[value] { return output }
        for wide in wideRanges where wide.range.contains(value) { return wide.output }
        return nil
    }

    @inline(__always)
    func replacement(for scalar: Unicode.Scalar) -> String? {
        replacement(forValue: scalar.value)
    }

    /// Longest first.
    @inline(__always)
    func sequenceIndices(startingWith value: UInt32) -> [Int]? {
        sequencesByFirst[value]
    }

    @inline(__always)
    func sequence(at index: Int) -> Sequence {
        allSequences[index]
    }

    @inline(__always)
    func asciiCanStartSequence(_ byte: UInt8) -> Bool {
        asciiStarts[Int(byte)]
    }
}
