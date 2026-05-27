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

    /// Safari ⌘W parity: close the tab if there's more than one,
    /// else close the window. Dirty buffers always route through the
    /// confirm dialog; its handlers tear the window down when the
    /// last tab resolves.
    static func closeActiveTab() {
        guard let session = Self.session,
              let tab = session.tabs.first(where: { $0.id == session.selectedTabID }) else { return }
        if session.tabs.count > 1 {
            requestCloseTab(session.selectedTabID, in: session)
            return
        }
        // Last tab: dirty → confirm dialog (resolve handler tears
        // the window down); clean → close immediately on iPad,
        // swallow ⌘W on iPhone (single-window).
        if shouldWarnBeforeClose(tab) {
            requestCloseTab(session.selectedTabID, in: session)
            return
        }
        destroyForegroundWindowScene()
    }

    /// iPad-only; iPhone has one scene and the system request is a
    /// no-op there.
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
        let wasLastTab = (session.tabs.count == 1)
        _ = session.closeTab(pending.tabID, disposition: .discard)
        if wasLastTab { destroyForegroundWindowScene() }
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
        let wasLastTab = (session.tabs.count == 1)
        _ = session.closeTab(pending.tabID)
        Self.context.editing.pendingClose = nil
        if wasLastTab { destroyForegroundWindowScene() }
    }

    static func cancelPendingClose() {
        Self.context.editing.pendingClose = nil
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
        session.closeOtherTabs(except: session.selectedTabID)
    }

    static func closeTabsToRight() {
        guard let session = Self.session else { return }
        session.closeTabsToRight(of: session.selectedTabID)
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
