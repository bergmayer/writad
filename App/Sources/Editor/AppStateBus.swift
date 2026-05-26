import SwiftUI

/// Umbrella for the app's shared @Observable state. Each domain
/// (find, scene routing, picker intents, sheets, pending URLs) lives
/// in its own focused @Observable type so a view that reads find
/// context doesn't re-render when an unrelated palette flag flips.
///
/// `AppStateBus.shared` is the single entry point; access state as
/// `AppStateBus.shared.find.context`, `…scenes.currentEditor`, etc.
/// Children are `var` (not `let`) so call sites can build writable
/// `Binding`s via key-path projection through @Bindable.
@MainActor
@Observable
final class AppStateBus: CommandContext {

    static let shared = AppStateBus()

    var find    = FindState()
    var scenes  = SceneRouter()
    var pickers = PickerIntents()
    var editing = EditingState()
    var pending = PendingURLs()

    private init() {}
}

/// Surface that `CommandActions` reads/writes when invoking a
/// command. In production it's the `AppStateBus.shared` singleton;
/// at test time a caller can swap in a stub via
/// `CommandActions.context = stub` to drive commands in isolation.
///
/// The protocol just re-exposes the existing sub-trees the bus
/// already owns — no new API surface; this is a seam for DI, not a
/// new architecture.
@MainActor
protocol CommandContext: AnyObject {
    var find: FindState     { get }
    var scenes: SceneRouter  { get }
    var pickers: PickerIntents { get }
    var editing: EditingState  { get }
    var pending: PendingURLs   { get }
}

// MARK: - Find

/// Persistent search options + one-shot UI toggles consumed by the
/// find/replace sheet. Mirrors the macOS "find pasteboard" so ⌘G and
/// ⌘⇧G keep working after the sheet is dismissed.
@MainActor
@Observable
final class FindState {
    var context = FindContext()

    /// One-shot toggles consumed by `FindReplaceSheet.onAppear` so the
    /// menu can request the sheet open with Replace expanded and/or
    /// in step-through (query) mode. The sheet clears them after
    /// reading.
    var pendingShowReplace = false
    var pendingQueryMode   = false
}

/// Persistent search options shared across the app.
struct FindContext: Equatable {
    var query: String = ""
    var replacement: String = ""
    var useRegex: Bool = false
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
}

// MARK: - Scene routing

/// Tracks the focused editor scene, the registry of open sessions,
/// and the bridges menu / UIKit code uses to open and route URLs to
/// new windows. SwiftUI's `@FocusedValue` doesn't propagate into the
/// editor engine's UIKit textview, so we keep our own pointers.
@MainActor
@Observable
final class SceneRouter {

    /// State of the most recently shown document scene. Cleared when
    /// the underlying `EditorState` is deallocated (weak ref).
    weak var currentEditor: EditorState?

    /// Tab session of the focused window. Re-bound on each scene
    /// `.active` transition so menu commands target the visible
    /// scene rather than the most recently appeared one.
    weak var currentSession: EditorSession?

    /// Bridge so non-View code (commands, the palette, UIKit
    /// delegates) can open named `WindowGroup` scenes. Installed by
    /// each editor scene's `onAppear`.
    var openWindowAction: ((SceneID) -> Void)?

    /// Bridge for "open this URL per the user's destination
    /// preference" — new window vs new tab. Installed by editor
    /// scenes; invoked from UIKit-level entry points like
    /// `DocumentPickerBridge` that don't have a session reference.
    var routeOpenURL: ((URL) -> Void)?

    /// Set when the home-screen quick action fires before any scene
    /// is mounted; consumed by the first scene to appear.
    var pendingShortcut: HomeShortcut?

    /// Tripped by the first scene to apply the launch-behaviour
    /// preference. Stops every subsequent scene's onAppear from
    /// firing the same action.
    var hasAppliedLaunchBehavior = false

    // MARK: Session registry

    /// Compacted on read — entries self-empty when their referent
    /// goes away, so we filter on each access.
    private var sessionRegistry: [WeakRef<EditorSession>] = []

    func registerSession(_ session: EditorSession) {
        sessionRegistry.removeAll { $0.ref == nil || $0.ref === session }
        sessionRegistry.append(WeakRef(session))
    }

    func deregisterSession(_ session: EditorSession) {
        sessionRegistry.removeAll { $0.ref == nil || $0.ref === session }
    }

    /// All currently-live sessions in insertion order. Read-only —
    /// dead slots are filtered out by `compactMap` (we don't prune
    /// the underlying array on read because that's a write inside
    /// a getter, which freezes SwiftUI bindings in a tight
    /// invalidation loop). Stale `WeakRef` slots accumulate up to
    /// the next `registerSession` / `deregisterSession` call, which
    /// is fine for an app that opens at most a handful of windows.
    var allOpenSessions: [EditorSession] {
        sessionRegistry.compactMap { $0.ref }
    }

    /// Locate the session that currently owns `tabID`. Used by the
    /// cross-window tab drag — drop destination on session B reads
    /// the dragged id and resolves it against session A.
    func session(containing tabID: UUID) -> EditorSession? {
        allOpenSessions.first { session in
            session.tabs.contains(where: { $0.id == tabID })
        }
    }

    // MARK: User-requested scene opens

    /// IDs of secondary WindowGroups the user has explicitly asked
    /// to open during this app launch. iOS doesn't expose
    /// `restorationBehavior(.disabled)`, so palette scenes that the
    /// system tries to restore would otherwise re-appear on cold
    /// launch. `requestOpenWindow(_:)` adds the id; the scene's
    /// `consumeOpen(_:)` removes it and reports whether the open was
    /// user-initiated.
    private var pendingPaletteOpens: Set<SceneID> = []

    func requestOpenWindow(_ id: SceneID) {
        pendingPaletteOpens.insert(id)
    }

    /// `true` when the matching `requestOpenWindow(_:)` was the
    /// reason this scene appeared; `false` when iPadOS restored it.
    func consumeOpen(_ id: SceneID) -> Bool {
        pendingPaletteOpens.remove(id) != nil
    }
}

// MARK: - Pickers

/// Mutually-exclusive file-picker intent driving the editor scene's
/// `.fileImporter` / `.fileExporter` modifiers via per-intent
/// bindings. Single optional > parallel booleans, both for state
/// integrity and for SwiftUI observation locality.
@MainActor
@Observable
final class PickerIntents {

    var pending: PickerIntent?

    /// SwiftUI Bool binding that presents the matching picker.
    /// Returns true iff `pending == intent`; setting false (dismiss
    /// callback) clears `pending` only if it still matches.
    func binding(for intent: PickerIntent) -> Binding<Bool> {
        Binding(
            get: { self.pending == intent },
            set: { presenting in
                if presenting {
                    self.pending = intent
                } else if self.pending == intent {
                    self.pending = nil
                }
            }
        )
    }
}

/// Pending file-picker intent surfaced by menu / palette commands.
enum PickerIntent: Equatable {
    case open
    case saveAs
    case insertFile
    case insertFolder
}

// MARK: - Editing surface

/// Sheet presentation, save callback, revert trigger, and surfaced
/// errors — the things the active editor scene exposes back to the
/// menu / palette layer.
@MainActor
@Observable
final class EditingState {

    /// Drives the sheet presentation in the active editor view.
    var presentedSheet: EditorSheet?

    /// `true` while the Safari-style tab switcher is on screen. Lives
    /// here (not on EditorScene) so menu / palette / toolbar buttons
    /// can toggle it without holding a scene reference. The active
    /// scene observes and runs the in-scene `matchedGeometryEffect`
    /// morph itself; the switcher is not a sheet.
    var tabSwitcherActive: Bool = false

    /// Saves the current file. Installed by the active scene's
    /// `EditorView.onAppear`; captured weakly so cleanup is
    /// automatic.
    var saveCurrentDocument: (() -> Void)?

    /// Incremented by the menu to ask the active scene to revert
    /// the in-memory buffer to whatever is on disk.
    var revertRequestCount: Int = 0

    /// Non-nil triggers an alert in the active editor — used to
    /// surface load / save failures.
    var openErrorMessage: String?

    /// Pending "close this tab — it has unsaved changes" prompt.
    /// EditorView observes and presents a confirmation dialog. Set
    /// by `CommandActions.requestCloseTab(_:)` when the close target
    /// has dirty / untitled content.
    var pendingClose: PendingClose?
}

/// One tab that's asking the user "should I really close?" before
/// we discard its buffer. The session id is captured so the dialog
/// targets the right window even if focus shifts before the user
/// taps a button.
@MainActor
struct PendingClose: Identifiable {
    let id = UUID()
    let sessionID: ObjectIdentifier
    let tabID: UUID
    let displayName: String
    let isUntitled: Bool
}

// MARK: - Pending URLs / targets

/// One-shot URL routing intents the editor scenes pick up via
/// `.onChange`. Distinct flavours: load-in-place (Revert,
/// pre-routed Multi-File-Search), seed-a-new-window (Open in new
/// window), and post-load goto-line (Multi-File-Search results).
@MainActor
@Observable
final class PendingURLs {

    /// Menu-driven request to load a URL into the *current* tab
    /// (e.g. from Revert). Different from `newWindow` which spawns
    /// a fresh scene.
    var openInPlace: URL?

    /// Set when "Open…" picks a file and the current scene already
    /// has a doc. A new editor window is requested via
    /// `openWindowAction(.editor)`; the freshly-spawned scene's
    /// onAppear consumes this URL on first appearance.
    var newWindow: URL?

    /// Line number a freshly-loaded document should jump to after
    /// its load Task commits text into `EditorState`. Set by
    /// Multi-File Search when the user taps a result row.
    var goToLine: Int?

    /// One-shot override for the next "Open…" routing. Set by the
    /// "Open in New Tab…" / "Open in New Window…" menu items so the
    /// user can pick the non-preferred destination without changing
    /// the persistent preference. Cleared by `DocumentDestination
    /// .current()` immediately after read.
    var nextOpenDestinationOverride: DocumentDestination?

    /// Tab detached from another session that's waiting to be
    /// adopted by the next fresh editor scene. Drives "Move Tab to
    /// New Window" — the source detaches, requests a new window via
    /// `openWindow(id: .editor)`, and the new scene's onAppear
    /// adopts this tab in place of its default blank one.
    var adoptedTab: TabModel?
}

// MARK: - Supporting types

/// Home-screen quick actions wired up in Info.plist via
/// `UIApplicationShortcutItems`. The `rawValue` matches the
/// `UIApplicationShortcutItemType` strings declared there.
enum HomeShortcut: String {
    case newFile        = "com.palefire.ayyyy.shortcut.newFile"
    case commandPalette = "com.palefire.ayyyy.shortcut.commandPalette"
}

/// Stable identifiers for every named `WindowGroup` in `AyyyyApp`.
/// Used in place of bare string literals at every `openWindow(id:)`
/// / `dismissWindow(id:)` / registry call site so a typo at a call
/// site stops compiling instead of silently no-op'ing at runtime.
enum SceneID: String {
    case editor
    case preferences
    case multiFileSearch = "multi-file-search"
    case fileBrowser     = "file-browser"
    case markdownPreview = "markdown-preview"
}

/// Where a freshly-opened document should land. The app-wide
/// preference is gone — the File menu carries explicit "Open in New
/// Tab…" / "Open in New Window…" entries that flip the destination
/// per-open. ⌘N / ⌘T do what they say regardless.
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

    /// Resolves the destination for the *next* open flow. iPhone is
    /// single-window by OS design and always returns `.tab`. iPad
    /// returns the one-shot override set by the "Open in New …" menu
    /// items, or `.window` as the default. The override is cleared
    /// in `EditorScene.route(open:)` once routing completes.
    /// `@MainActor` because it touches AppStateBus state.
    @MainActor
    static func current() -> DocumentDestination {
        if DeviceIdiom.isPhone { return .tab }
        return AppStateBus.shared.pending.nextOpenDestinationOverride ?? .window
    }
}

/// What a tab is currently showing. Mirrors Safari's "new tab page"
/// pattern — `.fileBrowser` means the tab hosts a
/// UIDocumentBrowserViewController inline; a pick transitions the
/// same tab back to `.editor` with the picked file loaded.
enum TabKind {
    case editor
    case fileBrowser
}

/// One tab in an editor window. Owns its own document and editor
/// state — `EditorView` reads both via plain references. Equatable
/// by identity so SwiftUI can match rows in the tab bar.
@MainActor
@Observable
final class TabModel: Identifiable {
    let id = UUID()
    let document: PlainTextDocument
    let state: EditorState
    /// Pinned tabs sort to the left of the strip, render as compact
    /// favicon-style chips, and survive "Close Other Tabs". Mirrors
    /// Safari's pin behaviour.
    var isPinned: Bool = false
    /// What the tab is currently rendering. Editor tabs use
    /// `document` + `state`; browser tabs ignore both until a pick
    /// transitions them back to editor.
    var kind: TabKind = .editor
    /// Lazily-created secondary state for split-view mode. Lives
    /// on the tab so split state is per-tab and the pane keeps its
    /// own cursor / scroll across split toggles.
    var secondaryState: EditorState?

    init() {
        self.document = PlainTextDocument()
        self.state = EditorState()
    }

    /// Get-or-create the secondary state used by the split pane.
    /// Seeds with the same view settings as the primary so both
    /// panes look identical to start.
    func ensureSecondaryState() -> EditorState {
        if let existing = secondaryState { return existing }
        let fresh = EditorState()
        fresh.text = state.text
        fresh.fileEncoding = state.fileEncoding
        fresh.lineEnding = state.lineEnding
        fresh.fileURL = state.fileURL
        fresh.languageIdentifier = state.languageIdentifier
        fresh.themeName = state.themeName
        fresh.font = state.font
        fresh.fontSize = state.fontSize
        fresh.showLineNumbers = state.showLineNumbers
        fresh.wrapLines = state.wrapLines
        fresh.savedBaselineText = state.savedBaselineText
        // Wire the bidirectional sibling links so the editor view's
        // coordinator can find the other pane's text view and push
        // per-keystroke deltas across without going through a
        // shared observable (which would re-render every observer).
        state.siblingState = fresh
        fresh.siblingState = state
        secondaryState = fresh
        return fresh
    }
}

extension TabModel: Equatable {
    nonisolated static func == (lhs: TabModel, rhs: TabModel) -> Bool {
        lhs === rhs
    }
}

/// Snapshot kept in `ClosedTabsStore.shared` so ⇧⌘T (and the
/// long-press menu on `+`) can resurrect a tab. URL-backed tabs
/// reopen via the standard load path; unsaved scratches restore from
/// the text snapshot taken at close time.
///
/// Codable so the store can persist the pool to UserDefaults — that
/// means a closed unsaved buffer survives the window closing AND a
/// full app relaunch, which is the safety net the user expects when
/// they think "I closed it but I didn't mean to."
struct ClosedTabRecord: Identifiable, Codable {
    let id: UUID
    let displayName: String
    let fileURL: URL?
    let unsavedSnapshot: String?
    let closedAt: Date

    init(id: UUID = UUID(),
         displayName: String,
         fileURL: URL?,
         unsavedSnapshot: String?,
         closedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.fileURL = fileURL
        self.unsavedSnapshot = unsavedSnapshot
        self.closedAt = closedAt
    }

    /// `true` for closures we want to highlight in recovery UI —
    /// untitled buffers with content the user could otherwise lose
    /// forever. Saved files have their bytes on disk; we don't gate
    /// the standard "Reopen Last Closed Tab" on this flag.
    var isUnsavedScratch: Bool {
        fileURL == nil && !(unsavedSnapshot ?? "").isEmpty
    }
}

/// App-wide persistent pool of closed-tab records. Replaces the
/// per-session ring buffer so closures survive window-close and app
/// relaunch. Capped to 25 to keep the storage payload modest.
@MainActor
@Observable
final class ClosedTabsStore {

    static let shared = ClosedTabsStore()
    private let cap = 25

    private(set) var records: [ClosedTabRecord]

    private init() {
        self.records = Self.load() ?? []
    }

    func record(_ entry: ClosedTabRecord) {
        records.insert(entry, at: 0)
        if records.count > cap {
            records.removeLast(records.count - cap)
        }
        save()
    }

    func popFirst() -> ClosedTabRecord? {
        guard !records.isEmpty else { return nil }
        let entry = records.removeFirst()
        save()
        return entry
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.closedTabRecords)
    }

    private static func load() -> [ClosedTabRecord]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.closedTabRecords),
              let decoded = try? JSONDecoder().decode([ClosedTabRecord].self, from: data)
        else { return nil }
        return decoded
    }
}

// MARK: - Drafts auto-save

/// Sidecar metadata persisted alongside each draft file. Optional
/// `sourceBookmark` reconnects the recovered buffer to the
/// originally-opened URL (for URL-backed dirty docs that hadn't
/// been saved when the window closed). Untitled drafts leave the
/// fields nil — they recover as fresh Untitled tabs.
struct DraftMetadata: Codable {
    /// Security-scoped bookmark for the source file URL. We round-
    /// trip through bookmarks rather than raw paths because file-
    /// provider locations (Nextcloud, iCloud) need explicit scope
    /// to re-open after relaunch.
    var sourceBookmark: Data?
    /// Display path for the recovery sheet's row (e.g. last 2-3
    /// path components). Falls back to "Untitled" when nil.
    var sourceDisplay: String?
    /// File encoding raw rawValue (UInt32, the `String.Encoding`
    /// raw representation). nil for untitled.
    var sourceEncodingRaw: UInt?
}

/// Per-document recoverable draft. Loaded from
/// `Documents/Drafts/<UUID>.txt` files (text body) plus an optional
/// sidecar `<UUID>.json` for URL-backed metadata. Each entry is one
/// separately-recoverable dirty buffer from a previous session.
struct DraftRecord: Identifiable {
    let id: UUID
    let url: URL
    let modified: Date
    let bytes: Int
    let preview: String
    /// `nil` → recovers as a fresh Untitled tab. Non-nil → recovers
    /// by re-opening the bookmarked source URL and applying the
    /// drafted text on top (marking the doc dirty so the user knows
    /// the on-disk file still has the old bytes).
    let metadata: DraftMetadata?
}

/// Mac-style autosave for every dirty buffer — untitled OR URL-
/// backed. Writes the live text to `Documents/Drafts/<UUID>.txt`
/// (plus optional `<UUID>.json` sidecar) so a system-gesture window
/// close (3-finger pinch, App Switcher swipe, Stage Manager close)
/// doesn't lose typed bytes regardless of whether the buffer ever
/// had a save location.
///
/// Why a separate directory + UUID-per-doc: each tab has its own
/// identity; two unrelated drafts must not stomp on each other's
/// bytes. The doc keeps a back-reference to its own draft file
/// (`PlainTextDocument.draftURL`) so subsequent autosaves overwrite
/// the SAME file in place — no orphan accumulation.
@MainActor
final class DraftsStore {

    static let shared = DraftsStore()

    /// Maximum drafts kept on disk. A new draft pushes out the
    /// oldest when this is exceeded. Keeps the recovery sheet a
    /// glance-readable list and prevents drifting forever past
    /// user attention. Six is enough to span a session's worth of
    /// experiments without becoming clutter.
    static let maxDrafts = 6

    /// `Documents/Drafts/` — created on first use. Visible to the
    /// user via Files (no `LSSupportsOpeningDocumentsInPlace` on the
    /// app means it's app-internal, but the user can still tap the
    /// recovery banner to recover any draft).
    let directory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = docs.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Write `text` to a draft file. Creates a new UUID-named file
    /// the first time, otherwise overwrites the existing one. When
    /// `metadata` is non-nil writes a JSON sidecar so the recovery
    /// path can re-open the source URL. Returns the text URL so the
    /// caller can stash it on `PlainTextDocument.draftURL` and route
    /// the next autosave to the same path.
    @discardableResult
    func save(text: String, existing: URL?, metadata: DraftMetadata? = nil) -> URL? {
        let url = existing ?? directory.appendingPathComponent("\(UUID().uuidString).txt")
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            if let metadata, let blob = try? JSONEncoder().encode(metadata) {
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                try? blob.write(to: sidecar, options: .atomic)
            } else {
                // No metadata = untitled. Strip a stale sidecar (the
                // doc may have been saved-to-disk then Reverted, or
                // the URL became invalid) so the recovery path
                // doesn't show a phantom "source" hint.
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                try? FileManager.default.removeItem(at: sidecar)
            }
            enforceCap(keeping: url)
            return url
        } catch {
            return nil
        }
    }

    /// FIFO eviction: when more than `maxDrafts` drafts exist on
    /// disk, drop the oldest until the count is back at the cap.
    /// `freshlySaved` is the URL the caller just wrote — protected
    /// from eviction even if it has an older mtime (e.g. an in-
    /// place overwrite that didn't bump `contentModificationDate`).
    private func enforceCap(keeping freshlySaved: URL) {
        let records = loadAll()
        guard records.count > Self.maxDrafts else { return }
        // `loadAll` returns newest-first; iterate from the END
        // (oldest) and discard until we're at the cap. Skip the
        // freshly-saved file so it's never the eviction victim.
        var toEvict = Array(records.reversed())
        var remaining = records.count
        while remaining > Self.maxDrafts, let oldest = toEvict.first {
            toEvict.removeFirst()
            if oldest.url.standardizedFileURL == freshlySaved.standardizedFileURL { continue }
            discard(oldest.url)
            remaining -= 1
        }
    }

    /// Delete a draft file (and its sidecar, if any). Called on
    /// Save-As — bytes now live at the user-chosen URL — and on
    /// Discard, where the user explicitly dropped them. Silent on
    /// failure: missing files are fine.
    func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    /// Enumerate every recoverable draft, newest first. Used by the
    /// launch-time recovery sheet. Empty drafts are filtered.
    func loadAll() -> [DraftRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var records: [DraftRecord] = []
        for url in urls {
            guard url.pathExtension == "txt" else { continue }
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = attrs?.contentModificationDate ?? .distantPast
            let bytes = attrs?.fileSize ?? 0
            guard bytes > 0 else { continue }
            let preview: String
            if let data = try? Data(contentsOf: url),
               let str = String(data: data.prefix(2_048), encoding: .utf8) {
                preview = String(str.prefix(80))
                    .replacingOccurrences(of: "\n", with: " ")
            } else {
                preview = ""
            }
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            let metadata: DraftMetadata?
            if let blob = try? Data(contentsOf: sidecar) {
                metadata = try? JSONDecoder().decode(DraftMetadata.self, from: blob)
            } else {
                metadata = nil
            }
            records.append(DraftRecord(
                id: id, url: url, modified: modified, bytes: bytes, preview: preview, metadata: metadata
            ))
        }
        records.sort { $0.modified > $1.modified }
        return records
    }
}

/// Per-window collection of tabs. The active tab's document and
/// state are what `EditorView` reads; modifiers on `EditorScene`
/// (file pickers, sheets, save, etc.) all target the active tab.
@MainActor
@Observable
final class EditorSession {
    var tabs: [TabModel]
    var selectedTabID: UUID
    /// Convenience view of the global closed-tabs pool — exposed on
    /// the session so existing call sites (TabSwitcherSheet's `+`
    /// long-press menu, TabBarView's drop list) keep their bindings
    /// without each having to reach into ClosedTabsStore directly.
    var recentlyClosed: [ClosedTabRecord] { ClosedTabsStore.shared.records }

    init() {
        let initial = TabModel()
        self.tabs = [initial]
        self.selectedTabID = initial.id
    }

    /// Returns the tab matching `selectedTabID`. Repairs the
    /// selection if it's drifted out of sync (assertion in debug;
    /// silently picks the first tab in release). Empties violate
    /// the closeTab invariant — that's a programmer error.
    var activeTab: TabModel {
        if let tab = tabs.first(where: { $0.id == selectedTabID }) { return tab }
        assertionFailure("selectedTabID \(selectedTabID) not in tabs — session is out of sync")
        guard let first = tabs.first else {
            preconditionFailure("EditorSession invariant violated: tabs is empty")
        }
        selectedTabID = first.id
        return first
    }

    @discardableResult
    func newTab() -> TabModel {
        let tab = TabModel()
        // Insert after the last pinned tab so unpinned newcomers
        // never push pins around. Mirrors Safari.
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
        return tab
    }

    /// "Open in New Tab" entry point: spawn a tab that renders the
    /// inline file browser instead of the editor. The pick callback
    /// (wired by `EditorScene`) flips its `kind` to `.editor` and
    /// loads the chosen URL into the same tab.
    @discardableResult
    func newFileBrowserTab() -> TabModel {
        let tab = newTab()
        tab.kind = .fileBrowser
        return tab
    }

    /// Whether closing a tab should also archive its content into
    /// `ClosedTabsStore` for "Reopen Last Closed Tab". `.archive` is
    /// the default (matches Safari behavior for tab × / ⌘W on a
    /// clean tab). `.discard` must be used by the unsaved-changes
    /// dialog's Discard path so the deliberately-thrown-away buffer
    /// can't be resurrected by ⇧⌘T.
    enum CloseDisposition {
        case archive
        case discard
    }

    func closeTab(_ id: UUID, disposition: CloseDisposition = .archive) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        // Never let the window go down to zero tabs — the caller is
        // expected to close the window when this returns `false`.
        guard tabs.count > 1 else { return false }
        let tab = tabs[idx]
        if disposition == .archive {
            recordClosure(of: tab)
        }
        let wasActive = (selectedTabID == id)
        tabs.remove(at: idx)
        if wasActive {
            selectedTabID = tabs[max(0, idx - 1)].id
        }
        return true
    }

    /// Close every tab except the one identified — but keep pinned
    /// tabs, matching Safari's "Close Other Tabs" semantics. Selection
    /// snaps to the pivot tab. Returns the count of tabs actually
    /// closed.
    @discardableResult
    func closeOtherTabs(except id: UUID) -> Int {
        let victims = tabs.filter { $0.id != id && !$0.isPinned }
        guard !victims.isEmpty else { return 0 }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims { recordClosure(of: tab) }
        tabs.removeAll { victimIDs.contains($0.id) }
        selectedTabID = id
        return victims.count
    }

    /// Close every tab strictly to the right of the given tab in the
    /// strip's visual order. Pinned tabs are exempt. Selection snaps
    /// to the pivot tab. Returns the count of tabs actually closed.
    @discardableResult
    func closeTabsToRight(of id: UUID) -> Int {
        guard let pivot = tabs.firstIndex(where: { $0.id == id }) else { return 0 }
        let victims = tabs[(pivot + 1)...].filter { !$0.isPinned }
        guard !victims.isEmpty else { return 0 }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims { recordClosure(of: tab) }
        tabs.removeAll { victimIDs.contains($0.id) }
        selectedTabID = id
        return victims.count
    }

    func selectNextTab() {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    /// Safari ⌘1–⌘9: jump to the 1-indexed tab. ⌘9 jumps to the
    /// last tab regardless of count (Safari quirk we mirror).
    func selectTab(at position: Int) {
        guard !tabs.isEmpty else { return }
        let idx = (position == 9) ? tabs.count - 1 : min(max(position - 1, 0), tabs.count - 1)
        selectedTabID = tabs[idx].id
    }

    /// Toggle pin state. Pinning moves the tab to the leftmost pinned
    /// position; unpinning moves it to the first unpinned position so
    /// the visual order matches the partitioned invariant.
    func togglePinned(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.isPinned.toggle()
        tabs.remove(at: idx)
        if tab.isPinned {
            // Append to end of the pinned block.
            tabs.insert(tab, at: tabs.partitionPointAfterPinned())
        } else {
            // Drop at the front of the unpinned block.
            tabs.insert(tab, at: tabs.partitionPointAfterPinned())
        }
    }

    /// Reorder via drag-and-drop. Clamps the destination so a pinned
    /// tab can't be dragged into the unpinned region (and vice versa)
    /// — keeps the partition invariant intact.
    func moveTab(id: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[from]
        let pinnedCount = tabs.partitionPointAfterPinned()
        // Legal range for `tab`'s drop destination in the final
        // array. Pinned tabs stay in [0, pinnedCount-1]; unpinned in
        // [pinnedCount, count-1].
        let lowerBound = tab.isPinned ? 0 : pinnedCount
        let upperBound = tab.isPinned ? max(0, pinnedCount - 1) : max(0, tabs.count - 1)
        let clamped = min(max(destination, lowerBound), upperBound)
        guard clamped != from else { return }
        tabs.remove(at: from)
        // Insertion index is the desired final position. SwiftUI's
        // partition guarantees the array invariant is preserved.
        tabs.insert(tab, at: min(clamped, tabs.count))
    }

    /// Pop the most-recently-closed record from the app-wide pool.
    /// Caller is responsible for re-opening the URL (or rehydrating
    /// the unsaved snapshot) — the session only stores the record.
    func popRecentlyClosed() -> ClosedTabRecord? {
        ClosedTabsStore.shared.popFirst()
    }

    /// Append a freshly-loaded URL-backed tab without changing the
    /// selection — used when "Open in Background" semantics are
    /// desired in future.
    func insertTab(_ tab: TabModel, activate: Bool = true) {
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        if activate { selectedTabID = tab.id }
    }

    /// Remove the given tab from this session and hand it back so the
    /// caller can re-home it (drag onto another window's tab bar, or
    /// spawn a new window). Returns nil if removing would empty the
    /// session — the session invariant requires ≥ 1 tab.
    func detachTab(_ id: UUID) -> TabModel? {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: idx)
        if selectedTabID == id {
            selectedTabID = tabs[max(0, idx - 1)].id
        }
        return tab
    }

    /// Adopt a tab detached from another session. Inserted just past
    /// the pinned block (matching `newTab`) and becomes active. Does
    /// NOT mutate the tab's identity — `id` stays stable across the
    /// move so subsequent drags resolve through `session(containing:)`.
    func attachTab(_ tab: TabModel) {
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
    }

    private func recordClosure(of tab: TabModel) {
        ClosedTabsStore.shared.record(Self.snapshotRecord(of: tab))
    }

    /// Build a closure record for a tab — extracted so the scene-
    /// close path can use it too (snapshotting every still-open
    /// tab when the window goes away).
    static func snapshotRecord(of tab: TabModel) -> ClosedTabRecord {
        // `document.text` lags the engine by up to 300 ms; for a
        // close that fires inside the debounce window we'd archive
        // the *pre-edit* text and silently lose whatever the user
        // typed last. Pull the live buffer when the engine view is
        // still around.
        let liveText = tab.state.textView?.text ?? tab.document.text
        return ClosedTabRecord(
            displayName: tab.document.fileURL?.lastPathComponent ?? "Untitled",
            fileURL: tab.document.fileURL,
            unsavedSnapshot: liveText.isEmpty ? nil : liveText
        )
    }
}

private extension Array where Element == TabModel {
    /// Index just past the last pinned tab — i.e. the insertion
    /// point that keeps `[pinned…, unpinned…]` partitioned. Touches
    /// main-actor state on TabModel, so the helper itself is hopped.
    @MainActor
    func partitionPointAfterPinned() -> Int {
        firstIndex(where: { !$0.isPinned }) ?? count
    }
}

/// Upper bound on file size for "rich" editing — syntax highlighting,
/// fold discovery, and the markdown inline decorator. Files over this
/// threshold open in plain-text mode for snappy typing.
///
/// `rawByteValue` is what's stored in `UserDefaults` so future schemes
/// (per-file overrides, custom thresholds) can co-exist with the enum.
/// Sentinel values: `-1` = unlimited (no skipping), `0` = never apply
/// rich editing.
enum SyntaxLimit: Int, CaseIterable, Identifiable {
    case never  = 0
    case up1MB  = 1_048_576
    case up5MB  = 5_242_880
    case up20MB = 20_971_520
    case always = -1

    var id: Int { rawValue }
    var rawByteValue: Int { rawValue }

    var label: String {
        switch self {
        case .never:  "Never (always plain text)"
        case .up1MB:  "Up to 1 MB"
        case .up5MB:  "Up to 5 MB"
        case .up20MB: "Up to 20 MB"
        case .always: "Always (may lag on huge files)"
        }
    }

    /// `true` if a file of `byteCount` bytes should get the rich
    /// editing treatment under this limit.
    func allows(byteCount: Int) -> Bool {
        switch self {
        case .never:  return false
        case .always: return true
        case .up1MB, .up5MB, .up20MB:
            return byteCount <= rawByteValue
        }
    }

    /// Reads the user's current choice from `UserDefaults`. Unknown
    /// stored values (forward-compat) fall back to `.up5MB`.
    static func current() -> SyntaxLimit {
        let stored = UserDefaults.standard.integer(forKey: AppPreferenceKey.syntaxLimitBytes)
        return SyntaxLimit(rawValue: stored) ?? .up5MB
    }
}

/// What the app does on a fresh launch when SwiftUI didn't restore any
/// prior windows. Restoration always wins when available.
enum LaunchBehavior: String, CaseIterable {
    case newBlank   = "newBlank"
    case openPicker = "openPicker"

    var displayName: String {
        switch self {
        case .newBlank:   "New blank document"
        case .openPicker: "Show file picker"
        }
    }
}

/// Reusable weak reference box. Used by `SceneRouter` to keep a list
/// of open sessions without retaining them.
@MainActor
final class WeakRef<T: AnyObject> {
    weak var ref: T?
    init(_ ref: T?) { self.ref = ref }
}
