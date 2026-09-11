//
//  UpdateCheckTests.swift
//  PasteBopCoreTests
//

import Foundation
import Testing
@testable import PasteBopCore

@Suite("App version")
struct AppVersionTests {

    @Test("Parses the versions the release scripts produce", arguments: [
        ("2026.09.11", "2026.09.11"),
        ("2026.9.11", "2026.09.11"),
        ("v2026.09.11", "2026.09.11"),
        ("2026.09.11.1", "2026.09.11"),
        ("2026.09.11.2", "2026.09.11.2"),
        ("v2026.12.01.10", "2026.12.01.10"),
    ])
    func parses(_ input: String, _ printed: String) throws {
        let version = try #require(AppVersion(input))
        #expect(version.description == printed)
    }

    @Test("Rejects anything that is not a date", arguments: [
        "", "1.2.3", "2026.13.01", "2026.00.11", "2026.09.32", "2026.09",
        "2026.09.11.0", "2026.09.11.2.3", "abc", "2026.09.xx", "v", "2026..11",
    ])
    func rejects(_ input: String) {
        #expect(AppVersion(input) == nil)
    }

    @Test("Orders by date, then by release")
    func ordering() throws {
        let ascending = try [
            "2026.09.11", "2026.09.11.2", "2026.09.12", "2026.10.01", "2027.01.01",
        ].map { try #require(AppVersion($0)) }

        #expect(ascending == ascending.sorted())
        // The trap a string comparison would fall into: "10" sorts before "9".
        #expect(try #require(AppVersion("2026.10.01")) > #require(AppVersion("2026.09.30")))
        // An unsuffixed version is the first release of its day.
        let unsuffixed = try #require(AppVersion("2026.09.11"))
        let explicit = try #require(AppVersion("2026.09.11.1"))
        #expect(unsuffixed == explicit)
    }
}

@Suite("Update check")
struct UpdateCheckTests {

    private func payload(tag: String) -> Data {
        Data("""
        {"tag_name": "\(tag)",
         "html_url": "https://github.com/neuroo/pastebop/releases/tag/\(tag)",
         "name": "PasteBop", "draft": false, "prerelease": false}
        """.utf8)
    }

    @Test("Reports an update when the release is newer")
    func newerRelease() throws {
        let outcome = try UpdateCheck.outcome(
            status: 200,
            body: payload(tag: "v2026.10.03"),
            currentVersion: "2026.09.11"
        )
        guard case .updateAvailable(let release) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(release.version.description == "2026.10.03")
        #expect(release.pageURL.absoluteString.hasSuffix("v2026.10.03"))
    }

    @Test("Reports up to date when the release matches or trails", arguments: [
        "v2026.09.11", "v2026.09.10", "v2025.12.31",
    ])
    func notNewer(_ tag: String) throws {
        let outcome = try UpdateCheck.outcome(
            status: 200, body: payload(tag: tag), currentVersion: "2026.09.11"
        )
        #expect(outcome == .upToDate(try #require(AppVersion("2026.09.11"))))
    }

    @Test("A same-day rebuild counts as an update")
    func sameDayRebuild() throws {
        let outcome = try UpdateCheck.outcome(
            status: 200, body: payload(tag: "v2026.09.11.2"), currentVersion: "2026.09.11"
        )
        guard case .updateAvailable(let release) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(release.version.description == "2026.09.11.2")
    }

    @Test("Explains the failures a user can actually hit", arguments: [
        (404, UpdateCheck.Failure.notFound),
        (403, UpdateCheck.Failure.rateLimited),
        (429, UpdateCheck.Failure.rateLimited),
        (500, UpdateCheck.Failure.server(500)),
    ])
    func httpFailures(_ status: Int, _ expected: UpdateCheck.Failure) {
        #expect(throws: expected) {
            try UpdateCheck.outcome(status: status, body: Data(), currentVersion: "2026.09.11")
        }
    }

    @Test("Rejects a release tagged with something that is not a version")
    func unreadableTag() {
        #expect(throws: UpdateCheck.Failure.unreadableTag("nightly")) {
            try UpdateCheck.outcome(
                status: 200, body: payload(tag: "nightly"), currentVersion: "2026.09.11"
            )
        }
    }

    @Test("Refuses to compare against a build with no usable version")
    func unreadableCurrentVersion() {
        // A bundle built without the version substituted must not silently
        // report itself up to date.
        #expect(throws: UpdateCheck.Failure.unreadableVersion("dev")) {
            try UpdateCheck.outcome(
                status: 200, body: payload(tag: "v2026.10.03"), currentVersion: "dev"
            )
        }
    }

    @Test("Fails cleanly on a malformed body")
    func malformedBody() {
        #expect(throws: (any Error).self) {
            try UpdateCheck.outcome(
                status: 200, body: Data("not json".utf8), currentVersion: "2026.09.11"
            )
        }
    }

    @Test("Builds the releases endpoint")
    func endpoint() throws {
        let url = try #require(UpdateCheck.latestReleaseURL(repository: "neuroo/pastebop"))
        #expect(url.absoluteString == "https://api.github.com/repos/neuroo/pastebop/releases/latest")
    }
}
