import Foundation

/// One-shot URL routing intents the editor scenes pick up via
/// `.onChange`.
@MainActor
@Observable
final class PendingURLs {

    /// Load into the current tab (Revert, pre-routed Multi-File-
    /// Search). Distinct from `newWindow`, which spawns a scene.
    var openInPlace: URL?

    /// "Open…" picked a file and the current scene already has a
    /// doc. The freshly-spawned scene's onAppear consumes it.
    var newWindow: URL?

    /// Line to jump to once a freshly-loaded document commits text
    /// into `EditorState`. Set by Multi-File Search result taps.
    var goToLine: Int?

    /// One-shot override for the next "Open…" routing. The "Open
    /// in New Tab…" / "Open in New Window…" menu items set it; the
    /// next `DocumentDestination.current()` clears it on read.
    var nextOpenDestinationOverride: DocumentDestination?

    /// Drives "Move Tab to New Window": source detaches, requests
    /// a new window, the new scene's onAppear adopts this tab in
    /// place of its default blank one.
    var adoptedTab: TabModel?
}

/// There's no app-wide preference — the File menu's per-open
/// "Open in New Tab…" / "Open in New Window…" items flip this for
/// the next open. ⌘N / ⌘T do what they say regardless.
enum DocumentDestination: String, CaseIterable, Identifiable {
    case window = "window"
    case tab    = "tab"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .window: "New window"
        case .tab:    "New tab"
        }
    }

    /// iPhone is single-window by OS design and always returns
    /// `.tab`. iPad reads the one-shot override and clears it in
    /// `EditorScene.route(open:)` once routing completes.
    @MainActor
    static func current() -> DocumentDestination {
        if DeviceIdiom.isPhone { return .tab }
        return AppStateBus.shared.pending.nextOpenDestinationOverride ?? .window
    }
}
