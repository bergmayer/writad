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

    let directory: URL

    private init() {
        // Prefer iCloud Drive so drafts sync across the user's
        // devices; fall back to local Documents when iCloud is off
        // or the user isn't signed in. Either way the path is
        // `<root>/Drafts/`.
        let docs = UbiquityContainer.preferredDocumentsURL
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
