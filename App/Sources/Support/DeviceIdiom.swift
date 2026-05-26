import UIKit

/// Single source of truth for "are we running on iPhone vs iPad".
/// iPhone is single-window by OS design, so the menu / scene routing
/// code collapses overlays and hides New Window on it. iPad gets the
/// full multi-window experience; the user can opt into per-tab
/// routing via the `openDocumentDestination` preference.
enum DeviceIdiom {

    /// `true` when running on iPhone (or iPhone-sized window on a
    /// device that can host one — currently no such configuration
    /// exists, but the check stays idiom-based for clarity).
    static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// `true` on iPad / Mac Catalyst / visionOS — anything that can
    /// host multiple scenes side by side.
    static var supportsMultipleWindows: Bool {
        !isPhone
    }
}
