import Foundation

/// Persistent ring buffer of the URLs the user has most recently opened or
/// saved. Stored as bookmark data in `UserDefaults` so the URLs survive
/// app restarts even when the file lives outside the app's sandbox (the
/// user picked it via `.fileImporter`/`.fileExporter`).
@MainActor
@Observable
final class RecentFilesStore {

    static let shared = RecentFilesStore()

    private(set) var urls: [URL] = []

    /// Maximum entries retained. Standard for "Open Recent" menus.
    private let capacity = 10

    private let defaultsKey = "recentFilesBookmarks"

    private init() {
        load()
    }

    func record(_ url: URL) {
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > capacity {
            urls.removeLast(urls.count - capacity)
        }
        persist()
    }

    func clear() {
        urls = []
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        self.urls = raw.compactMap { data in
            var stale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
    }

    private func persist() {
        let bookmarks: [Data] = urls.compactMap { url in
            try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
