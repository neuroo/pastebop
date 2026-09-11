//
//  UpdateState.swift
//  PasteBopCore
//

import Foundation

/// What PasteBop remembers between update checks.
public struct UpdateState: Codable, Sendable, Equatable {

    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// Successful or not: an offline machine must not retry on a loop.
    public var lastCheck: Date?

    /// So the same release is never announced twice.
    public var lastNotifiedVersion: String?

    public init(lastCheck: Date? = nil, lastNotifiedVersion: String? = nil) {
        self.lastCheck = lastCheck
        self.lastNotifiedVersion = lastNotifiedVersion
    }

    public func isCheckDue(now: Date = .now, interval: TimeInterval = Self.interval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards, or a state file copied from another machine,
        // must not postpone checks forever.
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    public func shouldAnnounce(_ version: AppVersion) -> Bool {
        guard let announced = lastNotifiedVersion.flatMap(AppVersion.init) else { return true }
        return version > announced
    }
}
