import Foundation

/// Resolves the app's iCloud Drive ubiquity container — the
/// directory under <iCloud>/<container>/Documents that the Files
/// app exposes as "writað" and syncs across the user's devices.
/// Drafts and templates live inside it so a draft started on iPad
/// shows up on iPhone, and so the user can drop a custom template
/// in from Files.app on any device.
///
/// `url(forUbiquityContainerIdentifier:)` blocks on first call and
/// returns nil when the user isn't signed in to iCloud or hasn't
/// enabled iCloud Drive for the app. Callers fall back to the
/// local Documents directory in that case — the behavior matches
/// what we had before, just without cross-device sync.
@MainActor
enum UbiquityContainer {

    /// `iCloud.<bundle-id>` per Apple's container-ID convention.
    /// Kept in sync with the entitlements file and Info.plist.
    static let containerIdentifier = "iCloud.com.palefire.writad"

    /// `<container>/Documents` — the public scope visible in Files.
    /// `nil` means iCloud isn't available; caller should use local
    /// Documents instead.
    static let documentsURL: URL? = {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }()

    /// Local `Documents` — used both as a fallback when iCloud isn't
    /// available and as the canonical home for non-synced content.
    static let localDocumentsURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }()

    /// `true` when the user is signed in to iCloud and the app has
    /// access to its ubiquity container. Says nothing about the
    /// user's preference — see `syncIsActive` for that.
    static var isAvailable: Bool { documentsURL != nil }

    /// User's stored toggle. Reading via UserDefaults directly
    /// rather than `@AppStorage` so non-View callers (DraftsStore,
    /// TemplatesStore, both `@MainActor` singletons) can check it
    /// without dragging SwiftUI in.
    static var userPrefersSync: Bool {
        // `bool(forKey:)` returns false for a missing key, but the
        // default is true (registered in AppPreferenceDefaults). The
        // `object(forKey:) != nil` guard keeps that default honored
        // on the very first launch before defaults are registered.
        let key = AppPreferenceKey.iCloudSyncEnabled
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// `true` when we're actually writing to iCloud — both the user
    /// toggle and the system signal must align.
    static var syncIsActive: Bool {
        isAvailable && userPrefersSync
    }

    /// Where new files (drafts, templates) get written. The reads
    /// always check both locations (`documentsRootsForRead`) so a
    /// toggle flip never strands existing content.
    static var documentsURLForWrite: URL {
        syncIsActive ? (documentsURL ?? localDocumentsURL) : localDocumentsURL
    }

    /// Both potential roots, in priority order — iCloud first when
    /// available, then local. DraftsStore + TemplatesStore iterate
    /// these so a user who toggles iCloud off still sees their old
    /// iCloud drafts in the launcher.
    static var documentsRootsForRead: [URL] {
        var roots: [URL] = []
        if let iCloud = documentsURL { roots.append(iCloud) }
        roots.append(localDocumentsURL)
        // Dedupe — on a Mac Catalyst build the two paths can resolve
        // to the same URL.
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
