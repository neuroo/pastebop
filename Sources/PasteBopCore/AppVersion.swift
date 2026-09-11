//
//  AppVersion.swift
//  PasteBopCore
//

/// A date, with an optional counter for a second release the same day:
/// `2026.09.11`, `2026.09.11.2`. Mirrors `Scripts/version.sh`.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {

    public let year: Int
    public let month: Int
    public let day: Int
    /// Which release that day. Absent in the string means the first.
    public let release: Int

    public init?(_ string: String) {
        // Tags carry a leading v; Info.plist values do not.
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count) else { return nil }

        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }

        year = numbers[0]
        month = numbers[1]
        day = numbers[2]
        release = numbers.count == 4 ? numbers[3] : 1

        // Four-digit year, as version.sh requires; otherwise "1.2.3" is a date.
        guard (1000...9999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              release >= 1
        else { return nil }
    }

    public var description: String {
        let date = "\(year).\(String(format: "%02d", month)).\(String(format: "%02d", day))"
        return release == 1 ? date : "\(date).\(release)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.release) < (rhs.year, rhs.month, rhs.day, rhs.release)
    }
}
