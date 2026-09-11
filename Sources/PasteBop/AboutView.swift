//
//  AboutView.swift
//  PasteBop
//

import AppKit
import PasteBopCore
import SwiftUI

/// The Help / About window: what PasteBop is, and exactly which characters it
/// rewrites. The table is generated from `Replacements`, so it cannot drift
/// away from the code.
struct AboutView: View {

    @Bindable var model: AppModel
    @State private var didCopySample = false

    /// Characters cleaned per family, and the largest of them, so every bar
    /// shares one scale.
    private var cleaned: [Replacement.Category: Int] {
        Dictionary(uniqueKeysWithValues: model.familyTotals.map { ($0.category, $0.count) })
    }

    private var busiest: Int {
        max(1, model.familyTotals.first?.count ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.rules.families, id: \.self) { category in
                        CategoryRow(
                            category: category,
                            rules: model.rules,
                            cleaned: cleaned[category] ?? 0,
                            busiest: busiest
                        )
                    }
                }
                .padding(20)
            }
            .frame(height: 280)
            if let note = rulesNote {
                Divider()
                note
            }
            Divider()
            footer
        }
        .frame(width: 460)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image("Mascot")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("PasteBop")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(Bundle.main.shortVersion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Copied text, straightened out.")
                    .font(.body)
                Text("""
                    PasteBop watches the clipboard and rewrites \
                    \(model.rules.scalarCount.formatted()) typographic and invisible characters \
                    into the ones on your keyboard. Accented letters, emoji, CJK text and \
                    rich-text formatting are left alone.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    // MARK: - Rules

    /// Shown only when the rules file is doing something worth mentioning:
    /// it has been edited, or it cannot be read.
    @ViewBuilder
    private var rulesNote: (some View)? {
        if let failure = model.ruleStore.failure {
            note(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                text: "Rules file: \(failure) Still using the last rules that worked."
            )
        } else if model.ruleStore.isCustomised {
            note(
                icon: "slider.horizontal.3",
                tint: .secondary,
                text: "Using your own rules, \(model.rules.scalarCount.formatted()) characters."
            )
        }
    }

    private func note(icon: String, tint: some ShapeStyle, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Edit\u{2026}") { model.ruleStore.edit() }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(didCopySample ? "Copied \u{2014} now paste it" : "Try it") {
                copySample()
            }
            .disabled(!model.isEnabled)
            .help(model.isEnabled
                  ? "Copies a messy sample. Paste anywhere to see it cleaned up."
                  : "Enable PasteBop to try it.")

            Link("GitHub", destination: PasteBopApp.repositoryURL)

            Spacer()

            Text(model.report.summaryLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func copySample() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Replacements.sampleText, forType: .string)
        didCopySample = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            didCopySample = false
        }
    }
}

// MARK: - Rows

private struct CategoryRow: View {
    let category: Replacement.Category
    let rules: RewriteRules
    /// How many characters of this family PasteBop has rewritten so far.
    let cleaned: Int
    /// The busiest family's count, so every bar shares a scale.
    let busiest: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.rawValue)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(coveredCharacters.formatted()) covered")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(width: 146, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(rules.exampleInput(for: category))
                Text(rules.exampleOutput(for: category))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                Text(cleaned == 0 ? "\u{2013}" : cleaned.formatted())
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(cleaned == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Bar(fraction: Double(cleaned) / Double(busiest))
            }
            .frame(width: 72, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var coveredCharacters: Int {
        rules.scalarCount(in: category)
    }
}

/// A thin proportional bar. Zero renders as an empty track rather than nothing,
/// so the rows stay on a grid.
private struct Bar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}
