//
//  AppSupport.swift
//  PasteBop
//

import Foundation

/// `~/Library/Application Support/PasteBop/`: state a user might reasonably
/// open, edit or delete by hand. Settings stay in `UserDefaults`.
enum AppSupport {

    static let directoryName = "PasteBop"

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
