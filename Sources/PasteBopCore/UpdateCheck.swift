//
//  UpdateCheck.swift
//  PasteBopCore
//

import Foundation

/// Whether a newer release exists. Not an updater: builds are ad-hoc signed,
/// and swapping in a binary the user never chose to download is what signing
/// exists to prevent. Pure, so it is testable without a socket.
public enum UpdateCheck {

    /// The part of GitHub's release payload that matters.
    public struct Release: Sendable, Equatable, Decodable {
        public let version: AppVersion
        public let pageURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        public init(version: AppVersion, pageURL: URL) {
            self.version = version
            self.pageURL = pageURL
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .tagName)
            guard let version = AppVersion(tag) else {
                throw Failure.unreadableTag(tag)
            }
            self.version = version
            self.pageURL = try container.decode(URL.self, forKey: .htmlURL)
        }
    }

    public enum Outcome: Sendable, Equatable {
        case upToDate(AppVersion)
        case updateAvailable(Release)
    }

    public enum Failure: LocalizedError, Equatable {
        case unreadableTag(String)
        case notFound
        case rateLimited
        case server(Int)
        case unreadableVersion(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableTag(let tag):
                "The latest release is tagged \"\(tag)\", which is not a PasteBop version."
            case .notFound:
                "No releases found. If the repository is private, update checks will not work."
            case .rateLimited:
                "GitHub is rate limiting update checks. Try again in a little while."
            case .server(let status):
                "GitHub returned status \(status)."
            case .unreadableVersion(let version):
                "This build reports its version as \"\(version)\", which cannot be compared."
            }
        }
    }

    /// GitHub excludes drafts and pre-releases from this endpoint.
    public static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    public static func outcome(
        status: Int,
        body: Data,
        currentVersion: String
    ) throws -> Outcome {
        guard let current = AppVersion(currentVersion) else {
            throw Failure.unreadableVersion(currentVersion)
        }
        switch status {
        case 200: break
        case 404: throw Failure.notFound
        case 403, 429: throw Failure.rateLimited
        default: throw Failure.server(status)
        }

        let release = try JSONDecoder().decode(Release.self, from: body)
        return release.version > current ? .updateAvailable(release) : .upToDate(current)
    }
}
