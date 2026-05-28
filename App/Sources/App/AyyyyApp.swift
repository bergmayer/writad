import SwiftUI
import UIKit

@main
struct AyyyyApp: App {

    /// Bridges UIKit's quick-action callbacks (Info.plist
    /// `UIApplicationShortcutItems`) into `AppStateBus.pendingShortcut`
    /// so the SwiftUI scene system can react.
    @UIApplicationDelegateAdaptor(AppDelegateBridge.self) private var appDelegate

    init() {
        AppPreferenceDefaults.register()
        TemplatesStore.shared.seedIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Editor", id: SceneID.editor.rawValue) {
            EditorScene()
        }
        .commands {
            EditorCommands()
        }

        // Settings as a separate scene. On iPadOS this opens as a
        // separate window when invoked via `@Environment(\.openWindow)`.
        WindowGroup("Settings", id: SceneID.preferences.rawValue) {
            PreferencesView()
        }
        .defaultSize(width: 560, height: 460)
        .commandsRemoved()

        // Multi-File Search lives in its own scene so it stays on
        // screen while the user opens result files in editor tabs/
        // windows. Same `requestOpenWindow` / dismiss-on-restore dance
        // as the palette to keep iPadOS from restoring it as the
        // launch surface.
        WindowGroup("Multi-File Search", id: SceneID.multiFileSearch.rawValue) {
            MultiFileSearchSheet()
        }
        .defaultSize(width: 560, height: 640)
        .commandsRemoved()

        // File Browser as its own scene — the "iPad way" of opening
        // documents. UIDocumentBrowserViewController hosted in a
        // real window (not a modal sheet). The window stays open so
        // the user can pick file after file; each pick spawns a
        // new editor window via `routeOpenURL`.
        WindowGroup("File Browser", id: SceneID.fileBrowser.rawValue) {
            FileBrowserScene()
        }
        .defaultSize(width: 720, height: 600)
        .commandsRemoved()

        // Markdown Preview scene. Reads the focused editor's text
        // and renders it through `marked.js` in a WKWebView. The user
        // can then Share / Print → Save as PDF from the toolbar.
        WindowGroup("Markdown Preview", id: SceneID.markdownPreview.rawValue) {
            MarkdownPreviewScene()
        }
        .defaultSize(width: 720, height: 880)
        .commandsRemoved()
    }
}

/// UIKit bridge for Home-Screen quick actions. The SwiftUI app sets this
/// as its `UIApplicationDelegateAdaptor` so the system can call its
/// shortcut callbacks. Lives in the same file as `AyyyyApp` to avoid
/// adding a new file to the pbxproj.
@MainActor
final class AppDelegateBridge: NSObject, UIApplicationDelegate {

    /// Captured when the process starts. Used to distinguish "iPadOS
    /// is restoring a session from a previous app run" (fires within
    /// a couple of seconds of launch) from "user just hit ⌘N" (fires
    /// later, mid-session). The former is the case we want to deny.
    private let processStart = Date()

    /// Flips true as soon as the first scene config is handed out.
    /// During cold launch, every scene after the first is iPadOS
    /// auto-restoring extras — we destroy those.
    private var hasAllowedFirstScene = false

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            apply(item)
        }
        // Cross-launch window restoration is OFF by user preference.
        // iPadOS keeps `UISceneSession` objects alive across app
        // launches and auto-restores them on next launch — that's
        // the "two windows come back after I swiped them away" bug.
        // During the cold-launch window we accept exactly one scene
        // and destroy the rest; after the cold-launch window all
        // scenes are user-initiated (⌘N, the + button, openWindow)
        // and pass through unmolested.
        let isColdLaunchWindow = Date().timeIntervalSince(processStart) < 5.0
        if isColdLaunchWindow {
            if hasAllowedFirstScene {
                application.requestSceneSessionDestruction(
                    connectingSceneSession,
                    options: nil,
                    errorHandler: nil
                )
            } else {
                hasAllowedFirstScene = true
            }
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    /// Called when iPadOS itself discards sessions (e.g., the user
    /// swiped them away in the App Switcher while the app was
    /// running, or the OS cleaned up after a force-quit). Mirror the
    /// discards into our own SessionsStore so our records don't
    /// outlive the system's view of the world.
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        // No store API for "remove by UISceneSession" — we key on
        // our own sceneUUID, which the system doesn't know. The
        // records get pruned naturally via the size cap; doing
        // nothing here is fine.
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        apply(shortcutItem)
        completionHandler(true)
    }

    private func apply(_ item: UIApplicationShortcutItem) {
        guard let action = HomeShortcut(rawValue: item.type) else { return }
        AppStateBus.shared.scenes.pendingShortcut = action
    }
}
