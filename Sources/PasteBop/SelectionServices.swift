//
//  SelectionServices.swift
//  PasteBop
//

import AppKit
import PasteBopCore

/// The two Services entries, for the two things a selection can be.
///
/// **SelectBlop** declares return types, so macOS replaces the selection with
/// what it hands back. **CopyBlop** declares none and puts the result on the
/// clipboard instead.
///
/// Which one appears is not PasteBop's decision and cannot be: a service
/// provider is handed a pasteboard and nothing else, with no reference to the
/// view the text came from. macOS asks the responder chain
/// `validRequestorForSendType:returnType:`, and a read-only view answers nil
/// when a return type is wanted, so SelectBlop is hidden there. Apps
/// implement that inconsistently, which is why CopyBlop exists: it works
/// anywhere, because nothing has to be written back.
///
/// Both run whether or not clipboard watching is switched on: choosing a menu
/// item is an explicit request, not something happening behind the user.
@MainActor
final class SelectionServices: NSObject {

    /// Read at call time, so an edit to the rules file applies immediately.
    private let rules: () -> RewriteRules

    init(rules: @escaping () -> RewriteRules) {
        self.rules = rules
    }

    /// Replaces the selection. Named by `NSMessage` in Info.plist; renaming it
    /// breaks the menu item, which is why `Scripts/verify-release.sh` checks.
    @objc
    func selectBlop(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // Nothing to change means nothing written, so the selection is left
        // exactly as it was rather than replaced with an identical copy.
        PasteboardWork.normalizeSelection(pasteboard, rules: rules())
    }

    /// Puts the cleaned selection on the clipboard, leaving the original
    /// alone. The only thing that can work on text you cannot edit.
    @objc
    func copyBlop(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard PasteboardWork.copyNormalizedSelection(pasteboard, rules: rules()) else {
            // The one case worth interrupting for: the user asked, and there
            // was nothing readable to act on.
            error.pointee = "PasteBop could not read the selection." as NSString
            return
        }
    }
}
