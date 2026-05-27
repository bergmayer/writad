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

    /// Set by `CommandActions.requestCloseOtherTabs` / `…Right` /
    /// `…AllTabs` when at least one tab in the closing set is dirty.
    var pendingBatchClose: PendingBatchClose?

    /// Stale-source dialog state — set by the launcher's draft-
    /// adoption path or by ⌘S when the source's disk mtime/size has
    /// drifted from what we recorded at load. Drives a single alert
    /// in `EditorView` with branch-appropriate buttons.
    var sourceStaleCheck: SourceStaleCheck?
}

/// What the user has to resolve before continuing.
enum SourceStaleCheck: Identifiable {
    /// File the draft references is gone. Continue as Untitled.
    case missing(tabID: UUID, displayName: String)
    /// Source file changed since draft was captured. The user picks
    /// between keeping the draft's bytes or reloading disk content.
    case changedOnAdopt(tabID: UUID, displayName: String)
    /// ⌘S aborted because the source file changed between load and
    /// save. The user picks force-save, reload, or cancel.
    case changedOnSave(tabID: UUID, displayName: String)

    var id: String {
        switch self {
        case .missing(let t, _):       return "missing-\(t)"
        case .changedOnAdopt(let t, _): return "changed-adopt-\(t)"
        case .changedOnSave(let t, _):  return "changed-save-\(t)"
        }
    }

    var displayName: String {
        switch self {
        case .missing(_, let n), .changedOnAdopt(_, let n), .changedOnSave(_, let n):
            return n
        }
    }
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

/// "Close Other Tabs" / "Close Tabs to the Right" / "Close All Tabs"
/// route through this when at least one of the tabs in the batch
/// has unsaved changes. The user picks Discard All (drops drafts)
/// or Save All to Drafts (parks the live bytes for launcher
/// recovery) — there's no per-tab Save-and-Close since the prompt
/// is meant to be quick.
@MainActor
struct PendingBatchClose: Identifiable {
    let id = UUID()
    let sessionID: ObjectIdentifier
    let tabIDs: [UUID]
    /// "Close 4 other tabs", "Close 7 tabs to the right", "Close all 9 tabs"
    let description: String
    /// Number of tabs in `tabIDs` that are actually dirty — used in
    /// the dialog message so the user sees the scope.
    let dirtyCount: Int
}
