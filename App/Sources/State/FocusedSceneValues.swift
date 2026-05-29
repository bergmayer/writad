import SwiftUI

/// Per-scene action published via `.focusedSceneValue`. Each
/// `EditorView` exposes a closure that knows which scene it belongs
/// to; menu bar commands read it through `@FocusedValue` so they
/// always target the focused window, not whichever scene happened to
/// register last with `AppStateBus`.
///
/// This solves the "menu bar item opens the sheet on a backgrounded
/// window" bug — `AppStateBus.scenes.currentEditor` lags behind
/// real scene focus on iPad in some Stage Manager / Split View
/// configurations, but `@FocusedSceneValue` resolves to the correct
/// scene at invocation time.
struct FocusedSheetPresenterKey: FocusedValueKey {
    typealias Value = SheetPresenter
}

/// Plain wrapper struct so the FocusedValueKey requirement is met
/// without depending on closure-type conformance to whatever
/// Sendable / Equatable shape the protocol expects across SDK
/// versions. The wrapped closure runs on the main actor.
struct SheetPresenter {
    let present: @MainActor (EditorSheet) -> Void

    @MainActor
    func callAsFunction(_ sheet: EditorSheet) {
        present(sheet)
    }
}

extension FocusedValues {
    var presentEditorSheet: SheetPresenter? {
        get { self[FocusedSheetPresenterKey.self] }
        set { self[FocusedSheetPresenterKey.self] = newValue }
    }
}

/// Per-scene reference to the active session. Menu commands that
/// need to act on the foreground window's tabs (New Tab, Close Tab,
/// Reopen Closed Tab, Next/Previous Tab, Jump to Tab, Show All
/// Tabs, etc.) read this via `@FocusedValue` so they always hit
/// the focused window's session even when `AppStateBus.scenes
/// .currentSession` lags. Each `EditorScene.onAppear` publishes
/// its own session.
struct FocusedSessionKey: FocusedValueKey {
    typealias Value = EditorSession
}

extension FocusedValues {
    var focusedSession: EditorSession? {
        get { self[FocusedSessionKey.self] }
        set { self[FocusedSessionKey.self] = newValue }
    }
}
