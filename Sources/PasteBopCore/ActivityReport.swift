//
//  ActivityReport.swift
//  PasteBopCore
//

import Foundation

/// The wording for what PasteBop has been doing. Out of the view so the
/// pluralisation and empty cases can be tested without building a menu.
public struct ActivityReport: Sendable {

    public let isEnabled: Bool
    public let copyCount: Int
    public let tally: RewriteTally
    public let rules: RewriteRules
    public let locale: Locale
    /// What the most recent copy read as, if anything was copied this launch.
    public let lastProvenance: Provenance?
    /// How many rewritten copies read as machine-written, over the lifetime.
    public let machineWrittenCopies: Int

    public init(
        isEnabled: Bool,
        copyCount: Int,
        tally: RewriteTally,
        rules: RewriteRules = .builtIn,
        locale: Locale = .autoupdatingCurrent,
        lastProvenance: Provenance? = nil,
        machineWrittenCopies: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.copyCount = copyCount
        self.tally = tally
        self.rules = rules
        self.locale = locale
        self.lastProvenance = lastProvenance
        self.machineWrittenCopies = machineWrittenCopies
    }

    public var characterCount: Int { tally.characterCount }

    public var hasStatistics: Bool { characterCount > 0 }

    /// Under the enable switch.
    public var activityLine: String {
        guard isEnabled else { return "Paused" }
        guard hasStatistics else { return "Watching the clipboard" }
        return "Cleaned \(summaryLine)"
    }

    /// "Mostly quotes and apostrophes (62%)", or nil when nothing is counted.
    public var dominantFamilyLine: String? {
        guard characterCount > 0,
              let leader = tally.familyTotals(rules: rules).first
        else { return nil }
        let share = Double(leader.count) / Double(characterCount)
        let percent = share.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return "Mostly \(leader.category.rawValue.lowercased()) (\(percent))"
    }

    /// `9 × Right single quotation mark ’`, commonest first.
    public func offenderLines(limit: Int = 6) -> [String] {
        tally.topOffenders(limit: limit, rules: rules).map { offender in
            let name = offender.glyph.map { "\(offender.name) \($0)" } ?? offender.name
            return "\(offender.count.formatted(.number.locale(locale))) \u{d7} \(name)"
        }
    }

    /// What the last copy read as: "Reads machine-written (em dashes, curly
    /// quotes)". Nil when there was too little text to say anything.
    public var lastCopyLine: String? {
        lastProvenance?.summary
    }

    /// "63% of what you pasted read as machine-written", once there are
    /// enough copies for a share to mean anything.
    public var machineShareLine: String? {
        guard copyCount >= Self.minimumCopiesForShare else { return nil }
        let share = Double(machineWrittenCopies) / Double(copyCount)
        let percent = share.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return "\(percent) of it read as machine-written"
    }

    /// Below this a percentage is noise dressed as a finding.
    static let minimumCopiesForShare = 10

    /// The Help window footer, and the tail of `activityLine`.
    public var summaryLine: String {
        guard hasStatistics else { return "Nothing cleaned yet" }
        return "\(plural(characterCount, "character")) in \(plural(copyCount, "copy", "copies"))"
    }

    private func plural(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        let noun = value == 1 ? singular : (plural ?? singular + "s")
        return "\(value.formatted(.number.locale(locale))) \(noun)"
    }
}
