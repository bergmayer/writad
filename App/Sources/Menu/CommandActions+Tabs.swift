import Foundation
import UIKit
import FileEncoding

extension CommandActions {

    // MARK: - Move / detach

    /// Detaches the tab and lands it in a fresh editor scene via
    /// `pending.adoptedTab`. `toNewWindow:` is the only mode today;
    /// the parameter leaves room for a "Move to Other Window" picker.
    static func moveTab(_ tabID: UUID, toNewWindow: Bool) {
        guard DeviceIdiom.supportsMultipleWindows,
              let source = Self.context.scenes.session(containing: tabID),
              source.tabs.count > 1,
              let tab = source.detachTab(tabID)
        else { return }
        Self.context.pending.adoptedTab = tab
        Self.context.scenes.requestOpenWindow(.editor)
        Self.context.scenes.openWindowAction?(.editor)
    }

    // MARK: - Close / confirm

    /// ⌘W closes the active tab. Closing the final tab now leaves the
    /// window with a fresh launcher tab instead of destroying it —
    /// matching Safari iPad's "Start Page". Use `closeWindow()`
    /// (⌘⇧W) when the user actually wants the window gone.
    static func closeActiveTab() {
        guard let session = Self.session else { return }
        requestCloseTab(session.selectedTabID, in: session)
    }

    /// Tear down the foreground scene. iPad-only; iPhone is single-
    /// window and the system request is a no-op there.
    static func closeWindow() {
        destroyForegroundWindowScene()
    }

    static func destroyForegroundWindowScene() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) else { return }
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: nil
        )
    }

    /// Single entry point so every UI surface (pill ×, swipe-to-
    /// close, context menu, ⌘W) gets the same unsaved-changes warning.
    static func requestCloseTab(_ tabID: UUID, in session: EditorSession) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else { return }
        if shouldWarnBeforeClose(tab) {
            Self.context.editing.pendingClose = PendingClose(
                sessionID: ObjectIdentifier(session),
                tabID: tabID,
                displayName: tab.document.displayName,
                isUntitled: tab.document.fileURL == nil
            )
        } else {
            _ = session.closeTab(tabID)
        }
    }

    /// `.discard` disposition so the buffer is NOT archived to
    /// ClosedTabsStore — a deliberate throw-away mustn't be
    /// resurrectable via ⇧⌘T. Drops the scratch shadow too.
    static func confirmDiscardAndClose(_ pending: PendingClose) {
        defer { Self.context.editing.pendingClose = nil }
        guard let (session, tab) = Self.resolveSession(for: pending) else { return }
        tab.document.deleteScratchFile()
        session.closeTab(pending.tabID, disposition: .discard)
    }

    /// URL-backed: save then close. Untitled: route to Save As, tab
    /// stays open. On save failure: surface the error and KEEP the
    /// tab — closing would silently destroy the buffer.
    static func confirmSaveAndClose(_ pending: PendingClose) {
        guard let (session, tab) = Self.resolveSession(for: pending) else {
            Self.context.editing.pendingClose = nil
            return
        }
        guard tab.document.fileURL != nil else {
            Self.context.pickers.pending = .saveAs
            Self.context.editing.pendingClose = nil
            return
        }
        do {
            try tab.document.save()
        } catch {
            Self.context.editing.openErrorMessage =
                "Couldn't save \(pending.displayName): \(error.localizedDescription)"
            Self.context.editing.pendingClose = nil
            return
        }
        session.closeTab(pending.tabID)
        Self.context.editing.pendingClose = nil
    }

    /// "Save as Draft" path from the close dialog + title menu:
    /// force a draft snapshot of the live text so the launcher can
    /// resume it, then close (archive disposition — both the draft
    /// and the closed-tab record become recovery vehicles). Same
    /// shape as autoSave but synchronous to the user's tap so we
    /// don't lose the last keystroke when the debounce hadn't fired.
    static func saveAsDraftAndClose(_ pending: PendingClose) {
        defer { Self.context.editing.pendingClose = nil }
        guard let (session, tab) = Self.resolveSession(for: pending) else { return }
        snapshotDraft(for: tab)
        session.closeTab(pending.tabID)
    }

    /// Title-menu / palette entry — captures the buffer into the
    /// draft store without closing.
    static func saveAsDraft() {
        guard let session = Self.context.scenes.currentSession,
              let tab = session.tabs.first(where: { $0.id == session.selectedTabID })
        else { return }
        snapshotDraft(for: tab)
    }

    private static func snapshotDraft(for tab: TabModel) {
        if let live = tab.state.textView?.text {
            tab.document.text = live
        }
        tab.document.autoSave()
    }

    static func cancelPendingClose() {
        Self.context.editing.pendingClose = nil
    }

    // MARK: - Stale-source safeguard

    /// Run before any ⌘S that's targeting an existing `fileURL`.
    /// Returns `true` when the caller should proceed with the
    /// actual write — `false` means we've raised a stale dialog
    /// and the user has to resolve it first.
    @discardableResult
    static func saveDocumentSafely(_ tab: TabModel, session: EditorSession) -> Bool {
        guard let url = tab.document.fileURL else {
            Self.context.pickers.pending = .saveAs
            return false
        }
        if let attrs = PlainTextDocument.diskAttrs(of: url),
           let loadMtime = tab.document.sourceMtimeAtLoad,
           let loadSize = tab.document.sourceSizeAtLoad,
           attrs.mtime != loadMtime || attrs.size != loadSize {
            Self.context.editing.sourceStaleCheck = .changedOnSave(
                tabID: tab.id,
                displayName: tab.document.displayName
            )
            return false
        }
        return performSave(tab: tab)
    }

    /// "Save Anyway" path off the stale dialog — bypasses the disk
    /// check and writes over whatever's there now. The user
    /// acknowledged data loss.
    static func forceSaveAfterStale() {
        defer { Self.context.editing.sourceStaleCheck = nil }
        guard let check = Self.context.editing.sourceStaleCheck,
              let (_, tab) = resolveTab(for: check)
        else { return }
        _ = performSave(tab: tab)
    }

    /// "Reload" path off the stale dialog — discards the buffer's
    /// in-memory state and re-reads the source from disk. Lossy
    /// for whatever wasn't yet ⌘S'd.
    static func reloadAfterStale() {
        defer { Self.context.editing.sourceStaleCheck = nil }
        guard let check = Self.context.editing.sourceStaleCheck,
              let (_, tab) = resolveTab(for: check),
              let url = tab.document.fileURL
        else { return }
        // Throw away the draft + scratch — the user picked reload,
        // so the unsaved bytes are deliberately gone.
        tab.document.deleteScratchFile()
        Task { @MainActor in
            do {
                try await tab.document.loadAsync(from: url)
                tab.state.text = tab.document.text
                tab.state.fileURL = url
                tab.state.savedBaselineText = tab.document.text
            } catch {
                Self.context.editing.openErrorMessage =
                    "Couldn't reload \(check.displayName): \(error.localizedDescription)"
            }
        }
    }

    /// "Continue Editing" path off the `changedOnAdopt` dialog —
    /// keeps the drafted text but bumps the load-time baseline to
    /// the disk's current attrs so the next ⌘S doesn't re-warn for
    /// the same drift.
    static func acceptStaleAdopt() {
        defer { Self.context.editing.sourceStaleCheck = nil }
        guard let check = Self.context.editing.sourceStaleCheck,
              case .changedOnAdopt = check,
              let (_, tab) = resolveTab(for: check),
              let url = tab.document.fileURL,
              let attrs = PlainTextDocument.diskAttrs(of: url)
        else { return }
        tab.document.sourceMtimeAtLoad = attrs.mtime
        tab.document.sourceSizeAtLoad = attrs.size
    }

    /// "OK" off the source-missing dialog — the file's gone, so
    /// the buffer drops its URL link and becomes Untitled. Draft
    /// stays around as recovery for the bytes themselves.
    static func acknowledgeSourceMissing() {
        defer { Self.context.editing.sourceStaleCheck = nil }
        guard let check = Self.context.editing.sourceStaleCheck,
              case .missing = check,
              let (_, tab) = resolveTab(for: check)
        else { return }
        tab.document.fileURL = nil
        tab.state.fileURL = nil
        tab.document.sourceMtimeAtLoad = nil
        tab.document.sourceSizeAtLoad = nil
        // No baseline against a missing file — every line is "added"
        // until the user picks a new save target.
        tab.state.savedBaselineText = ""
    }

    private static func performSave(tab: TabModel) -> Bool {
        if let live = tab.state.textView?.text {
            tab.document.text = live
        }
        do {
            try tab.document.save()
            tab.state.savedBaselineText = tab.document.text
            return true
        } catch {
            Self.context.editing.openErrorMessage =
                "Couldn't save \(tab.document.displayName): \(error.localizedDescription)"
            return false
        }
    }

    /// Walks every open session for a tab matching the stale-check.
    private static func resolveTab(for check: SourceStaleCheck) -> (EditorSession, TabModel)? {
        let tabID: UUID
        switch check {
        case .missing(let t, _), .changedOnAdopt(let t, _), .changedOnSave(let t, _):
            tabID = t
        }
        for session in Self.context.scenes.allOpenSessions {
            if let tab = session.tabs.first(where: { $0.id == tabID }) {
                return (session, tab)
            }
        }
        return nil
    }

    /// Shared by save / discard handlers so both reach the same
    /// definition of "the targeted tab."
    private static func resolveSession(for pending: PendingClose) -> (EditorSession, TabModel)? {
        let sessions = Self.context.scenes.allOpenSessions
        guard let session = sessions.first(where: { ObjectIdentifier($0) == pending.sessionID }),
              let tab = session.tabs.first(where: { $0.id == pending.tabID })
        else { return nil }
        return (session, tab)
    }

    /// Untitled-with-content or URL-backed-and-dirty triggers the
    /// dialog. Empty untitled scratches close silently — losing zero
    /// bytes isn't worth a confirmation.
    private static func shouldWarnBeforeClose(_ tab: TabModel) -> Bool {
        // Pull the engine's live buffer — `document.text` is a 300 ms
        // snapshot and a one-character untitled buffer + immediate
        // ⌘W would otherwise sail past the warning.
        let liveText = tab.state.textView?.text ?? tab.document.text
        if tab.document.fileURL == nil {
            return !liveText.isEmpty
        }
        return tab.document.isDirty
    }

    /// Public peek — sheet-hosting UI (switcher, palette) checks
    /// this so it can dismiss itself before the dialog. iOS hosts
    /// one modal per scene; presenting under another sheet drops
    /// the dialog silently or wedges the app.
    static func tabNeedsCloseConfirmation(_ tab: TabModel) -> Bool {
        shouldWarnBeforeClose(tab)
    }

    // MARK: - Draft recovery

    /// Two paths off the recovery sheet:
    ///   - URL-backed (metadata.sourceBookmark): re-attach the URL,
    ///     apply drafted text on top (dirty), seed baseline with the
    ///     on-disk content so the gutter highlights only the unsaved
    ///     deltas.
    ///   - Untitled: bytes load into a fresh Untitled tab; `draftURL`
    ///     is inherited so the next autosave overwrites the same file
    ///     instead of orphaning the old one.
    static func recoverDraft(_ draft: DraftRecord) {
        guard let session = Self.session else { return }
        let text = (try? String(contentsOf: draft.url, encoding: .utf8))
            ?? (try? String(contentsOf: draft.url, encoding: .isoLatin1))
            ?? ""
        let tab = session.newTab(kind: .editor)
        tab.document.text = text
        tab.document.isDirty = true
        tab.document.draftURL = draft.url
        tab.state.text = text

        if let bookmark = draft.metadata?.sourceBookmark,
           let resolved = resolveBookmark(bookmark) {
            tab.document.fileURL = resolved.url
            tab.state.fileURL = resolved.url
            tab.state.languageIdentifier = LanguageRegistry.identifier(for: resolved.url)
            if let rawEncoding = draft.metadata?.sourceEncodingRaw {
                let encoding = String.Encoding(rawValue: rawEncoding)
                tab.document.fileEncoding = FileEncoding(encoding: encoding)
                tab.state.fileEncoding = tab.document.fileEncoding
            }
            // Best-effort baseline: if the file is unreadable (perm
            // flip, deleted), fall back to "" so every recovered
            // line shows as added.
            let onDisk = (try? String(contentsOf: resolved.url, encoding: .utf8))
                ?? (try? String(contentsOf: resolved.url, encoding: .isoLatin1))
                ?? ""
            tab.state.savedBaselineText = onDisk
            if resolved.isStale {
                // Bookmark may no longer match (file moved, provider
                // re-indexed) — refresh on next autosave.
                tab.document.draftURL = draft.url
            }
        } else {
            tab.state.savedBaselineText = ""
        }
    }

    /// `nil` when the file no longer exists or the bookmark won't
    /// resolve.
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

    // MARK: - Duplicate / rename

    static func duplicateCurrentTab() {
        guard let session = Self.session else { return }
        let source = session.activeTab
        // Pull engine-live text — `document.text` lags by 300 ms and
        // a Duplicate right after typing would copy stale bytes.
        let snapshot = source.state.textView?.text ?? source.document.text
        let language = source.state.languageIdentifier
        let encoding = source.document.fileEncoding
        let lineEnding = source.document.lineEnding
        let tab = session.newTab()
        tab.document.text = snapshot
        tab.document.isDirty = true
        tab.document.fileEncoding = encoding
        tab.document.lineEnding = lineEnding
        tab.state.text = snapshot
        tab.state.languageIdentifier = language
        tab.state.fileEncoding = encoding
        tab.state.lineEnding = lineEnding
    }

    /// Preserves the original extension unless the user typed one
    /// explicitly. Renames on disk and updates both `fileURL` mirrors
    /// so the rest of the app picks up the new path immediately.
    static func renameCurrentFile(to newName: String) {
        guard let session = Self.session else { return }
        let document = session.activeTab.document
        let state = session.activeTab.state
        guard let oldURL = document.fileURL else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Typed dot = explicit override; otherwise inherit the old
        // extension.
        let finalName: String
        if trimmed.contains(".") {
            finalName = trimmed
        } else {
            let ext = oldURL.pathExtension
            finalName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        }
        guard finalName != oldURL.lastPathComponent else { return }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(finalName)
        let scoped = oldURL.startAccessingSecurityScopedResource()
        defer { if scoped { oldURL.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            document.fileURL = newURL
            state.fileURL = newURL
            RecentFilesStore.shared.record(newURL)
        } catch {
            Self.context.editing.openErrorMessage =
                "Couldn't rename \(oldURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Navigation among tabs

    static func nextTab() {
        Self.context.scenes.currentSession?.selectNextTab()
    }

    static func previousTab() {
        Self.context.scenes.currentSession?.selectPreviousTab()
    }

    static func selectTab(at position: Int) {
        Self.context.scenes.currentSession?.selectTab(at: position)
    }

    static func pinCurrentTab() {
        guard let session = Self.session else { return }
        session.togglePinned(session.selectedTabID)
    }

    static func closeOtherTabs() {
        guard let session = Self.session else { return }
        requestCloseOtherTabs(except: session.selectedTabID, in: session)
    }

    static func closeTabsToRight() {
        guard let session = Self.session else { return }
        requestCloseTabsToRight(of: session.selectedTabID, in: session)
    }

    // MARK: - Batch close (Close Other Tabs / Right / All)

    /// Route every "close many tabs" entry through one funnel so the
    /// unsaved-changes dialog is consistent. The dialog fires only
    /// when at least one of the tabs in the closing set is dirty;
    /// clean batches go through immediately.
    static func requestCloseOtherTabs(except keepID: UUID, in session: EditorSession) {
        let victims = session.tabs.filter { $0.id != keepID && !$0.isPinned }
        requestCloseTabs(victims, in: session, description: descriptor(for: victims.count, kind: .other))
    }

    static func requestCloseTabsToRight(of pivotID: UUID, in session: EditorSession) {
        guard let pivot = session.tabs.firstIndex(where: { $0.id == pivotID }) else { return }
        let victims = session.tabs[(pivot + 1)...].filter { !$0.isPinned }
        requestCloseTabs(Array(victims), in: session, description: descriptor(for: victims.count, kind: .right))
    }

    static func requestCloseAllTabs(in session: EditorSession) {
        // Pinned tabs are exempt — matches the Safari semantics
        // every other batch-close command in the app follows.
        let victims = session.tabs.filter { !$0.isPinned }
        requestCloseTabs(victims, in: session, description: descriptor(for: victims.count, kind: .all))
    }

    private enum BatchKind { case other, right, all }

    private static func descriptor(for count: Int, kind: BatchKind) -> String {
        let plural = (count == 1 ? "tab" : "tabs")
        switch kind {
        case .other: return count == 1 ? "Close 1 other tab" : "Close \(count) other tabs"
        case .right: return "Close \(count) \(plural) to the right"
        case .all:   return count == 1 ? "Close 1 tab" : "Close all \(count) tabs"
        }
    }

    private static func requestCloseTabs(_ victims: [TabModel], in session: EditorSession, description: String) {
        guard !victims.isEmpty else { return }
        let dirty = victims.filter(shouldWarnBeforeClose)
        if dirty.isEmpty {
            for tab in victims { session.closeTab(tab.id) }
            return
        }
        Self.context.editing.pendingBatchClose = PendingBatchClose(
            sessionID: ObjectIdentifier(session),
            tabIDs: victims.map(\.id),
            description: description,
            dirtyCount: dirty.count
        )
    }

    /// "Discard All" path — wipes scratch + draft for every dirty tab
    /// so the bytes can't resurrect from the launcher or ⇧⌘T.
    static func confirmBatchDiscard(_ pending: PendingBatchClose) {
        defer { Self.context.editing.pendingBatchClose = nil }
        guard let session = resolveSession(for: pending) else { return }
        for tabID in pending.tabIDs {
            guard let tab = session.tabs.first(where: { $0.id == tabID }) else { continue }
            tab.document.deleteScratchFile()
            session.closeTab(tabID, disposition: .discard)
        }
    }

    /// "Save All to Drafts" — autosave the live buffer for every
    /// dirty tab (URL-backed gets a draft pinned to its source;
    /// untitled goes to the recovery pool), then close everything
    /// with `.archive` disposition so ⇧⌘T can resurrect them too.
    static func confirmBatchSaveAsDrafts(_ pending: PendingBatchClose) {
        defer { Self.context.editing.pendingBatchClose = nil }
        guard let session = resolveSession(for: pending) else { return }
        for tabID in pending.tabIDs {
            guard let tab = session.tabs.first(where: { $0.id == tabID }) else { continue }
            snapshotDraft(for: tab)
            session.closeTab(tabID)
        }
    }

    static func cancelBatchClose() {
        Self.context.editing.pendingBatchClose = nil
    }

    /// Resolves the originating session for a PendingBatchClose,
    /// matching by identity so the dialog hits the right window
    /// even after focus shifts.
    private static func resolveSession(for pending: PendingBatchClose) -> EditorSession? {
        Self.context.scenes.allOpenSessions.first { ObjectIdentifier($0) == pending.sessionID }
    }

    /// Reopen the most-recently closed tab in the active session.
    /// File-backed tabs route through the standard open path so
    /// security-scoped access and revision tracking re-initialize
    /// cleanly. Untitled buffers are rehydrated from the text
    /// snapshot taken at close time.
    static func reopenLastClosedTab() {
        guard let session = Self.session,
              let record = session.popRecentlyClosed()
        else { return }
        reopenClosedTab(record)
    }

    static func reopenClosedTab(_ record: ClosedTabRecord) {
        guard let session = Self.session else { return }
        if let url = record.fileURL {
            Self.context.scenes.routeOpenURL?(url)
            return
        }
        let tab = session.newTab(kind: .editor)
        if let snapshot = record.unsavedSnapshot {
            tab.document.text = snapshot
            tab.document.isDirty = true
            tab.state.text = snapshot
        }
    }
}
