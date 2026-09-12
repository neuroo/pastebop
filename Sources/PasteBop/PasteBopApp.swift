//
//  PasteBopApp.swift
//  PasteBop
//

import AppKit
import SwiftUI

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

@main
struct PasteBopApp: App {

    /// For the Help window link.
    static let repository = "neuroo/pastebop"

    static let repositoryURL: URL = {
        guard let url = URL(string: "https://github.com/\(repository)") else {
            preconditionFailure("\(repository) is not a usable URL path")
        }
        return url
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            // Template rendering comes from the asset catalog, so the glyph
            // follows the menu bar's tint.
            Image("MenuBarIcon")
                .opacity(delegate.model.isEnabled ? 1 : 0.4)
                .accessibilityLabel(delegate.model.isEnabled ? "PasteBop, on" : "PasteBop, off")
        }
        .menuBarExtraStyle(.menu)

        Window("PasteBop Rules", id: RulesWindow.id) {
            RulesView(model: delegate.model)
        }
        // Unlike About, this is a list someone reads down: contentMinSize
        // keeps the layout's size as a floor and lets it grow from there.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 580)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("About PasteBop", id: AboutWindow.id) {
            AboutView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        // Without this an accessory app's window drags a File/Edit/View menu
        // into existence.
        .commandsRemoved()
    }
}

/// The clipboard has to be watched from launch, not from the first time a
/// view happens to appear.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = AppModel()

    private lazy var service = SelectBopService { [model] in model.rules }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()

        // The Services menu entry. macOS caches the registration, so nudge it
        // in case the bundle moved since it was last scanned.
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()
    }

    /// Quitting does not have to close the rules window first, so a switch
    /// flipped inside the debounce would otherwise never reach the file.
    func applicationWillTerminate(_ notification: Notification) {
        model.rulesEditor.flush()
    }
}

enum AboutWindow {
    static let id = "about"

    /// Without the activation the window opens behind whatever the user was
    /// working in.
    @MainActor
    static func show(using openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)
    }
}

enum RulesWindow {
    static let id = "rules"

    @MainActor
    static func show(using openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)
    }
}
