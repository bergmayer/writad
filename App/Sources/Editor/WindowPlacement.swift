import UIKit

/// Best-effort attempt to differentiate freshly-opened iPad windows
/// from the scene they spawn off of. iPadOS has no public API to set
/// an explicit frame; the closest lever is
/// `UIWindowSceneProminentPlacement`, which the system *may* honor by
/// positioning the new window with offset/inset relative to siblings.
///
/// In full-screen / split view this is typically a no-op; in
/// free-form windowing (iPadOS 26) it nudges the system toward a
/// "more prominent" slot. Failure is silent — the new window still
/// opens, just without the cascade hint.
@MainActor
enum WindowPlacement {

    static func requestProminentPlacement(for scene: UIWindowScene) {
        guard !DeviceIdiom.isPhone else { return }
        let options = UIWindowScene.ActivationRequestOptions()
        options.placement = .prominent()
        let request = UISceneSessionActivationRequest(
            session: scene.session,
            userActivity: nil,
            options: options
        )
        UIApplication.shared.activateSceneSession(for: request) { _ in }
    }
}
