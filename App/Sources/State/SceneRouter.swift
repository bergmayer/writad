import Foundation

@MainActor
@Observable
final class SceneRouter {

    weak var currentEditor: EditorState?
    weak var currentSession: EditorSession?

    /// Installed once at app start by `WindowOpenerInstaller`; bridges
    /// non-View callers to SwiftUI's `@Environment(\.openWindow)`,
    /// which can't be reached outside a View body.
    var openWindow: ((SceneID) -> Void)?

    var pendingShortcut: HomeShortcut?
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

    /// iPad multi-window scenePhase ordering is unstable; per-window
    /// chrome calls this on tap so the upcoming sheet / command lands
    /// on the right scene.
    func claimFocus(session: EditorSession) {
        if currentSession !== session { currentSession = session }
        let activeState = session.activeTab.state
        if currentEditor !== activeState { currentEditor = activeState }
    }

    func claimFocus(state: EditorState) {
        if currentEditor !== state { currentEditor = state }
        if let session = currentSession, session.tabs.contains(where: { $0.state === state }) {
            return
        }
        for candidate in allOpenSessions where candidate.tabs.contains(where: { $0.state === state }) {
            currentSession = candidate
            return
        }
        // Fail closed: a stale currentSession from another window would
        // route OR-gated sheets/pickers to the wrong scene.
        currentSession = nil
    }

    func session(containing tabID: UUID) -> EditorSession? {
        allOpenSessions.first { $0.tabs.contains { $0.id == tabID } }
    }

    /// Single source of truth for "is this scene the foreground one."
    /// Used to gate per-scene sheets/pickers/alerts so a shared bus flag
    /// surfaces them on the focused window only. EditorView and
    /// EditorScene both call this; keeping the policy here (not inlined
    /// at each call site) is the difference between a one-line edit and
    /// dredging up every modifier when the focus model evolves.
    func isActive(_ state: EditorState) -> Bool {
        currentEditor === state
    }

    /// iOS has no `restorationBehavior(.disabled)`; palette / preview
    /// scenes the system tries to restore would surface on cold
    /// launch. Each user-initiated open registers here; the target
    /// scene's `.onAppear` checks via `consumeOpen` and dismisses
    /// itself if no request matched.
    private var pendingPaletteOpens: Set<SceneID> = []

    func requestOpenWindow(_ id: SceneID) {
        pendingPaletteOpens.insert(id)
    }

    func consumeOpen(_ id: SceneID) -> Bool {
        pendingPaletteOpens.remove(id) != nil
    }
}

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
    case newFile        = "com.palefire.writad.shortcut.newFile"
    case commandPalette = "com.palefire.writad.shortcut.commandPalette"
}
