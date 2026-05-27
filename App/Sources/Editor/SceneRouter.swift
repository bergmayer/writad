import Foundation

/// SwiftUI's `@FocusedValue` doesn't propagate into the engine's
/// UIKit text view, so menu / palette / UIKit code reads focus
/// through these pointers instead.
@MainActor
@Observable
final class SceneRouter {

    weak var currentEditor: EditorState?

    /// Re-bound on each scene `.active` transition so menu commands
    /// target the visible scene, not the most recently appeared one.
    weak var currentSession: EditorSession?

    /// Installed by each editor scene's `onAppear`. Lets non-View
    /// callers open named `WindowGroup` scenes.
    var openWindowAction: ((SceneID) -> Void)?

    /// Routes a URL to a new window or new tab per the open menu's
    /// override. Invoked from UIKit entry points like
    /// `DocumentPickerBridge` that don't have a session reference.
    var routeOpenURL: ((URL) -> Void)?

    /// Home-screen quick action that fired before any scene mounted.
    /// Consumed by the first scene to appear.
    var pendingShortcut: HomeShortcut?

    /// Tripped by the first scene to apply the launch-behaviour
    /// preference, so subsequent scenes don't re-fire it.
    var hasAppliedLaunchBehavior = false

    // MARK: Session registry

    private var sessionRegistry: [WeakRef<EditorSession>] = []

    func registerSession(_ session: EditorSession) {
        sessionRegistry.removeAll { $0.ref == nil || $0.ref === session }
        sessionRegistry.append(WeakRef(session))
    }

    func deregisterSession(_ session: EditorSession) {
        sessionRegistry.removeAll { $0.ref == nil || $0.ref === session }
    }

    /// Read-only; never prune on read — that would be a write inside
    /// a getter, which freezes SwiftUI bindings in a tight
    /// invalidation loop. Stale slots clear next register/deregister.
    var allOpenSessions: [EditorSession] {
        sessionRegistry.compactMap { $0.ref }
    }

    /// Per-window chrome (outline sidebar X, tab bar +, split toggle,
    /// status-bar buttons) must call this before any CommandActions
    /// invocation that reads `currentEditor` / `currentSession`. On
    /// iPad multi-window, scenePhase fires for both visible scenes
    /// in unpredictable order, so the pointers can be stale at tap
    /// time — claim-on-tap is the only reliable fix until SwiftUI
    /// exposes a "this scene gained user input" signal.
    func claimFocus(session: EditorSession) {
        if currentSession !== session { currentSession = session }
        let activeState = session.activeTab.state
        if currentEditor !== activeState { currentEditor = activeState }
    }

    /// Same idea, but the caller only has the leaf `EditorState`
    /// (outline sidebar, info inspector, split panes). Walks the
    /// registry to find the owning session so the pair stays
    /// internally consistent.
    func claimFocus(state: EditorState) {
        if currentEditor !== state { currentEditor = state }
        if let session = currentSession, session.tabs.contains(where: { $0.state === state }) {
            return
        }
        for candidate in allOpenSessions where candidate.tabs.contains(where: { $0.state === state }) {
            currentSession = candidate
            return
        }
    }

    /// Resolves a tab id back to its owning session. Cross-window
    /// drag uses this to find the source on drop.
    func session(containing tabID: UUID) -> EditorSession? {
        allOpenSessions.first { session in
            session.tabs.contains(where: { $0.id == tabID })
        }
    }

    // MARK: User-requested scene opens

    /// iOS has no `restorationBehavior(.disabled)`, so palette
    /// scenes the system tries to restore would re-appear on cold
    /// launch. We gate them: `requestOpenWindow(_:)` adds the id;
    /// `consumeOpen(_:)` returns true only if a request matched.
    private var pendingPaletteOpens: Set<SceneID> = []

    func requestOpenWindow(_ id: SceneID) {
        pendingPaletteOpens.insert(id)
    }

    func consumeOpen(_ id: SceneID) -> Bool {
        pendingPaletteOpens.remove(id) != nil
    }
}

/// Replaces bare string literals at every `openWindow(id:)` call so
/// a typo fails the build instead of silently no-op'ing at runtime.
enum SceneID: String {
    case editor
    case preferences
    case multiFileSearch = "multi-file-search"
    case fileBrowser     = "file-browser"
    case markdownPreview = "markdown-preview"
}

/// `rawValue` must match the `UIApplicationShortcutItemType` strings
/// declared in Info.plist under `UIApplicationShortcutItems`.
enum HomeShortcut: String {
    case newFile        = "com.palefire.ayyyy.shortcut.newFile"
    case commandPalette = "com.palefire.ayyyy.shortcut.commandPalette"
}
