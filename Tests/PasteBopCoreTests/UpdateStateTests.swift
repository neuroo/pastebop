//
//  UpdateStateTests.swift
//  PasteBopCoreTests
//

import Foundation
import Testing
@testable import PasteBopCore

@Suite("Update state")
struct UpdateStateTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A fresh install checks straight away")
    func neverChecked() {
        #expect(UpdateState().isCheckDue(now: now))
    }

    @Test("Waits out the interval")
    func waitsTheInterval() {
        let justChecked = UpdateState(lastCheck: now.addingTimeInterval(-60))
        #expect(!justChecked.isCheckDue(now: now))

        let sixDays = UpdateState(lastCheck: now.addingTimeInterval(-6 * 24 * 3600))
        #expect(!sixDays.isCheckDue(now: now))

        let eightDays = UpdateState(lastCheck: now.addingTimeInterval(-8 * 24 * 3600))
        #expect(eightDays.isCheckDue(now: now))
    }

    @Test("A last-check in the future does not postpone checks forever")
    func clockWentBackwards() {
        // A state file copied between machines, or a corrected clock.
        let future = UpdateState(lastCheck: now.addingTimeInterval(365 * 24 * 3600))
        #expect(future.isCheckDue(now: now))
    }

    @Test("Announces a release the user has not been told about")
    func announcesNewRelease() throws {
        let version = try #require(AppVersion("2026.10.03"))
        #expect(UpdateState().shouldAnnounce(version))
        #expect(UpdateState(lastNotifiedVersion: "2026.09.11").shouldAnnounce(version))
    }

    @Test("Does not announce the same release twice")
    func doesNotRepeatItself() throws {
        let version = try #require(AppVersion("2026.10.03"))
        #expect(!UpdateState(lastNotifiedVersion: "2026.10.03").shouldAnnounce(version))
        #expect(!UpdateState(lastNotifiedVersion: "2026.11.01").shouldAnnounce(version))
    }

    @Test("An unreadable remembered version does not silence the notice")
    func corruptNotifiedVersion() throws {
        let version = try #require(AppVersion("2026.10.03"))
        #expect(UpdateState(lastNotifiedVersion: "garbage").shouldAnnounce(version))
    }

    @Test("Survives a round trip through the stored file")
    func roundTrip() throws {
        let state = UpdateState(lastCheck: now, lastNotifiedVersion: "2026.10.03")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(state)
        #expect(try decoder.decode(UpdateState.self, from: data) == state)

        // The file is meant to be readable and editable by hand.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("2026-01-15") || json.contains("T"))
    }

    @Test("A missing field decodes rather than throwing")
    func partialFile() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(UpdateState.self, from: Data("{}".utf8))
        #expect(state == UpdateState())
        #expect(state.isCheckDue(now: now))
    }
}
