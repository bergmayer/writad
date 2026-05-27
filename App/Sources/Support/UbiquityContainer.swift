import Foundation

/// Resolves the app's iCloud Drive ubiquity container — the
/// directory under <iCloud>/<container>/Documents that the Files
/// app exposes as "Ayyyy" and syncs across the user's devices.
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
    static let containerIdentifier = "iCloud.com.palefire.ayyyy"

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

    /// iCloud if available, else local Documents. Both stores
    /// (drafts, templates) resolve their working directory through
    /// here so the rest of the app doesn't need to know.
    static var preferredDocumentsURL: URL {
        documentsURL ?? localDocumentsURL
    }

    /// `true` when the user is signed in to iCloud and the app has
    /// access to its ubiquity container. Used by UI surfaces that
    /// want to flag "not syncing right now."
    static var isAvailable: Bool {
        documentsURL != nil
    }
}
