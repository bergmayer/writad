import Foundation

/// What the active editor scene exposes back to the menu / palette.
@MainActor
@Observable
final class EditingState {

    var presentedSheet: EditorSheet?

    /// On the bus rather than the scene so menu / palette / toolbar
    /// can toggle the switcher without holding a scene reference.
    /// The active scene runs the `matchedGeometryEffect` morph
    /// itself — the switcher isn't a sheet.
    var tabSwitcherActive: Bool = false

    /// Installed by the active scene's `EditorView.onAppear`.
    var saveCurrentDocument: (() -> Void)?

    /// Bumped by the menu to ask the active scene to revert.
    var revertRequestCount: Int = 0

    /// Non-nil triggers a load/save-failure alert in the active
    /// editor.
    var openErrorMessage: String?

    /// Set by `CommandActions.requestCloseTab(_:)` when a dirty or
    /// untitled tab needs the confirmation dialog.
    var pendingClose: PendingClose?
}

/// The session id is captured so the dialog targets the right
/// window even if focus shifts before the user taps a button.
@MainActor
struct PendingClose: Identifiable {
    let id = UUID()
    let sessionID: ObjectIdentifier
    let tabID: UUID
    let displayName: String
    let isUntitled: Bool
}
