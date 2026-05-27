import UIKit
import SwiftUI

/// Opens a new editor window with `UIWindowSceneProminentPlacement`
/// set on the activation request itself — the only point iPad will
/// actually honor the placement hint. SwiftUI's `openWindow(id:)`
/// activates without options, so new windows land flat behind the
/// spawning one and look identical to it. Calling
/// `activateSceneSession(for:)` ourselves lets us slot the placement
/// in.
///
/// Tags the activation with an `NSUserActivity` whose `activityType`
/// matches the SwiftUI `WindowGroup` id so iOS routes the new scene
/// to our editor surface (and not, say, the preferences group).
/// Falls back through the bus's `openWindowAction` if the system
/// returns an error — the window still opens, just without our
/// placement preference.
@MainActor
enum WindowPlacement {

    static func openEditorWindow(fallback: (() -> Void)? = nil) {
        guard !DeviceIdiom.isPhone else {
            fallback?()
            return
        }
        let options = UIWindowScene.ActivationRequestOptions()
        options.placement = .prominent()
        let activity = NSUserActivity(activityType: SceneID.editor.rawValue)
        activity.targetContentIdentifier = SceneID.editor.rawValue
        let request = UISceneSessionActivationRequest(
            role: .windowApplication,
            userActivity: activity,
            options: options
        )
        UIApplication.shared.activateSceneSession(for: request) { _ in
            // System rejected the request (uncommon — usually placement
            // is just ignored rather than failing). Fall back to the
            // SwiftUI path so the user still gets a window.
            Task { @MainActor in
                fallback?()
            }
        }
    }
}
