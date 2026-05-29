import Foundation

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
