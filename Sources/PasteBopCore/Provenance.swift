//
//  Provenance.swift
//  PasteBopCore
//

/// A guess at where a piece of text came from, made from the rules that fired
/// on it and nothing else.
///
/// PasteBop already counts every em dash, curly quote and ellipsis it rewrites,
/// which is most of a fingerprint for text that came out of a chat assistant.
/// No text is examined, stored or sent: this reads a handful of integers that
/// were counted anyway.
///
/// It is a heuristic and says so. Typographic polish is what it actually
/// measures, and a word processor produces plenty of that on its own, so the
/// discriminator is *variety* rather than volume: smart quotes alone are
/// Pages or Word, while quotes together with em dashes and ellipses are the
/// house style of a language model.
public struct Provenance: Sendable, Equatable {

    public enum Reading: Sendable, Equatable {
        /// Too little text to say anything honest.
        case inconclusive
        /// Typographic polish of the kind a word processor adds.
        case polished
        /// Dense and varied enough to read as machine-written.
        case machineWritten
    }

    /// Families of marker, counted separately because using several at once
    /// is the signal. One family used heavily is just autocorrect.
    enum Marker: CaseIterable {
        case emDash
        case curlyQuotes
        case ellipsis
        case exoticSpace

        var scalars: [UInt32] {
            switch self {
            case .emDash: [0x2014, 0x2013]
            case .curlyQuotes: [0x2018, 0x2019, 0x201C, 0x201D]
            case .ellipsis: [0x2026]
            case .exoticSpace: [0x00A0, 0x202F, 0x2009]
            }
        }

        var label: String {
            switch self {
            case .emDash: "em dashes"
            case .curlyQuotes: "curly quotes"
            case .ellipsis: "ellipses"
            case .exoticSpace: "non-breaking spaces"
            }
        }
    }

    /// Below this there is not enough text for a density to mean anything.
    static let minimumCharacters = 240
    /// Markers per thousand characters before volume counts as a signal.
    static let densityThreshold = 1.5
    /// Distinct families needed to separate a language model from autocorrect.
    static let varietyThreshold = 2

    public let reading: Reading
    /// Markers per thousand characters.
    public let density: Double
    /// Which families appeared, commonest first.
    public let signals: [String]

    public var isMachineWritten: Bool { reading == .machineWritten }

    /// Reads the fingerprint out of a tally and the length of the text it came from.
    public init(tally: RewriteTally, characterCount: Int) {
        var present: [(marker: Marker, count: Int)] = []
        var total = 0
        for marker in Marker.allCases {
            let count = marker.scalars.reduce(0) { sum, scalar in
                sum + (tally.counts[Pattern.scalars(scalar...scalar).key] ?? 0)
            }
            guard count > 0 else { continue }
            present.append((marker, count))
            total += count
        }

        density = characterCount > 0 ? Double(total) * 1000 / Double(characterCount) : 0
        signals = present.sorted { $0.count > $1.count }.map(\.marker.label)

        if characterCount < Self.minimumCharacters || present.isEmpty {
            reading = .inconclusive
        } else if present.count >= Self.varietyThreshold, density >= Self.densityThreshold {
            reading = .machineWritten
        } else {
            reading = .polished
        }
    }

    /// The line shown under a copy, or `nil` when there is nothing to claim.
    public var summary: String? {
        switch reading {
        case .inconclusive:
            nil
        case .polished:
            "Reads word-processed (\(signals.prefix(2).joined(separator: ", ")))"
        case .machineWritten:
            "Reads machine-written (\(signals.prefix(3).joined(separator: ", ")))"
        }
    }
}
