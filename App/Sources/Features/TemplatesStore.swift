import Foundation

/// One file in `Documents/Templates/`. Tapping the row in the
/// launcher seeds a brand-new Untitled tab with the file's bytes —
/// the template file itself is never opened, so editing the new
/// buffer never bleeds back into the template.
struct TemplateRecord: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let displayName: String
    /// SF Symbol picked from the file extension so the launcher row
    /// looks distinct (`doc.text.fill` for .txt, `text.book.closed`
    /// for .md, `tablecells` for .csv, …). Falls back to a generic
    /// document for unknown types.
    let symbol: String
}

/// First-run seeding + live enumeration of `Documents/Templates/`.
/// The user can drop additional template files into the folder via
/// Files.app — they show up in the launcher next time it appears.
@MainActor
final class TemplatesStore {

    static let shared = TemplatesStore()

    /// Active write root — iCloud when sync is on and the user is
    /// signed in, otherwise local Documents. Default seeds get
    /// (re-)installed here so an app update can ship new defaults,
    /// but a user-added template is never auto-deleted.
    var directory: URL {
        UbiquityContainer.documentsURLForWrite.appendingPathComponent("Templates", isDirectory: true)
    }

    /// Every root the launcher scans for templates. Listing both
    /// roots means a user who flipped iCloud off keeps seeing the
    /// templates they previously synced.
    var readDirectories: [URL] {
        UbiquityContainer.documentsRootsForRead.map {
            $0.appendingPathComponent("Templates", isDirectory: true)
        }
    }

    private init() {}

    /// Idempotent: creates the folder, writes any seed file that
    /// isn't already there. Lets the user delete a seed they don't
    /// want without it reappearing — only missing files are written.
    /// Seeds the *active* directory only; the other root keeps
    /// whatever templates the user left there.
    func seedIfNeeded() {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for seed in Self.defaultSeeds {
            let url = dir.appendingPathComponent(seed.filename)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? seed.body.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// Union of every read root. Same-named templates in two roots
    /// are deduped — iCloud wins because it's first in
    /// `UbiquityContainer.documentsRootsForRead`.
    func loadAll() -> [TemplateRecord] {
        var records: [TemplateRecord] = []
        var seenName = Set<String>()
        for dir in readDirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.nameKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                let lowercaseName = url.lastPathComponent.lowercased()
                guard seenName.insert(lowercaseName).inserted else { continue }
                records.append(TemplateRecord(
                    url: url,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    symbol: Self.symbol(for: url.pathExtension.lowercased())
                ))
            }
        }
        return records.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Returns the template's bytes as a String, or nil if the file
    /// vanished between enumeration and tap.
    func loadContent(_ template: TemplateRecord) -> String? {
        guard let data = try? Data(contentsOf: template.url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func symbol(for ext: String) -> String {
        switch ext {
        case "md", "markdown":     return "text.book.closed.fill"
        case "csv", "tsv":         return "tablecells.fill"
        case "json", "yaml", "yml": return "curlybraces"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "cpp", "h":
                                    return "chevron.left.forwardslash.chevron.right"
        case "html", "xml":        return "chevron.left.slash.chevron.right"
        case "txt", "":            return "doc.text.fill"
        default:                   return "doc.fill"
        }
    }

    private struct Seed {
        let filename: String
        let body: String
    }

    private static let defaultSeeds: [Seed] = [
        Seed(filename: "Blank.txt", body: ""),
        Seed(filename: "Notes.md", body: """
        # Notes

        -

        """),
        Seed(filename: "Data.csv", body: """
        column1,column2,column3
        ,,
        """)
    ]
}
