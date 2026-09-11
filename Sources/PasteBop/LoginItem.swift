//
//  LoginItem.swift
//  PasteBop
//

import Foundation
import ServiceManagement

/// `SMAppService.mainApp`: no helper bundle, no privileged install. macOS
/// lists the app under Login Items in System Settings.
@MainActor
enum LoginItem {

    enum Failure: LocalizedError {
        /// Switched off in System Settings, which the app cannot override.
        case blockedBySystemSettings
        case system(any Error)

        var errorDescription: String? {
            switch self {
            case .blockedBySystemSettings:
                "macOS is blocking this. Turn PasteBop on under Login Items."
            case .system(let error):
                error.localizedDescription
            }
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
            }
        } catch {
            throw Failure.system(error)
        }

        // register() reports success even when System Settings has the app
        // switched off; only the status afterwards tells the truth. Without
        // this the toggle sits on while nothing happens at login.
        if enabled, service.status == .requiresApproval {
            throw Failure.blockedBySystemSettings
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
