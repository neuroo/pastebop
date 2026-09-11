//
//  AppSupport.swift
//  PasteBop
//

import Foundation
import PasteBopCore

/// `~/Library/Application Support/PasteBop/`: state a user might reasonably
/// open, edit or delete by hand. Settings stay in `UserDefaults`.
enum AppSupport {

    static let directoryName = "PasteBop"
    static let updateStateFile = "update-state.json"

    /// Nil if the folder cannot be made; the app still works, it just forgets
    /// between launches.
    static func directory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let folder = base.appending(path: directoryName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder
    }
}

/// A missing, unreadable or corrupt file means "never checked", so nothing
/// here throws.
struct UpdateStateStore {

    private let url: URL?

    init(url: URL? = AppSupport.directory()?.appending(path: AppSupport.updateStateFile)) {
        self.url = url
    }

    /// ISO 8601 on both sides: readable, and a mismatch would silently reset
    /// the state every launch.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func load() -> UpdateState {
        guard let url, let data = try? Data(contentsOf: url) else { return UpdateState() }
        return (try? Self.decoder.decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    func save(_ state: UpdateState) {
        guard let url, let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
