//
//  SelectBopService.swift
//  PasteBop
//

import AppKit
import PasteBopCore

/// The Services entry: rewrites a selection in place, in any app, without it
/// ever going through the clipboard.
///
/// macOS hands the service its own pasteboard holding the selection. Writing
/// back to it is what replaces the text, which is why the same
/// `PasteboardNormalizer` used for the clipboard works here unchanged --
/// including keeping RTF styling and refusing to touch a file or a link.
///
/// Only offered where the text is editable: a service that hands text back is
/// hidden when the responder says it cannot take it. There is no send-only
/// companion for read-only text, because copying it does the same job with
/// one keystroke instead of a submenu.
///
/// Runs whether or not clipboard watching is switched on: choosing the menu
/// item is an explicit request, not something happening behind the user.
@MainActor
final class SelectBopService: NSObject {

    /// Read at call time, so an edit to the rules file applies immediately.
    private let rules: () -> RewriteRules

    init(rules: @escaping () -> RewriteRules) {
        self.rules = rules
    }

    /// Replaces the selection. Named by `NSMessage` in Info.plist; renaming it
    /// breaks the menu item, which is why `Scripts/verify-release.sh` checks.
    @objc
    func selectBop(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // Nothing to change means nothing written, so the selection is left
        // exactly as it was rather than replaced with an identical copy.
        PasteboardWork.normalizeSelection(pasteboard, rules: rules())
    }
}
