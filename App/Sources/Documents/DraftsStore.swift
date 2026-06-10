import Foundation

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
    /// Disk state of the source at the moment the draft was last
    /// written. The launcher's adoption path re-reads disk mtime/
    /// size and compares — if either differs (or the file's gone)
    /// the user gets a missing / changed dialog before the buffer
    /// becomes editable. Cheaper than a content hash and good
    /// enough to catch the "someone else wrote it" race.
    var sourceMtime: Date?
    var sourceSize: Int?
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

    /// Tests pass an isolated temp directory here; production leaves it
    /// nil and we resolve through `UbiquityContainer` so the iCloud /
    /// local pick follows the live Settings toggle.
    private let rootOverride: URL?

    /// Draft filenames the cap must never evict. Defaults to every
    /// draft referenced by a persisted session record: when several
    /// dirty tabs commit drafts on backgrounding, FIFO eviction would
    /// otherwise delete drafts just written for other still-open tabs
    /// — permanent data loss on restore. Injectable for tests.
    private let protectedDraftFilenames: @MainActor () -> Set<String>

    init(
        rootOverride: URL? = nil,
        protectedDraftFilenames: (@MainActor () -> Set<String>)? = nil
    ) {
        self.rootOverride = rootOverride
        self.protectedDraftFilenames = protectedDraftFilenames ?? {
            Set(SessionsStore.shared.records.flatMap { record in
                record.tabs.compactMap(\.draftFilename)
            })
        }
        // Eagerly ensure draft directories exist so first-write doesn't
        // race with directory creation when the user toggles iCloud
        // mid-session.
        for root in roots {
            let dir = root.appendingPathComponent("Drafts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Where new drafts get written. Resolved on access so a Settings
    /// toggle of "Sync via iCloud Drive" takes effect immediately
    /// without needing a relaunch.
    var directory: URL {
        let root = rootOverride ?? UbiquityContainer.documentsURLForWrite
        let dir = root.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every root the launcher should consider when listing drafts —
    /// iCloud + local. Reading from both means flipping the sync
    /// toggle never hides existing files; the user's old iCloud
    /// drafts stay browseable even after going local-only.
    var readDirectories: [URL] {
        roots.map { root in
            let dir = root.appendingPathComponent("Drafts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    private var roots: [URL] {
        if let rootOverride { return [rootOverride] }
        return UbiquityContainer.documentsRootsForRead
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
    /// caller's brand-new write. Drafts referenced by a persisted
    /// session record are exempt too.
    private func enforceCap(keeping freshlySaved: URL) {
        let records = loadAll()
        guard records.count > Self.maxDrafts else { return }
        let protected = protectedDraftFilenames()
        var toEvict = Array(records.reversed())
        var remaining = records.count
        while remaining > Self.maxDrafts, let oldest = toEvict.first {
            toEvict.removeFirst()
            if oldest.url.standardizedFileURL == freshlySaved.standardizedFileURL { continue }
            if protected.contains(oldest.url.lastPathComponent) { continue }
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

    /// Every recoverable draft from every active root (iCloud and
    /// local), newest first, empties filtered. Reading the union
    /// means a user who toggled iCloud sync off still sees their
    /// previously-synced drafts in the launcher.
    func loadAll() -> [DraftRecord] {
        var records: [DraftRecord] = []
        var seen = Set<String>()
        for dir in readDirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                guard url.pathExtension == "txt" else { continue }
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = attrs?.contentModificationDate ?? .distantPast
                let bytes = attrs?.fileSize ?? 0
                guard bytes > 0 else { continue }
                let preview: String
                if let data = try? Data(contentsOf: url) {
                    // Lossy decode — the 2 KB cut can split a multibyte
                    // character, which would make String(data:encoding:)
                    // return nil and blank the whole preview.
                    let str = String(decoding: data.prefix(2_048), as: UTF8.self)
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
        }
        records.sort { $0.modified > $1.modified }
        return records
    }
}
