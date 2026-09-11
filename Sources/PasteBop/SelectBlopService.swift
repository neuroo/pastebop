//
//  SelectBlopService.swift
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
/// This runs whether or not clipboard watching is switched on: choosing the
/// menu item is an explicit request, not something happening behind the user.
@MainActor
final class SelectBlopService: NSObject {

    /// Read at call time, so an edit to the rules file applies immediately.
    private let rules: () -> RewriteRules

    init(rules: @escaping () -> RewriteRules) {
        self.rules = rules
    }

    /// Named by `NSMessage` in Info.plist. Renaming it breaks the service.
    @objc
    func selectBlop(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // Nothing to change means nothing written, so the selection is left
        // exactly as it was rather than replaced with an identical copy. A
        // large selection is rewritten off the main thread and waited for,
        // with a deadline past which it is left alone.
        PasteboardWork.normalizeSelection(pasteboard, rules: rules())
    }
}
