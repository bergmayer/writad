import Foundation

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

/// One window's restorable tab list. Keyed by the scene's
/// `@SceneStorage` UUID so SwiftUI's scene restoration drives which
/// records get applied.
struct SessionRecord: Codable {
    let sceneUUID: String
    var tabs: [TabSnapshot]
    var activeIndex: Int
    var lastModified: Date
}

/// Records on disk (UserDefaults `sessionRecords`). The actual draft
/// bytes live in `DraftsStore`'s files; this layer just remembers
/// which window owned which tabs and which files they had open.
@MainActor
final class SessionsStore {

    static let shared = SessionsStore()

    /// Cap on stored records — orphaned records (scenes the user
    /// closed) sit here until evicted by newer writes.
    private let cap = 20

    private(set) var records: [SessionRecord]

    private init() {
        self.records = Self.load() ?? []
    }

    func record(forScene sceneUUID: String) -> SessionRecord? {
        records.first { $0.sceneUUID == sceneUUID }
    }

    func save(_ record: SessionRecord) {
        records.removeAll { $0.sceneUUID == record.sceneUUID }
        records.insert(record, at: 0)
        if records.count > cap {
            records.removeLast(records.count - cap)
        }
        persist()
    }

    func remove(forScene sceneUUID: String) {
        records.removeAll { $0.sceneUUID == sceneUUID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.sessionRecords)
    }

    private static func load() -> [SessionRecord]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.sessionRecords),
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
