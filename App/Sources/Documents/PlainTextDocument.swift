import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

/// Mutable text document model that backs an editor scene.
///
/// Replaces the prior `FileDocument`/`DocumentGroup` pairing because iOS 26.5
/// simulator's local-storage FileProvider returns `FP -1005 "The file doesn't
/// exist"` for bookmarks to files DocumentGroup has just imported. The bug
/// is verifiable in the log: QuickLook can render the file at the same
/// `did=N` that DocumentManager reports as nonexistent. Until Apple fixes
/// that, we manage file I/O ourselves with traditional file paths, which
/// bypasses the FileProvider entirely.
@MainActor
@Observable
final class PlainTextDocument {

    /// Snapshot of the buffer. NOT the source of truth during
    /// editing — the engine's `TextView` owns the live buffer.
    /// This field is updated on load, save, and a 300 ms-debounced
    /// snapshot pulled from the text view (so things like the
    /// markdown preview, status-bar counts, etc. see eventually-
    /// consistent text without paying full-buffer flow per
    /// keystroke). Read live text via the text view directly when
    /// the call site cares about strict freshness (transforms,
    /// snippet inserts, save).
    var text: String = ""
    /// Tiny counter incremented on every text edit. Observers that
    /// need to react to "buffer changed" (autosave debounce, change-
    /// history overlay refresh) observe THIS instead of `text` —
    /// no full-buffer payload, no observation cascade through
    /// SwiftUI re-rendering paths.
    var bufferRevision: UInt64 = 0
    var fileEncoding: FileEncoding
    var lineEnding: LineEnding
    /// `nil` for an unsaved scratch buffer; non-nil for any document that
    /// has been saved to or opened from disk.
    var fileURL: URL?
    /// Stable identity used by `RevisionStore` to group snapshots.
    /// Per-document UUID-based key for fresh / untitled buffers; flips
    /// to a URL-derived key once the document is associated with a file
    /// on disk (load or save). The UUID variant means revisions track
    /// the tab's lifetime even before the user picks a save location.
    var revisionKey: String
    /// Tracks whether `text` differs from what's on disk. Cleared on
    /// load/save.
    var isDirty: Bool = false
    /// Last-read raw bytes — kept so the encoding picker can re-decode the
    /// file with a different encoding.
    var originalData: Data?
    /// `true` while a load is in flight. EditorView shows a progress
    /// overlay so the user can see something is happening when a file
    /// comes from a slow-to-materialise location (Nextcloud, iCloud).
    var isLoading: Bool = false
    /// Path of the per-document draft file under `Documents/Drafts/`.
    /// Lazy-populated the first time the buffer is dirty AND has no
    /// `fileURL`; the autosave path keeps it in sync. Survives app
    /// quit and resurfaces in the next launch's recovery banner so a
    /// system-gesture window close doesn't silently lose typed text.
    /// Cleared (and the on-disk file deleted) once the doc is saved
    /// to a real URL or explicitly discarded.
    var draftURL: URL?

    init() {
        self.fileEncoding = Self.defaultFileEncoding()
        self.lineEnding = Self.defaultLineEnding()
        self.revisionKey = RevisionStore.keyForUntitledTab(UUID())
    }

    /// Synchronous load — kept for the legacy "revert to saved" path
    /// where the buffer is already on disk (no File Provider download
    /// in flight). New code should use ``loadAsync(from:)`` so the
    /// async URLSession read with mid-flight cancellation kicks in.
    func load(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let payload = try Self.decodePayload(from: data)
        applyPayload(payload, url: url)
    }

    /// Shared decode-and-validate path used by both the sync and async
    /// loaders. Sniffs for binary content, checks the hard size cap,
    /// and runs the encoding-detection decoder.
    nonisolated private static func decodePayload(from data: Data) throws -> LoadPayload {
        if data.isEmpty {
            return LoadPayload(data: data, text: "", encoding: FileEncoding(encoding: .utf8))
        }
        if data.count > hardSizeCap {
            throw DocumentError.fileTooLarge(bytes: data.count)
        }
        if data.prefix(8192).contains(0) {
            throw DocumentError.binaryFile
        }
        let options = String.DetectionOptions(
            candidates: Self.candidateEncodings,
            xattrEncoding: nil,
            considersDeclaration: true
        )
        do {
            let (decoded, encoding) = try String.string(
                data: data,
                decodingStrategy: .automatic(options)
            )
            return LoadPayload(data: data, text: decoded, encoding: encoding)
        } catch {
            return LoadPayload(
                data: data,
                text: String(data: data, encoding: .utf8) ?? "",
                encoding: FileEncoding(encoding: .utf8)
            )
        }
    }

    /// Like ``load(from:)`` but reads and decodes via an async URLSession
    /// so the UI stays responsive. URLSession's async APIs honour
    /// `Task.cancel()` mid-flight — when the user taps the Cancel
    /// button in the loading overlay, the in-flight read is genuinely
    /// interrupted (the previous chunked-FileHandle approach only
    /// checked cancellation between chunks, so a single slow chunk on
    /// a sluggish Nextcloud connection blocked Cancel for many seconds).
    ///
    /// Refuses files over ``hardSizeCap`` — above that ceiling the
    /// engine's line-manager initialisation freezes the UI for many
    /// seconds even in plain-text mode.
    func loadAsync(from url: URL) async throws {
        isLoading = true
        defer { isLoading = false }
        let payload = try await Self.readPayload(from: url)
        // Yield + brief sleep gives SwiftUI a beat to paint the
        // loading overlay before we commit the text and trigger the
        // engine's text-assignment pass.
        await Task.yield()
        try? await Task.sleep(for: Timing.loadOverlayHandoff)
        if Task.isCancelled { throw CancellationError() }
        applyPayload(payload, url: url)
    }

    private func applyPayload(_ payload: LoadPayload, url: URL) {
        self.text = payload.text
        self.fileEncoding = payload.encoding
        self.originalData = payload.data
        self.lineEnding = Self.detectLineEnding(in: payload.text) ?? .lf
        self.fileURL = url
        self.isDirty = false
        // Promote to a URL-derived revision key so reopening the same
        // file finds its history. The earlier untitled-UUID key is
        // discarded — anything snapshotted before the file got a URL
        // stays under that orphaned UUID but is unreachable from this
        // document (acceptable tradeoff for simplicity).
        self.revisionKey = RevisionStore.key(for: url)
        // First read of this file (per URL) → seed the "original on
        // open" revision so a later "Revert to Original" has an
        // anchor to roll back to. No-op on subsequent reopens.
        // Revision recording is best-effort: a sandbox write
        // failure shouldn't fail the document load. Surface it.
        recordRevisionOrReport {
            try RevisionStore.shared.recordOriginalIfNeeded(payload.text, forKey: revisionKey)
        }
    }

    /// Plain value type for the data + decoded text we load off-main, then
    /// assign back on main. Kept as a nonisolated struct so the detached
    /// task can return it across actor boundaries.
    private struct LoadPayload: Sendable {
        let data: Data
        let text: String
        let encoding: FileEncoding
    }

    /// Reads and decodes a file *without* any main-actor dependencies so
    /// it can run on a background task. Honours security-scoped URLs
    /// returned by `UIDocumentPickerViewController` / SwiftUI's
    /// `.fileImporter`.
    nonisolated private static func readPayload(from url: URL) async throws -> LoadPayload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try await materializeUbiquitousItemIfNeeded(at: url)

        // URLSession's async data(from:) is the only Foundation API
        // where Task.cancel() genuinely aborts an in-flight file read
        // — synchronous FileHandle / Data(contentsOf:) only honour
        // cancellation between chunks.
        //
        // Hard 2-minute resource timeout so a hung provider doesn't
        // leave the load Task running forever.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, _): (Data, URLResponse) = try await session.data(from: url)
        return try decodePayload(from: data)
    }

    /// If `url` lives in iCloud Drive and isn't currently materialised
    /// locally, request the download explicitly and poll for
    /// completion. Each poll sleeps 200 ms via Swift concurrency, which
    /// yields the calling actor — main runloop keeps pumping. Times
    /// out after 90 seconds to match the URLSession resource budget.
    nonisolated private static func materializeUbiquitousItemIfNeeded(at url: URL) async throws {
        let manager = FileManager.default
        guard manager.isUbiquitousItem(at: url) else { return }
        try manager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values.ubiquitousItemDownloadingStatus == .current { return }
            try await Task.sleep(for: Timing.ubiquitousItemPoll)
        }
    }

    /// Saves to `fileURL` (must be non-nil). Use `save(to:)` for first save.
    func save() throws {
        guard let fileURL else {
            throw DocumentError.noFileURL
        }
        try save(to: fileURL)
    }

    /// Writes to the given URL, recording it as the document's URL on success.
    /// `kind` controls whether the resulting revision counts as a manual
    /// save (always added) or an auto-save (coalesced if the previous
    /// auto revision was recent).
    func save(to url: URL, revisionKind: RevisionStore.Kind = .manual) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try encodedData()
        try data.write(to: url, options: .atomic)
        let isFirstSave = (self.fileURL == nil)
        self.fileURL = url
        self.originalData = data
        self.isDirty = false
        // Source-of-truth file just got the latest bytes — the
        // scratch shadow is now stale, so delete it. Otherwise a
        // crash-recovery sweep would resurrect old buffer state on
        // top of the just-written file.
        deleteScratchFile()
        // Save-As (or save of a recovered untitled draft) promotes
        // the buffer to a real URL; the per-doc draft file is now
        // redundant and shouldn't resurface in the recovery banner.
        if let stale = draftURL {
            DraftsStore.shared.discard(stale)
            draftURL = nil
        }
        // A Save-As that promotes an untitled doc to disk: switch from
        // the UUID-based key to the URL-derived key so future opens of
        // the same file find this history, and seed an .original
        // anchor against the URL so "Revert to Original" works.
        if isFirstSave {
            self.revisionKey = RevisionStore.key(for: url)
            recordRevisionOrReport {
                try RevisionStore.shared.recordOriginalIfNeeded(text, forKey: revisionKey)
            }
        }
        recordRevisionOrReport {
            try RevisionStore.shared.recordRevision(text, kind: revisionKind, forKey: revisionKey)
        }
    }

    /// Mac-style autosave: writes the current buffer to a per-document
    /// scratch file in Application Support, NOT to `fileURL`. Buys
    /// crash recovery without touching the user's actual file —
    /// `save()` (⌘S) is the only path that writes back to the source.
    /// Records an `.auto` revision so the revision history reflects
    /// the autosave. Keeps `isDirty` true because the source file
    /// still differs from the buffer.
    ///
    /// Fire-and-forget: snapshots the inputs on the main actor, then
    /// dispatches the encode + write + revision-record work to a
    /// background task. The previous fully-synchronous implementation
    /// ran `replacingLineEndings` and `data.write(options: .atomic)`
    /// on the main thread; for a 1 MB+ buffer that's 100-500 ms of
    /// freeze whenever the typing debounce fired. Now the freeze is
    /// gone and the actual save lands a fraction of a second later.
    func autoSave() {
        // Mac-style recoverable draft for ANY dirty buffer — both
        // untitled bytes and URL-backed dirty edits. The recovery
        // banner on next launch scans `Documents/Drafts/` and
        // offers each draft back. For URL-backed docs we stash a
        // security-scoped bookmark of the source so the recovery
        // path can re-open the original and apply the drafted text
        // on top (vs. just opening as Untitled and losing the
        // association with the original file).
        if !text.isEmpty {
            var metadata: DraftMetadata?
            if let source = fileURL {
                let bookmark = try? source.bookmarkData(options: .minimalBookmark)
                metadata = DraftMetadata(
                    sourceBookmark: bookmark,
                    sourceDisplay: Self.displayPath(for: source),
                    sourceEncodingRaw: fileEncoding.encoding.rawValue
                )
            }
            draftURL = DraftsStore.shared.save(
                text: text,
                existing: draftURL,
                metadata: metadata
            )
        } else if let stale = draftURL {
            // Empty buffer + still has a draft file → the user
            // cleared the text. Drop the draft so it doesn't
            // resurface in the recovery banner.
            DraftsStore.shared.discard(stale)
            draftURL = nil
        }
        guard let scratch = Self.scratchURL(for: revisionKey) else { return }
        let snapshot = text
        let key = revisionKey
        let encoding = fileEncoding
        let lineEnd = lineEnding
        let defaults = UserDefaults.standard
        let trimTrailing = defaults.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave)
        let ensureNewline = defaults.bool(forKey: AppPreferenceKey.ensureTrailingNewline)
        let bomPref = defaults.bool(forKey: AppPreferenceKey.saveUTF8BOM)
        Task.detached(priority: .utility) {
            do {
                let data = try Self.encode(
                    text: snapshot,
                    encoding: encoding,
                    lineEnding: lineEnd,
                    trimTrailingWhitespace: trimTrailing,
                    ensureTrailingNewline: ensureNewline,
                    saveUTF8BOMPref: bomPref
                )
                try data.write(to: scratch, options: .atomic)
            } catch {
                // Best-effort autosave; failure surfaces only via
                // the revision-record path below if relevant.
            }
            // RevisionStore is @MainActor (it writes per-key files
            // and updates a manifest). Hop back to record the auto
            // revision; the disk write that just happened above
            // already saved the buffer to scratch, so this is the
            // cheap part.
            await MainActor.run {
                try? RevisionStore.shared.recordRevision(snapshot, kind: .auto, forKey: key)
            }
        }
    }

    /// Untitled-buffer entry point — kept as an alias so existing
    /// callers don't need to change. The unified `autoSave()` path
    /// works for untitled docs too (scratch URL is keyed by
    /// `revisionKey`, which is UUID-based until a Save-As).
    func autoSnapshot() {
        autoSave()
    }

    /// Drop the scratch shadow for this document — used by the
    /// "Discard Changes" close path so a confirmed throw-away doesn't
    /// leave abandoned bytes on disk.
    func deleteScratchFile() {
        guard let url = Self.scratchURL(for: revisionKey) else { return }
        try? FileManager.default.removeItem(at: url)
        // A confirmed Discard tears the recoverable-draft file
        // down too — the user explicitly threw the bytes away, so
        // they must not resurrect from the next-launch banner.
        DraftsStore.shared.discard(draftURL)
        draftURL = nil
    }

    /// Last 2-3 path components, joined with " / ", for use in the
    /// recovery sheet's row subtitle. Falls back to the full path
    /// when the URL has fewer than 2 components.
    nonisolated static func displayPath(for url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count <= 2 { return url.path }
        return parts.suffix(3).joined(separator: " / ")
    }

    // MARK: - Scratch storage

    /// URL for the per-document scratch shadow keyed by
    /// `revisionKey`. Each call ensures the parent directory exists
    /// so writes can land without a stat-first dance. Returns nil
    /// only if Application Support itself is unreachable — i.e.
    /// never on a healthy install.
    private static func scratchURL(for revisionKey: String) -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true) else { return nil }
        let dir = support.appendingPathComponent("AutoSavedDocuments", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Slashes from URL-derived revision keys would create
        // subdirectories — replace them so every doc lives in one
        // flat scratch folder.
        let safeName = revisionKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safeName).appendingPathExtension("txt")
    }

    /// Revision recording is best-effort — a sandbox / disk failure
    /// shouldn't fail the underlying save or load. Surface the error
    /// through `AppStateBus.openErrorMessage` so it reaches the user
    /// instead of silently disappearing.
    @discardableResult
    private func recordRevisionOrReport(
        _ body: () throws -> RevisionStore.Entry?
    ) -> RevisionStore.Entry? {
        do {
            return try body()
        } catch {
            AppStateBus.shared.editing.openErrorMessage = error.localizedDescription
            return nil
        }
    }

    func encodedData() throws -> Data {
        let defaults = UserDefaults.standard
        return try Self.encode(
            text: text,
            encoding: fileEncoding,
            lineEnding: lineEnding,
            trimTrailingWhitespace: defaults.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave),
            ensureTrailingNewline: defaults.bool(forKey: AppPreferenceKey.ensureTrailingNewline),
            saveUTF8BOMPref: defaults.bool(forKey: AppPreferenceKey.saveUTF8BOM)
        )
    }

    /// Pure encode — no instance state, no main-actor dependency.
    /// Callable from a detached background task so a multi-MB
    /// `replacingLineEndings(with:)` doesn't run on the main thread
    /// during autosave (the trim + line-ending normalisation + UTF-8
    /// conversion on a 1 MB buffer is ~50-200 ms of pure-Swift work
    /// that froze typing on McCartney-sized files).
    nonisolated static func encode(
        text: String,
        encoding: FileEncoding,
        lineEnding: LineEnding,
        trimTrailingWhitespace: Bool,
        ensureTrailingNewline: Bool,
        saveUTF8BOMPref: Bool
    ) throws -> Data {
        var output = text
        if trimTrailingWhitespace {
            output = trimmingTrailingWhitespace(from: output)
        }
        output = output.replacingLineEndings(with: lineEnding)
        if ensureTrailingNewline, !output.hasSuffix(lineEnding.string) {
            output += lineEnding.string
        }
        let rawEncoding = encoding.encoding
        guard var data = output.data(using: rawEncoding, allowLossyConversion: false) else {
            throw CocoaError(
                .fileWriteInapplicableStringEncoding,
                userInfo: [NSStringEncodingErrorKey: rawEncoding.rawValue]
            )
        }
        let bomForDocument = encoding.withUTF8BOM
        if rawEncoding == .utf8, (bomForDocument || saveUTF8BOMPref) {
            var prefixed = Data([0xEF, 0xBB, 0xBF])
            prefixed.append(data)
            data = prefixed
        }
        return data
    }

    // MARK: - Helpers

    enum DocumentError: LocalizedError {
        case noFileURL
        case fileTooLarge(bytes: Int)
        case binaryFile
        var errorDescription: String? {
            switch self {
            case .noFileURL:
                return "Save the document first before using Save."
            case .fileTooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                let capMB = Double(PlainTextDocument.hardSizeCap) / 1_048_576
                return String(
                    format: "This file is %.1f MB. Files over %.0f MB can't be opened in this editor on iPad — the engine's initial parse would freeze the app. Try splitting the file or using a desktop editor.",
                    mb, capMB
                )
            case .binaryFile:
                return "This file looks like a binary (it contains NUL bytes). The text editor can only open plain-text files."
            }
        }
    }

    /// Hard ceiling above which the editor refuses to open a file.
    /// Below this, the user's `SyntaxLimit` choice gates syntax /
    /// fold / decorator work; above it, even plain-text mode would
    /// freeze the UI during the engine's line-manager init.
    nonisolated static let hardSizeCap: Int = 100 * 1024 * 1024  // 100 MB

    static let supportedReadTypes: [UTType] = [
        .plainText, .utf8PlainText, .utf16PlainText, .sourceCode, .text,
        .delimitedText, .commaSeparatedText, .tabSeparatedText,
        .yaml, .json, .xml, .html, .data
    ]
    static let supportedWriteType: UTType = .plainText

    nonisolated static let candidateEncodings: [String.Encoding] = [
        .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32,
        .windowsCP1252, .isoLatin1, .isoLatin2, .macOSRoman,
        .shiftJIS, .japaneseEUC, .iso2022JP
    ]

    static func detectLineEnding(in string: String) -> LineEnding? {
        switch TextMetrics.firstLineEnding(in: string as NSString) {
        case .lf?:   return .lf
        case .cr?:   return .cr
        case .crlf?: return .crlf
        case nil:    return nil
        }
    }

    static func defaultFileEncoding() -> FileEncoding {
        let raw = UInt(UserDefaults.standard.integer(forKey: AppPreferenceKey.defaultEncodingRaw))
        let encoding = String.Encoding(rawValue: raw == 0 ? String.Encoding.utf8.rawValue : raw)
        return FileEncoding(encoding: encoding)
    }

    static func defaultLineEnding() -> LineEnding {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.defaultLineEndingRaw) ?? "\n"
        return LineEnding(rawValue: raw.first ?? "\n") ?? .lf
    }

    nonisolated private static func trimmingTrailingWhitespace(from input: String) -> String {
        input
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { line -> Substring in
                var s = line
                while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
                return s
            }
            .joined(separator: "\n")
    }
}

