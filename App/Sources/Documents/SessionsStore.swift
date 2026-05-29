import SwiftUI
import UIKit

/// One tab's restorable state. Bookmark, not raw URL — File Provider
/// locations (Nextcloud, iCloud) need explicit scope to re-open after
/// relaunch.
struct TabSnapshot: Codable {
    var fileBookmark: Data?
    /// Filename within `DraftsStore.directory`; relative because the
    /// Documents base path changes on reinstall.
    var draftFilename: String?
    var isPinned: Bool
}

/// One window's restorable tab list. `launchID` tags every record
/// saved during a single app run so the next launch can identify
/// "windows open at last quit" — records from earlier launches still
/// sit in the store as dormant history until the cap evicts them.
/// `persistentIdentifier` is iPadOS's `UISceneSession.persistentIdentifier`
/// captured at scene register time — the AppDelegate's
/// `configurationForConnecting` uses it to correlate a cold-launch
/// scene back to its record. No record == iPadOS ghost (user swiped
/// or explicitly closed); a matching record means "involuntary kill,
/// the user wants this back."
struct SessionRecord: Codable {
    let sceneUUID: String
    var tabs: [TabSnapshot]
    var activeIndex: Int
    var lastModified: Date
    var launchID: String
    var persistentIdentifier: String?
}

/// Records on disk (UserDefaults `sessionRecords`). The actual draft
/// bytes live in `DraftsStore`'s files; this layer just remembers
/// which window owned which tabs and which files they had open.
///
/// SwiftUI on iOS only restores one `WindowGroup` scene by default,
/// so the user's other windows would be lost. The launch-id grouping
/// + pending-restore queue let the first scene proactively spawn
/// extras (`openWindow(id:)`) to cover every record from the
/// previous launch.
@MainActor
final class SessionsStore {

    static let shared = SessionsStore()

    /// Cap on stored records — old launch groups sit here until
    /// evicted by newer writes.
    static let cap = 60

    /// Tests pass an isolated UserDefaults suite and skip the global
    /// UIScene observer; production wires both to standard.
    private let defaults: UserDefaults

    private(set) var records: [SessionRecord]

    /// Fresh per app launch. Saves tag records with this so the next
    /// launch can identify the "most recent" group.
    let currentLaunchID = UUID().uuidString

    /// FIFO queue of records waiting to be applied to scenes. Seeded
    /// once per launch by `initiateRestoreSweep()`; each scene's
    /// `onAppear` pops one entry.
    private var pendingRestores: [SessionRecord] = []

    /// Trips on the first call to `initiateRestoreSweep()` so only
    /// one scene seeds the queue.
    private(set) var hasInitiatedRestore = false

    /// Maps a live `UIScene`'s object identity to the `sceneUUID`
    /// of its `SessionRecord`. Populated by `register(_:sceneUUID:)`
    /// from `EditorScene`; the `didDisconnectNotification` observer
    /// uses it to evict records when the user closes a window.
    private var sceneUUIDsByObjectIdentifier: [ObjectIdentifier: String] = [:]

    /// Mirror map from our `sceneUUID` to iPadOS's
    /// `UISceneSession.persistentIdentifier`. Saved into each
    /// `SessionRecord` at persist time so the AppDelegate can
    /// correlate a cold-launch scene to our record.
    private var persistentIdsByUUID: [String: String] = [:]

    init(defaults: UserDefaults = .standard, observesScenes: Bool = true) {
        self.defaults = defaults
        self.records = Self.load(from: defaults) ?? []
        guard observesScenes else { return }
        // `for await note in …` delivers each notification already on
        // this Task's @MainActor context, sidestepping the Sendable-
        // capture warnings from the older `addObserver(forName:…)`
        // closure-based API. `Notification`'s `object`/`userInfo` are
        // non-Sendable, so the closure form couldn't legally read
        // `scene.session` (main-actor-isolated) under Swift 6 strict
        // concurrency.
        sceneDisconnectTask = Task { @MainActor [weak self] in
            let stream = NotificationCenter.default.notifications(
                named: UIScene.didDisconnectNotification
            )
            for await note in stream {
                guard let self,
                      let scene = note.object as? UIScene
                else { continue }
                let key = ObjectIdentifier(scene)
                if let sceneUUID = self.sceneUUIDsByObjectIdentifier.removeValue(forKey: key) {
                    self.remove(forScene: sceneUUID)
                }
                // Tell iPadOS to fully discard the session, not just
                // disconnect it. Without this, every closed window
                // accumulates in `UIApplication.shared.openSessions`
                // and shows up in iPadOS's "N hidden windows" toast
                // on next launch. Drafts were already flushed by
                // `scenePhase` → `.background` and `.onDisappear`,
                // so there's no data loss — the launcher's Drafts
                // section is our recently-closed UI.
                UIApplication.shared.requestSceneSessionDestruction(
                    scene.session,
                    options: nil,
                    errorHandler: nil
                )
            }
        }
    }

    /// Cancels the scene-disconnect observation on dealloc — without
    /// this the Task would outlive the singleton in test injection.
    deinit {
        sceneDisconnectTask?.cancel()
    }

    private var sceneDisconnectTask: Task<Void, Never>?

    /// Called by `EditorScene` once it has both a `sceneUUID` and a
    /// live `UIWindowScene`. The disconnect observer above uses this
    /// mapping to evict the record when the user closes the window.
    /// Idempotent — repeat calls with the same arguments are no-ops.
    func register(_ scene: UIScene, sceneUUID: String) {
        sceneUUIDsByObjectIdentifier[ObjectIdentifier(scene)] = sceneUUID
        persistentIdsByUUID[sceneUUID] = scene.session.persistentIdentifier
    }

    /// Looked up by `SessionRecord.init(scene:session:)` so the
    /// record carries the iPadOS session id forward across launches.
    func persistentIdentifier(forSceneUUID uuid: String) -> String? {
        persistentIdsByUUID[uuid]
    }

    /// `true` if any prior-launch record claims this iPadOS session.
    /// AppDelegate's `configurationForConnecting` uses it to decide
    /// whether a restoring session is one we want back or an iPadOS
    /// ghost to destroy.
    func hasRecord(forPersistentIdentifier id: String) -> Bool {
        records.contains { $0.persistentIdentifier == id }
    }

    /// Drop any record claiming this persistent identifier. Used
    /// from `application(_:didDiscardSceneSessions:)` so iOS-level
    /// discards (user swiped a window away in the App Switcher
    /// while the app was running) mirror into our store.
    func removeRecord(forPersistentIdentifier id: String) {
        records.removeAll { $0.persistentIdentifier == id }
        persist()
    }

    /// One-shot cleanup of orphaned `UISceneSession`s — the ones
    /// iPadOS keeps after a user dismisses a window via Stage
    /// Manager / App Switcher and that show up as "N hidden
    /// windows" on next launch. By the time this fires (cold-launch
    /// first scene `.active`), the system has already decided which
    /// sessions to reconnect; any session in `openSessions` whose
    /// `scene` is nil is genuinely orphaned. Drafts are already
    /// safe on disk from the prior `.background` / `.onDisappear`
    /// flush, so the launcher's Drafts section is the recovery
    /// surface. Guarded by `hasPurgedHiddenSessions` so it runs
    /// once per launch.
    private var hasPurgedHiddenSessions = false
    func purgeHiddenSessions() {
        guard !hasPurgedHiddenSessions else { return }
        hasPurgedHiddenSessions = true
        let app = UIApplication.shared
        let liveScenes = Set(app.connectedScenes.map { ObjectIdentifier($0) })
        for session in app.openSessions {
            // A session whose scene is in `connectedScenes` is the
            // window the user just opened — leave it alone.
            if let scene = session.scene, liveScenes.contains(ObjectIdentifier(scene)) {
                continue
            }
            app.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
        }
    }

    /// First scene to call this seeds `pendingRestores` from the
    /// previous launch's records and returns the count. Subsequent
    /// callers receive `0`.
    @discardableResult
    func initiateRestoreSweep() -> Int {
        guard !hasInitiatedRestore else { return 0 }
        hasInitiatedRestore = true
        let toRestore = recordsFromPreviousLaunch()
        pendingRestores = toRestore
        return toRestore.count
    }

    func consumePendingRestore() -> SessionRecord? {
        pendingRestores.isEmpty ? nil : pendingRestores.removeFirst()
    }

    /// Records sharing the most recent prior-launch `launchID`,
    /// oldest-first. Returns `[]` when there's nothing to restore.
    /// Used by `applySessionRestoreIfNeeded` to re-open windows
    /// that were alive at the prior involuntary kill (OOM, reboot).
    /// User-initiated closes remove their records before this point
    /// either via the `didDisconnectNotification` handler (in-app
    /// close) or `didDiscardSceneSessions` (App Switcher swipe), so
    /// only "the user didn't mean to lose this" records survive.
    private func recordsFromPreviousLaunch() -> [SessionRecord] {
        let priorRecords = records.filter { $0.launchID != currentLaunchID }
        guard let mostRecent = priorRecords.max(by: { $0.lastModified < $1.lastModified }) else {
            return []
        }
        return priorRecords
            .filter { $0.launchID == mostRecent.launchID }
            .sorted { $0.lastModified < $1.lastModified }
    }

    func record(forScene sceneUUID: String) -> SessionRecord? {
        records.first { $0.sceneUUID == sceneUUID }
    }

    func save(_ record: SessionRecord) {
        records.removeAll { $0.sceneUUID == record.sceneUUID }
        records.insert(record, at: 0)
        if records.count > Self.cap {
            records.removeLast(records.count - Self.cap)
        }
        persist()
    }

    func remove(forScene sceneUUID: String) {
        records.removeAll { $0.sceneUUID == sceneUUID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: AppPreferenceKey.sessionRecords)
    }

    private static func load(from defaults: UserDefaults) -> [SessionRecord]? {
        guard let data = defaults.data(forKey: AppPreferenceKey.sessionRecords),
              let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data)
        else { return nil }
        return decoded
    }
}

extension TabSnapshot {
    @MainActor
    init(of tab: TabModel) {
        self.isPinned = tab.isPinned
        if let url = tab.document.fileURL {
            self.fileBookmark = try? url.bookmarkData(options: .minimalBookmark)
        }
        if let draft = tab.document.draftURL {
            self.draftFilename = draft.lastPathComponent
        }
    }
}

extension SessionRecord {
    @MainActor
    init(scene sceneUUID: String, session: EditorSession) {
        self.sceneUUID = sceneUUID
        self.tabs = session.tabs.map(TabSnapshot.init(of:))
        self.activeIndex = session.tabs.firstIndex { $0.id == session.selectedTabID } ?? 0
        self.lastModified = Date()
        self.launchID = SessionsStore.shared.currentLaunchID
        self.persistentIdentifier = SessionsStore.shared.persistentIdentifier(forSceneUUID: sceneUUID)
    }
}

/// Applies a `SessionRecord` to a freshly-created `EditorSession`.
/// File loads kick off as async tasks so a hung File Provider doesn't
/// block the scene from showing.
@MainActor
enum SessionRestore {

    static func apply(_ record: SessionRecord, to session: EditorSession) {
        guard !record.tabs.isEmpty else { return }
        var restored: [TabModel] = []
        for snapshot in record.tabs {
            let tab = TabModel()
            tab.isPinned = snapshot.isPinned
            populate(tab, from: snapshot)
            restored.append(tab)
        }
        session.tabs = restored
        let idx = min(max(record.activeIndex, 0), restored.count - 1)
        session.selectedTabID = restored[idx].id
    }

    private static func populate(_ tab: TabModel, from snapshot: TabSnapshot) {
        // Read draft bytes first — used as the dirty buffer when the
        // tab was unsaved at last quit, on top of disk content for
        // URL-backed dirty tabs.
        var draftText: String?
        if let draftFilename = snapshot.draftFilename {
            let draftURL = DraftsStore.shared.directory
                .appendingPathComponent(draftFilename)
            draftText = (try? String(contentsOf: draftURL, encoding: .utf8))
                ?? (try? String(contentsOf: draftURL, encoding: .isoLatin1))
            tab.document.draftURL = draftURL
        }

        if let bookmark = snapshot.fileBookmark, let resolved = resolveBookmark(bookmark) {
            tab.document.fileURL = resolved.url
            tab.state.fileURL = resolved.url
            tab.state.languageIdentifier = LanguageRegistry.identifier(for: resolved.url)
            // Show the draft (if any) immediately so the engine has
            // bytes to paint while the disk load resolves.
            if let draftText {
                tab.document.text = draftText
                tab.document.isDirty = true
                tab.state.text = draftText
            }
            tab.state.loadTask = Task { @MainActor [weak tab] in
                guard let tab else { return }
                defer { tab.state.loadTask = nil }
                do {
                    try await tab.document.loadAsync(from: resolved.url)
                } catch {
                    return
                }
                if let draftText {
                    // Disk content is the baseline; drafted text wins
                    // for the live buffer.
                    tab.state.savedBaselineText = tab.document.text
                    tab.document.text = draftText
                    tab.document.isDirty = true
                    tab.state.text = draftText
                    tab.state.fileEncoding = tab.document.fileEncoding
                    tab.state.lineEnding = tab.document.lineEnding
                } else {
                    tab.state.text = tab.document.text
                    tab.state.savedBaselineText = tab.document.text
                    tab.state.fileEncoding = tab.document.fileEncoding
                    tab.state.lineEnding = tab.document.lineEnding
                }
            }
        } else if let draftText {
            // Untitled draft: bytes load into the fresh tab; dirty so
            // the "edited" subtitle stays on until the user saves.
            tab.document.text = draftText
            tab.document.isDirty = true
            tab.state.text = draftText
        }
    }

    private static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return (url, stale)
    }
}

/// Bridges `view.window?.windowScene` back into SwiftUI so
/// `EditorScene` can hand its `UIWindowScene` to `SessionsStore`
/// for close-detection. SwiftUI doesn't expose the host scene on
/// iOS, hence the UIKit dip.
struct SceneRegistrationBridge: UIViewRepresentable {

    let sceneUUID: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // sceneUUID starts empty, becomes non-empty on the first
        // `onAppear` once `applySessionRestoreIfNeeded` runs. The
        // dispatch hops past this render so `view.window` is wired.
        let uuid = sceneUUID
        guard !uuid.isEmpty else { return }
        DispatchQueue.main.async {
            guard let scene = uiView.window?.windowScene else { return }
            SessionsStore.shared.register(scene, sceneUUID: uuid)
        }
    }
}
