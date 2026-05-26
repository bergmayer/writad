import SwiftUI

/// Shared @Observable state, split per domain so a view that reads
/// find context doesn't re-render when an unrelated palette flag
/// flips. Children are `var` so call sites can build writable
/// `Binding`s through @Bindable.
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

/// DI seam for `CommandActions`. Production passes the bus; tests
/// swap in a stub via `CommandActions.context = stub`.
@MainActor
protocol CommandContext: AnyObject {
    var find: FindState     { get }
    var scenes: SceneRouter  { get }
    var pickers: PickerIntents { get }
    var editing: EditingState  { get }
    var pending: PendingURLs   { get }
}

// MARK: - Find

/// Mirrors macOS's find pasteboard so ⌘G / ⌘⇧G keep working after
/// the sheet is dismissed.
@MainActor
@Observable
final class FindState {
    var context = FindContext()

    /// One-shot toggles cleared by `FindReplaceSheet.onAppear` after
    /// reading. Let menu items request the sheet with Replace
    /// expanded or in step-through mode.
    var pendingShowReplace = false
    var pendingQueryMode   = false
}

struct FindContext: Equatable {
    var query: String = ""
    var replacement: String = ""
    var useRegex: Bool = false
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
}

// MARK: - Scene routing

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

// MARK: - Pickers

/// One pending picker at a time — a single optional, not a flag per
/// intent, so two pickers can never both think they're presenting.
@MainActor
@Observable
final class PickerIntents {

    var pending: PickerIntent?

    /// True iff `pending == intent`. Dismissing only clears the
    /// pending intent if it still matches — guards against a stale
    /// dismiss from a previous picker stomping on a newer one.
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

enum PickerIntent: Equatable {
    case open
    case saveAs
    case insertFile
    case insertFolder
}

// MARK: - Editing surface

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

// MARK: - Pending URLs / targets

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

// MARK: - Supporting types

/// `rawValue` must match the `UIApplicationShortcutItemType` strings
/// declared in Info.plist under `UIApplicationShortcutItems`.
enum HomeShortcut: String {
    case newFile        = "com.palefire.ayyyy.shortcut.newFile"
    case commandPalette = "com.palefire.ayyyy.shortcut.commandPalette"
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

/// `.fileBrowser` hosts a UIDocumentBrowserViewController inline;
/// a pick transitions the tab back to `.editor` with the file loaded.
enum TabKind {
    case editor
    case fileBrowser
}

/// Equatable by identity so SwiftUI can match rows in the tab bar.
@MainActor
@Observable
final class TabModel: Identifiable {
    let id = UUID()
    let document: PlainTextDocument
    let state: EditorState
    /// Pinned tabs sort left, render as compact chips, and survive
    /// "Close Other Tabs" — mirrors Safari.
    var isPinned: Bool = false
    var kind: TabKind = .editor
    /// Per-tab so split state isn't shared between tabs — each pane
    /// keeps its own cursor / scroll across split toggles.
    var secondaryState: EditorState?

    init() {
        self.document = PlainTextDocument()
        self.state = EditorState()
    }

    /// Seeds the split pane with the same view settings as the
    /// primary so both panes start identical.
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
        // Bidirectional sibling links so each coordinator can find
        // the other pane's text view directly — pushing deltas
        // through a shared observable would re-render every observer.
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

/// Codable + persisted to UserDefaults so a closed unsaved buffer
/// survives both the window close AND a full app relaunch — the
/// safety net the user expects when they think "I closed it but I
/// didn't mean to."
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

    /// Untitled buffers with content — the ones the user could
    /// otherwise lose forever, worth highlighting in recovery UI.
    /// "Reopen Last Closed Tab" doesn't gate on this.
    var isUnsavedScratch: Bool {
        fileURL == nil && !(unsavedSnapshot ?? "").isEmpty
    }
}

/// App-wide pool persisted to UserDefaults. Replaces the old per-
/// session ring buffer so closures survive window-close and relaunch.
/// Capped at 25 — modest storage payload.
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

/// Sidecar JSON next to each draft .txt. Untitled drafts leave the
/// fields nil and recover as fresh Untitled tabs.
struct DraftMetadata: Codable {
    /// Security-scoped bookmark, not a raw path: file-provider
    /// locations (Nextcloud, iCloud) need explicit scope to re-open
    /// after relaunch.
    var sourceBookmark: Data?
    /// Last 2-3 path components for the recovery row.
    var sourceDisplay: String?
    /// `String.Encoding.rawValue`. nil for untitled.
    var sourceEncodingRaw: UInt?
}

/// One recoverable dirty buffer from a previous session.
/// `Documents/Drafts/<UUID>.txt` + optional `<UUID>.json` sidecar.
struct DraftRecord: Identifiable {
    let id: UUID
    let url: URL
    let modified: Date
    let bytes: Int
    let preview: String
    /// `nil` → recovers as Untitled. Non-nil → re-opens the
    /// bookmarked URL and applies drafted text on top, marking
    /// the doc dirty so the user knows disk still has the old bytes.
    let metadata: DraftMetadata?
}

/// Mac-style autosave for every dirty buffer. Writes live text to
/// `Documents/Drafts/<UUID>.txt` so a system-gesture close
/// (3-finger pinch, App Switcher swipe, Stage Manager close) can't
/// lose typed bytes, with or without a save location.
///
/// UUID-per-doc + back-reference on `PlainTextDocument.draftURL` so
/// repeat autosaves overwrite the same file — no orphan accumulation.
@MainActor
final class DraftsStore {

    static let shared = DraftsStore()

    /// Six is enough to span a session's worth of experiments
    /// without becoming clutter. New pushes oldest out — the sheet
    /// stays glance-readable.
    static let maxDrafts = 6

    let directory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = docs.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Creates a new UUID-named file on first write, overwrites in
    /// place after that. The returned URL is what the caller should
    /// stash on `PlainTextDocument.draftURL` so the next autosave
    /// hits the same path.
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
                // Strip any stale sidecar — the doc may have been
                // saved-then-reverted, in which case a leftover
                // sidecar would surface a phantom "source" hint.
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                try? FileManager.default.removeItem(at: sidecar)
            }
            enforceCap(keeping: url)
            return url
        } catch {
            return nil
        }
    }

    /// FIFO eviction. `freshlySaved` is exempt even if its mtime
    /// is older — an in-place overwrite doesn't always bump
    /// `contentModificationDate`, and we don't want to evict the
    /// caller's brand-new write.
    private func enforceCap(keeping freshlySaved: URL) {
        let records = loadAll()
        guard records.count > Self.maxDrafts else { return }
        var toEvict = Array(records.reversed())
        var remaining = records.count
        while remaining > Self.maxDrafts, let oldest = toEvict.first {
            toEvict.removeFirst()
            if oldest.url.standardizedFileURL == freshlySaved.standardizedFileURL { continue }
            discard(oldest.url)
            remaining -= 1
        }
    }

    /// Missing files are fine — Save-As and Discard both call here
    /// without knowing whether the draft was ever written.
    func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    /// Every recoverable draft, newest first, empties filtered.
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

/// Per-window collection of tabs. Modifiers on `EditorScene` all
/// target the active tab.
@MainActor
@Observable
final class EditorSession {
    var tabs: [TabModel]
    var selectedTabID: UUID
    /// View of the global pool, surfaced on the session so existing
    /// call sites don't need to reach into `ClosedTabsStore` directly.
    var recentlyClosed: [ClosedTabRecord] { ClosedTabsStore.shared.records }

    init() {
        let initial = TabModel()
        self.tabs = [initial]
        self.selectedTabID = initial.id
    }

    /// Self-repairs a drifted selection; an empty `tabs` is a
    /// programmer error (close-tab invariant).
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
        // Drop after the last pinned tab so newcomers don't shove
        // pins around — Safari rule.
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
        return tab
    }

    /// "Open in New Tab" entry point. The pick callback flips kind
    /// back to `.editor` and loads the chosen URL into the same tab.
    @discardableResult
    func newFileBrowserTab() -> TabModel {
        let tab = newTab()
        tab.kind = .fileBrowser
        return tab
    }

    /// `.discard` is required from the unsaved-changes dialog's
    /// Discard path so a deliberately-thrown-away buffer can't be
    /// resurrected by ⇧⌘T.
    enum CloseDisposition {
        case archive
        case discard
    }

    func closeTab(_ id: UUID, disposition: CloseDisposition = .archive) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        // Caller is expected to close the window when this returns
        // false — never let `tabs` go to zero.
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

    /// Keeps pinned tabs — Safari semantics. Selection snaps to the
    /// pivot. Returns count of tabs closed.
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

    /// Pinned tabs are exempt. Selection snaps to the pivot.
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

    /// Safari quirk: ⌘9 jumps to the last tab regardless of count.
    func selectTab(at position: Int) {
        guard !tabs.isEmpty else { return }
        let idx = (position == 9) ? tabs.count - 1 : min(max(position - 1, 0), tabs.count - 1)
        selectedTabID = tabs[idx].id
    }

    /// Pinning re-homes the tab so the `[pinned…, unpinned…]`
    /// partition invariant stays intact.
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

    /// Drag-and-drop reorder. Clamps so a pinned tab can't cross
    /// into the unpinned region (or vice versa) — partition stays
    /// intact.
    func moveTab(id: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[from]
        let pinnedCount = tabs.partitionPointAfterPinned()
        // Pinned: [0, pinnedCount-1]. Unpinned: [pinnedCount, count-1].
        let lowerBound = tab.isPinned ? 0 : pinnedCount
        let upperBound = tab.isPinned ? max(0, pinnedCount - 1) : max(0, tabs.count - 1)
        let clamped = min(max(destination, lowerBound), upperBound)
        guard clamped != from else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(clamped, tabs.count))
    }

    func popRecentlyClosed() -> ClosedTabRecord? {
        ClosedTabsStore.shared.popFirst()
    }

    /// Appends a tab without claiming focus — placeholder for an
    /// eventual "Open in Background" gesture.
    func insertTab(_ tab: TabModel, activate: Bool = true) {
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        if activate { selectedTabID = tab.id }
    }

    /// Hands the tab back so the caller can re-home it (cross-window
    /// drag, new window). Returns nil if removing would violate the
    /// ≥ 1 tab invariant.
    func detachTab(_ id: UUID) -> TabModel? {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: idx)
        if selectedTabID == id {
            selectedTabID = tabs[max(0, idx - 1)].id
        }
        return tab
    }

    /// Adopt a detached tab. `id` is preserved so subsequent drags
    /// resolve through `session(containing:)`.
    func attachTab(_ tab: TabModel) {
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
    }

    private func recordClosure(of tab: TabModel) {
        ClosedTabsStore.shared.record(Self.snapshotRecord(of: tab))
    }

    /// Shared by the scene-close path, which snapshots every still-
    /// open tab when the window goes away.
    static func snapshotRecord(of tab: TabModel) -> ClosedTabRecord {
        // `document.text` lags the engine by ~300 ms — pull the
        // live buffer when the engine view is still around, or a
        // close inside the debounce window archives pre-edit text.
        let liveText = tab.state.textView?.text ?? tab.document.text
        return ClosedTabRecord(
            displayName: tab.document.fileURL?.lastPathComponent ?? "Untitled",
            fileURL: tab.document.fileURL,
            unsavedSnapshot: liveText.isEmpty ? nil : liveText
        )
    }
}

private extension Array where Element == TabModel {
    /// Insertion point that keeps `[pinned…, unpinned…]` partitioned.
    @MainActor
    func partitionPointAfterPinned() -> Int {
        firstIndex(where: { !$0.isPinned }) ?? count
    }
}

/// Upper byte-size for syntax highlighting, fold discovery, and
/// the markdown inline decorator. Files over the limit open in
/// plain-text mode. Sentinels: `-1` = unlimited, `0` = never.
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

    func allows(byteCount: Int) -> Bool {
        switch self {
        case .never:  return false
        case .always: return true
        case .up1MB, .up5MB, .up20MB:
            return byteCount <= rawByteValue
        }
    }

    /// Unknown stored values (forward-compat) fall back to `.up5MB`.
    static func current() -> SyntaxLimit {
        let stored = UserDefaults.standard.integer(forKey: AppPreferenceKey.syntaxLimitBytes)
        return SyntaxLimit(rawValue: stored) ?? .up5MB
    }
}

/// Cold-launch behaviour. SwiftUI restoration always wins when
/// it has a prior window to bring back.
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

@MainActor
final class WeakRef<T: AnyObject> {
    weak var ref: T?
    init(_ ref: T?) { self.ref = ref }
}
