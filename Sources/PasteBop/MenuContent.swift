//
//  MenuContent.swift
//  PasteBop
//

import AppKit
import PasteBopCore
import SwiftUI

struct MenuContent: View {

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Enable PasteBop", isOn: $model.isEnabled)
            .keyboardShortcut("e")

        Text(report.activityLine)
        if let reading = report.lastCopyLine {
            Text(reading)
        }

        if report.hasStatistics {
            Menu("Statistics") {
                Text(report.lifetimeLine)
                Text("Since \(model.countingSince.formatted(date: .abbreviated, time: .omitted))")
                if let dominant = report.dominantFamilyLine {
                    Text(dominant)
                }
                if let share = report.machineShareLine {
                    Text(share)
                }

                Divider()

                ForEach(report.offenderLines(), id: \.self) { line in
                    Text(line)
                }

                Divider()

                Button("Reset Statistics") { model.resetStatistics() }
            }
        }

        Divider()

        Menu("Rules") {
            Button("Edit Rules\u{2026}") { RulesWindow.show(using: openWindow) }
            Divider()
            Button("Open rules.yaml") { model.ruleStore.edit() }
            Button("Reveal in Finder") { model.ruleStore.revealInFinder() }
            Divider()
            Button("Restore Default Rules") { model.ruleStore.restoreDefaults() }
        }
        if let failure = model.ruleStore.failure {
            Text("Rules file: \(failure)")
        }

        Divider()

        Toggle("Start at Login", isOn: $model.startsAtLogin)
        if let failure = model.loginItemFailure {
            Text(failure)
            Button("Open Login Items\u{2026}") { LoginItem.openSystemSettings() }
        }

        Divider()

        Button("About PasteBop\u{2026}") {
            AboutWindow.show(using: openWindow)
        }
        Button("Quit PasteBop") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var report: ActivityReport { model.report }
}
