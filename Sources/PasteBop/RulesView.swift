//
//  RulesView.swift
//  PasteBop
//

import PasteBopCore
import SwiftUI

/// The rules window: families down the side, their characters beside them.
/// The file stays the place to change *what* a character becomes; this is for
/// leaving something alone.
struct RulesView: View {

    let model: AppModel

    @State private var selected: Replacement.Category?

    private var editor: RulesEditor { model.rulesEditor }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                families
                    .frame(minWidth: 210, idealWidth: 232, maxWidth: 280)
                Divider()
                detail
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 300, maxHeight: .infinity)
            if let failure = model.ruleStore.failureMessage {
                Divider()
                warning(failure)
            }
            if let failure = model.cloudMirror?.failure {
                Divider()
                warning(failure)
            }
            Divider()
            footer
        }
        .frame(
            minWidth: 660,
            idealWidth: 720,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 580,
            maxHeight: .infinity
        )
        .background(.background)
        .onAppear {
            editor.reload()
            selectSomething()
        }
        .onDisappear { editor.flush() }
        // Any change to the file while this window is open — a hand edit
        // picked up by the watcher, or a table arriving from iCloud.
        .onChange(of: model.ruleStore.revision) {
            editor.reload()
            selectSomething()
        }
    }

    /// The selected family can vanish while the window is open, if the file
    /// was edited by hand.
    private func selectSomething() {
        let families = editor.selection.categories
        if let selected, families.contains(selected) { return }
        selected = families.first
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Rules")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("""
                Switch off anything you would rather PasteBop left alone. \
                Changes take effect on the next copy.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: - Families

    private var families: some View {
        List(editor.selection.categories, id: \.self, selection: $selected) { category in
            VStack(alignment: .leading, spacing: 3) {
                Text(category.rawValue)
                    .font(.callout)
                Text(count(for: category))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.vertical, 5)
            .tag(category)
        }
        .listStyle(.sidebar)
    }

    private func count(for category: Replacement.Category) -> String {
        let total = editor.selection.rules(in: category).count
        let on = editor.selection.enabledCount(in: category)
        if on == 0 { return "off" }
        return on == total ? "\(total) characters" : "\(on) of \(total)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            FamilyDetail(editor: editor, category: selected)
        } else {
            Text("No rules")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Restore Defaults") { editor.restoreDefaults() }
            Button("Open rules.yaml") { model.ruleStore.edit() }
                .help("Edit the file directly to change what a character becomes.")

            Spacer()

            Text("\(editor.selection.enabledScalarCount.formatted()) characters on")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - One family

private struct FamilyDetail: View {

    let editor: RulesEditor
    let category: Replacement.Category

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(category.rawValue)
                    .font(.headline)
                Spacer(minLength: 8)
                Toggle("Rewrite \(category.rawValue)", isOn: Binding(
                    get: { editor.selection.isOn(category) },
                    set: { editor.setOn(category, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(editor.selection.rules(in: category), id: \.pattern) { rule in
                        RuleRow(editor: editor, rule: rule)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct RuleRow: View {

    let editor: RulesEditor
    let rule: Replacement

    @State private var isHovering = false

    private var isOn: Bool { editor.selection.isOn(rule) }

    var body: some View {
        HStack(spacing: 10) {
            // Everything up to the switch is the click target. The switch
            // stays outside it: a tap gesture spanning both can fire twice
            // for one click and land back where it started.
            HStack(spacing: 10) {
                before
                    .frame(width: 56, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

                after
                    .frame(width: 72, alignment: .leading)

                Text(rule.name.sentenceCased)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
            }
            .contentShape(.rect)
            .onTapGesture { editor.setOn(rule, !isOn) }

            Toggle("Rewrite \(rule.name)", isOn: Binding(
                get: { isOn },
                set: { editor.setOn(rule, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        .onHover { isHovering = $0 }
    }

    /// Spaces and invisibles have no glyph to show, so they show the code
    /// point instead: for those the number is the only visible identity.
    @ViewBuilder
    private var before: some View {
        if rule.category.hasVisibleGlyphs, !glyph.isEmpty {
            chip(glyph, code: false)
        } else {
            chip(codePoint, code: true)
        }
    }

    /// A word, not a chip, when nothing comes out the other side: an empty
    /// box would read as a character PasteBop could not draw.
    @ViewBuilder
    private var after: some View {
        switch rule.output {
        case "":
            Text("removed")
                .font(.callout)
                .foregroundStyle(.tertiary)
        case " ":
            Text("space")
                .font(.callout)
                .foregroundStyle(.tertiary)
        default:
            chip(rule.output, code: false)
        }
    }

    private func chip(_ text: String, code: Bool) -> some View {
        Text(text)
            .font(code ? .system(size: 10, design: .monospaced) : .system(size: 26))
            .lineLimit(1)
            .padding(.horizontal, code ? 5 : 4)
            .frame(minWidth: 46, minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private var glyph: String {
        if let scalar = rule.scalar { return String(scalar) }
        if let text = rule.sequenceText, !text.isEmpty { return text }
        return ""
    }

    private var codePoint: String {
        guard let range = rule.range else { return "seq" }
        let low = "U+" + String(range.lowerBound, radix: 16, uppercase: true)
        // A range covers more than it can show, and saying so beats naming
        // only its first character.
        return range.lowerBound == range.upperBound ? low : low + "\u{2026}"
    }
}

private extension String {
    /// The table stores Unicode names, which are upper case. A column of
    /// those reads as shouting.
    var sentenceCased: String {
        let lower = lowercased()
        guard let first = lower.first else { return lower }
        return first.uppercased() + lower.dropFirst()
    }
}
