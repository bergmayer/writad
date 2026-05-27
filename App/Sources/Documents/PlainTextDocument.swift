import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

/// Document model for one open buffer.
///
/// We don't use `DocumentGroup` / `FileDocument` because of an iOS 26.5
/// simulator FileProvider bug: bookmarks to just-imported files return
/// `FP -1005 "doesn't exist"`. Our own load path through `.fileImporter`
/// + `URLSession` sidesteps it. Once Apple ships the fix this layer can
/// probably go away.
@MainActor
@Observable
final class PlainTextDocument {

    /// Debounced snapshot of the buffer. The engine's `TextView` owns
    /// the live text — read from there when freshness matters (save,
    /// transforms, snippet inserts). This lags by ~300 ms but lets
    /// SwiftUI observers (status-bar counts, markdown preview) update
    /// without paying the per-keystroke cost.
    var text: String = ""

    /// Bumped on every edit. Observers that just need "something
    /// changed" (autosave debounce, change-history overlay) watch
    /// this instead of `text` to avoid invalidating the full buffer.
    var bufferRevision: UInt64 = 0

    var fileEncoding: FileEncoding
    var lineEnding: LineEnding
    var fileURL: URL?

    /// Per-document key for `RevisionStore`. UUID-based for untitled
    /// buffers, URL-hash-based once saved.
    var revisionKey: String

    var isDirty: Bool = false
    /// Raw bytes from the last load — kept so the encoding picker can
    /// re-decode with a different encoding without re-reading disk.
    var originalData: Data?
    var isLoading: Bool = false

    /// `Documents/Drafts/<UUID>.txt` path for crash-recovery. Set on
    /// first autosave of a dirty doc; cleared on Save-As / Discard.
    var draftURL: URL?

    /// Monotonic per-launch tag so a window full of fresh "Untitled"
    /// tabs picks up distinct titles ("Untitled", "Untitled 2", …)
    /// — same scheme TextEdit uses. Stays the same after the doc is
    /// saved (becomes irrelevant once `fileURL` is set); numbers
    /// aren't recycled when a tab closes.
    let untitledNumber: Int

    private static var untitledCounter: Int = 0
    private static func nextUntitledNumber() -> Int {
        untitledCounter += 1
        return untitledCounter
    }

    init() {
        self.fileEncoding = Self.defaultFileEncoding()
        self.lineEnding = Self.defaultLineEnding()
        self.revisionKey = RevisionStore.keyForUntitledTab(UUID())
        self.untitledNumber = Self.nextUntitledNumber()
    }

    /// Window/tab pill title. Untitled docs read "Untitled" (n=1)
    /// or "Untitled N" so multiple Untitled windows are visually
    /// distinct in Stage Manager / the App Switcher.
    var displayName: String {
        if let url = fileURL { return url.lastPathComponent }
        return untitledNumber == 1 ? "Untitled" : "Untitled \(untitledNumber)"
    }

    /// Disk state at the moment we last read from / wrote to the
    /// source file. The stale-source safeguard compares these to
    /// the current on-disk attrs before adopting a draft or ⌘S'ing
    /// — if either differs (or the file's gone), the user sees a
    /// missing / changed dialog before any bytes commit.
    var sourceMtimeAtLoad: Date?
    var sourceSizeAtLoad: Int?

    /// Reads the file's modification date + size for the stale
    /// check. `nil` means the URL is gone or unreachable.
    nonisolated static func diskAttrs(of url: URL) -> (mtime: Date, size: Int)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = attrs.contentModificationDate,
              let size = attrs.fileSize
        else { return nil }
        return (mtime, size)
    }

    /// Synchronous load. Used by Revert-to-Saved; new code should
    /// prefer ``loadAsync(from:)`` so a slow File Provider can be
    /// cancelled mid-read.
    func load(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let payload = try Self.decodePayload(from: data)
        applyPayload(payload, url: url)
    }

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

    /// Async load with mid-flight cancellation. URLSession is the
    /// only Foundation API where `Task.cancel()` genuinely aborts an
    /// in-flight file read; synchronous `Data(contentsOf:)` only
    /// checks between chunks.
    func loadAsync(from url: URL) async throws {
        isLoading = true
        defer { isLoading = false }
        let payload = try await Self.readPayload(from: url)
        // Yield so SwiftUI can paint the loading overlay before the
        // text-assignment pass kicks the engine.
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
        // Capture the disk snapshot now so the stale-source check
        // on save can spot concurrent writes from other apps /
        // devices.
        if let attrs = Self.diskAttrs(of: url) {
            self.sourceMtimeAtLoad = attrs.mtime
            self.sourceSizeAtLoad = attrs.size
        }
        // URL-derived key — reopening the same file finds its
        // revision history. Anything captured under the prior
        // untitled-UUID key is orphaned (acceptable tradeoff).
        self.revisionKey = RevisionStore.key(for: url)
        // Seed an "original on open" revision once per URL so a
        // later Revert-to-Original has an anchor. Best-effort — a
        // sandbox write failure doesn't fail the document load.
        recordRevisionOrReport {
            try RevisionStore.shared.recordOriginalIfNeeded(payload.text, forKey: revisionKey)
        }
    }

    private struct LoadPayload: Sendable {
        let data: Data
        let text: String
        let encoding: FileEncoding
    }

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

    /// Pull an iCloud-Drive file down if it's not local yet. Polls
    /// at 200 ms via Task.sleep so the main runloop keeps pumping.
    /// 90-second timeout matches URLSession's resource budget.
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

    /// ⌘S — write to the existing `fileURL`. Use `save(to:)` for first save.
    func save() throws {
        guard let fileURL else { throw DocumentError.noFileURL }
        try save(to: fileURL)
    }

    /// Write to `url` and update document state to reflect it.
    /// Used by ⌘S, Save As, and the post-rename rewrite path.
    func save(to url: URL, revisionKind: RevisionStore.Kind = .manual) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try encodedData()
        try data.write(to: url, options: .atomic)
        let isFirstSave = (self.fileURL == nil)
        self.fileURL = url
        self.originalData = data
        self.isDirty = false
        // Bring the stale-source baseline up to date with the bytes
        // we just wrote — otherwise the next ⌘S would see "changed
        // since last load" and warn about our own write.
        if let attrs = Self.diskAttrs(of: url) {
            self.sourceMtimeAtLoad = attrs.mtime
            self.sourceSizeAtLoad = attrs.size
        }
        // The just-written file is now canonical; drop the scratch
        // shadow and the draft entry so neither resurrects stale bytes.
        deleteScratchFile()
        if let stale = draftURL {
            DraftsStore.shared.discard(stale)
            draftURL = nil
        }
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

    /// Mac-style autosave with checkout semantics:
    ///
    /// - Per-keystroke (`commitDraft: false`): writes only to the
    ///   local scratch shadow + revision store. The synced drafts
    ///   folder is NOT touched, so two devices can't both see the
    ///   same buffer in the launcher while it's being edited.
    /// - On close / app-background (`commitDraft: true`): also
    ///   writes a draft to the synced folder so the buffer is
    ///   recoverable from the launcher on the next session or on
    ///   another device.
    ///
    /// Never touches `fileURL` either way — ⌘S is the only path
    /// that writes back to the source. Off-main so the encode +
    /// write don't freeze the typing loop.
    func autoSave(commitDraft: Bool = false) {
        if commitDraft {
            writeDraftToSyncFolder()
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
            // cheap part. `try?` returns `Void?`; the `_ =` discard
            // silences MainActor.run's unused-result warning.
            _ = await MainActor.run {
                try? RevisionStore.shared.recordRevision(snapshot, kind: .auto, forKey: key)
            }
        }
    }

    /// Alias kept for legacy call sites — the unified `autoSave()`
    /// already handles untitled buffers.
    func autoSnapshot() { autoSave() }

    /// Push the live buffer into the synced drafts folder. Called
    /// from every close path (tab × / ⌘W / Save as Draft / window
    /// close / app background) so that an interrupted session can
    /// be resumed from the launcher on this or any synced device.
    /// Per-keystroke autosave doesn't call this — the draft folder
    /// only sees the buffer at moments the user "lets go" of it.
    func writeDraftToSyncFolder() {
        if !text.isEmpty {
            var metadata: DraftMetadata?
            if let source = fileURL {
                let bookmark = try? source.bookmarkData(options: .minimalBookmark)
                metadata = DraftMetadata(
                    sourceBookmark: bookmark,
                    sourceDisplay: Self.displayPath(for: source),
                    sourceEncodingRaw: fileEncoding.encoding.rawValue,
                    sourceMtime: sourceMtimeAtLoad,
                    sourceSize: sourceSizeAtLoad
                )
            }
            draftURL = DraftsStore.shared.save(
                text: text,
                existing: draftURL,
                metadata: metadata
            )
        } else if let stale = draftURL {
            // User cleared the buffer before close — drop the draft
            // so it doesn't resurface as an empty entry in the
            // launcher.
            DraftsStore.shared.discard(stale)
            draftURL = nil
        }
    }

    /// Throw away the scratch shadow and draft for this doc — called
    /// by the Discard close path.
    func deleteScratchFile() {
        if let url = Self.scratchURL(for: revisionKey) {
            try? FileManager.default.removeItem(at: url)
        }
        DraftsStore.shared.discard(draftURL)
        draftURL = nil
    }

    /// Last 2-3 path components joined with " / " for the recovery
    /// sheet's row subtitle.
    nonisolated static func displayPath(for url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count <= 2 { return url.path }
        return parts.suffix(3).joined(separator: " / ")
    }

    // MARK: - Scratch storage

    private static func scratchURL(for revisionKey: String) -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true) else { return nil }
        let dir = support.appendingPathComponent("AutoSavedDocuments", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Slashes in URL-derived keys would create subdirectories.
        let safeName = revisionKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safeName).appendingPathExtension("txt")
    }

    /// Revision recording is best-effort — a disk failure shouldn't
    /// fail the save or load, but the user should see it.
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

    /// File picker / Recents are gated on these types so the user
    /// only sees files Ayyyy can actually open. Dropping `.data`
    /// removes the over-broad fallback — it matches every file. Add
    /// custom UTIs (markdown / TeX / Typst) when registered.
    static let supportedReadTypes: [UTType] = {
        var types: [UTType] = [
            .plainText, .utf8PlainText, .utf16PlainText, .sourceCode, .text,
            .delimitedText, .commaSeparatedText, .tabSeparatedText,
            .yaml, .json, .xml, .html
        ]
        for identifier in ["net.daringfireball.markdown", "org.tug.tex", "app.typst.typst"] {
            if let custom = UTType(identifier) { types.append(custom) }
        }
        return types
    }()
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

