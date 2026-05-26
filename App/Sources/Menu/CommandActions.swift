import SwiftUI
import AVFoundation
import FileEncoding
import LineEnding
import LineSort

/// Free-standing menu actions, callable from both the menu bar and the
/// command palette. All actions read the current editor via
/// `Self.context.scenes.currentEditor`.
@MainActor
enum CommandActions {

    // MARK: - Sheets

    static func presentSheet(_ sheet: EditorSheet) {
        Self.context.editing.presentedSheet = sheet
    }

    // MARK: - Window / file commands

    /// Spawn a brand-new editor scene. The freshly-opened window picks
    /// the user's default launch behaviour (blank doc or open picker).
    static func newWindow() {
        Self.context.scenes.openWindowAction?(.editor)
    }

    /// Add a tab to the currently focused window's session. No-op when
    /// no editor window is active. Also surfaces the drafts-recovery
    /// sheet if any recoverable drafts exist — by spec, every user-
    /// initiated new tab/window offers recovery first so an unsaved
    /// draft isn't accidentally buried behind a fresh blank surface.
    static func newTab() {
        Self.context.scenes.currentSession?.newTab()
        offerDraftsIfAvailable()
    }

    /// Internal helper: show the drafts-recovery sheet on the
    /// currently-focused scene if any drafts exist. Centralized so
    /// every "user just opened a new surface" entry point uses the
    /// same gate.
    static func offerDraftsIfAvailable() {
        guard !DraftsStore.shared.loadAll().isEmpty else { return }
        Self.context.editing.presentedSheet = .draftsRecovery
    }

    static func openFile() {
        Self.context.pickers.pending = .open
    }

    static func saveFile() {
        Self.context.editing.saveCurrentDocument?()
    }

    static func saveFileAs() {
        Self.context.pickers.pending = .saveAs
    }

    static func revertToSaved() {
        Self.context.editing.revertRequestCount += 1
    }

    static func presentPreferences() {
        if DeviceIdiom.isPhone {
            Self.context.editing.presentedSheet = .preferences
        } else {
            Self.context.scenes.openWindowAction?(.preferences)
        }
    }

    /// Presents the command palette as a sheet on the active editor
    /// scene.
    static func presentCommandPalette() {
        Self.context.editing.presentedSheet = .commandPalette
    }

    /// Opens the file browser. In window-destination mode it spawns
    /// the dedicated browser scene (one window per pick). In tab-
    /// destination mode it presents the browser as a sheet on the
    /// active editor — picks add tabs to the current session, which
    /// matches the user's "everything in this window" intent.
    static func presentFileBrowser() {
        switch DocumentDestination.current() {
        case .window:
            Self.context.scenes.requestOpenWindow(.fileBrowser)
            Self.context.scenes.openWindowAction?(.fileBrowser)
        case .tab:
            Self.context.editing.presentedSheet = .fileBrowser
        }
    }

    /// "Open in New Tab…" / "Open in New Window…" menu entries — set
    /// a one-shot destination override so this open flow ignores the
    /// persistent preference, then routes through the standard
    /// presenter. The override is cleared by `EditorScene.route(open:)`
    /// once the picked URL has landed.
    static func presentFileBrowser(forceDestination destination: DocumentDestination) {
        Self.context.pending.nextOpenDestinationOverride = destination
        presentFileBrowser()
    }

    /// "Open in New Tab…" — spawn a fresh tab whose content IS the
    /// file browser (UIDocumentBrowserViewController inline). When
    /// the user picks a file, EditorScene's tab-browser pick handler
    /// transitions that same tab back to `.editor` with the URL
    /// loaded, so the browser never takes over the whole window.
    /// Falls back to the legacy sheet path if no session is mounted
    /// (cold-start race).
    static func presentFileBrowserInNewTab() {
        guard let session = Self.session else {
            presentFileBrowser(forceDestination: .tab)
            return
        }
        session.newFileBrowserTab()
    }

    static func presentFileBrowserInNewWindow() {
        presentFileBrowser(forceDestination: .window)
    }

    // MARK: - Undo / Redo

    /// Undo on the focused editor. EditorActions itself doesn't surface
    /// `undoManager`, but the only conformer is a UITextView subclass
    /// (EditorEngine.TextView), so a UIResponder cast is safe.
    static func undo() {
        (actions as? UIResponder)?.undoManager?.undo()
    }

    static func redo() {
        (actions as? UIResponder)?.undoManager?.redo()
    }

    // MARK: - Tabs

    /// Toggle the inline tab switcher on the focused scene. EditorScene
    /// observes `tabSwitcherActive` and runs the matchedGeometry morph
    /// (active editor shrinks into its grid card). ⇧⌘\\ from menu also
    /// hits this — second press dismisses, matching Safari.
    static func showTabSwitcher() {
        withAnimation(.appSwitcherMorph) {
            Self.context.editing.tabSwitcherActive.toggle()
        }
    }

    // MARK: - Same-file new window (split-view surrogate)

    /// Open the active document in a new window for side-by-side
    /// editing. Same URL, two scenes — iPad-native alternative to a
    /// true split view (which would need engine-side shared text
    /// storage). Untitled buffers are no-ops since there's no URL to
    /// reload from.
    static func openCurrentDocumentInNewWindow() {
        guard let url = Self.context.scenes.currentEditor?.fileURL else { return }
        Self.context.pending.newWindow = url
        Self.context.scenes.openWindowAction?(.editor)
    }

    // MARK: - Sidebar

    /// Toggle the per-window navigation sidebar (outline of markdown
    /// Compatibility shim — older code paths called `toggleSidebar`
    /// directly. Routed through `showOutline()` so there's only one
    /// implementation. Safe to delete once no callers remain.
    static func toggleSidebar() { showOutline() }

    /// Toggle the outline sidebar (markdown headings + tree-sitter
    /// symbols). The sidebar IS the outline panel, so "Show Outline"
    /// is the single user-facing name for this — previously there
    /// were two near-identical menu items ("Show Sidebar" + "Show
    /// Outline"), which surfaced the same panel and confused users.
    static func showOutline() {
        guard let state = Self.state else { return }
        withAnimation(.appSnappyPanel) {
            state.sidebarOpen.toggle()
        }
    }

    /// Toggle the trailing file-information inspector panel.
    /// Flips `state.inspectorOpen`, which `EditorView`'s `.inspector`
    /// modifier observes — both the menu (View ▸ Show File
    /// Information) and the status-bar ⓘ button share this same
    /// per-tab flag.
    static func toggleInspector() {
        guard let state = Self.state else { return }
        state.inspectorOpen.toggle()
    }

    // MARK: - Split editor view

    /// Toggle the split-view pane for the active tab. Two text
    /// views render side-by-side over the same document — each with
    /// its own cursor / scroll / selection — so the user can compare
    /// two regions of one file without opening it in a second window.
    /// Starts at a 50/50 split; the divider is draggable.
    /// One-command rotation through the three split states:
    /// off → horizontal → vertical → off. Surfaced as a single button
    /// in the editor bar so the user doesn't have to think about
    /// "toggle on" + "toggle orientation" as two separate concepts.
    /// Resets the divider to 50/50 on every state change so a
    /// width→height aspect flip doesn't leave a sliver pane.
    static func cycleSplitView() {
        guard let state = Self.state else { return }
        withAnimation(.appSnappyPanel) {
            switch (state.splitOpen, state.splitOrientation) {
            case (false, _):
                state.splitOpen = true
                state.splitOrientation = .horizontal
            case (true, .horizontal):
                state.splitOrientation = .vertical
            case (true, .vertical):
                state.splitOpen = false
            }
            state.splitFraction = 0.5
        }
    }

    /// Read the active editor's split state for icon / accessibility
    /// labelling on the cycle button. Returns nil when there's no
    /// active editor (menu/palette won't surface the button then).
    static func currentSplitState() -> (open: Bool, orientation: SplitOrientation)? {
        guard let state = Self.state else { return nil }
        return (state.splitOpen, state.splitOrientation)
    }

    // MARK: - Fold Selection
    //
    // "Hide Lines" was NPP-style line concealment. Users found that
    // confusing — folding implies a structural marker and the
    // language gutter only shows fold widgets at auto-detected
    // points. "Fold Selection" gives users explicit folding over a
    // chosen range without overloading "hide", and the effect is
    // identical to language folding (toggle via Unfold All).

    /// Fold every line touched by the selection (or the current line
    /// if empty). Same engine call as language folding — just driven
    /// by the user's selection instead of a tree-sitter fold marker.
    static func foldSelection() {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let selection = textView.selectedRange
        let block = nsText.lineRange(for: selection)
        // Convert character range → 0-based line index range in one
        // pass. The old implementation called `lineNumber(forCharacterAt:)`
        // twice, each rescanning from offset 0 — O(N²) on large docs
        // where Fold Selection should be cheap.
        let endChar = max(block.location, block.location + block.length - 1)
        let lines = lineNumbers(forCharactersAt: [block.location, endChar], in: nsText)
        guard lines.count == 2, lines[0] <= lines[1] else { return }
        let body = lines[0]...lines[1]
        textView.setLinesFolded(true, range: body)
        // Record so `Coordinator.refreshFoldableRegions` re-emits a
        // FoldableRegion at the line above — the engine then paints
        // its native gutter indicator (theme-aware, properly inside
        // the gutter) instead of relying on our prior custom overlay.
        state?.userFoldedBodyRanges.insert(body)
    }

    // (showAllHiddenLines removed — Unfold All in the Folding
    // submenu handles it.)

    /// One-pass line-index lookup for an arbitrary set of character
    /// offsets. Output order matches input order. The previous
    /// per-offset helper re-walked the buffer from 0 each call,
    /// so callers that needed two offsets paid O(N²); this collapses
    /// them to O(N + k log k) where k = offset count.
    private static func lineNumbers(forCharactersAt offsets: [Int],
                                     in nsText: NSString) -> [Int] {
        let sorted = offsets.enumerated().sorted { $0.element < $1.element }
        var results = [Int](repeating: 0, count: offsets.count)
        var line = 0, scan = 0, cursor = 0
        while scan < nsText.length, cursor < sorted.count {
            let lr = nsText.lineRange(for: NSRange(location: scan, length: 0))
            while cursor < sorted.count, sorted[cursor].element < lr.location + lr.length {
                results[sorted[cursor].offset] = line
                cursor += 1
            }
            scan = lr.location + lr.length
            line += 1
        }
        // Any offset past the last newline lands on the final line.
        while cursor < sorted.count {
            results[sorted[cursor].offset] = line
            cursor += 1
        }
        return results
    }

    /// "Move Tab to New Window" — detach `tabID` from its current
    /// session and request a fresh editor scene that will adopt it
    /// (via `Self.context.pending.adoptedTab`) in place of its
    /// default blank tab. `toNewWindow:` is currently the only mode;
    /// the parameter exists so a future "Move to Other Window"
    /// picker can reuse the same entry point.
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

    /// Safari ⌘W parity: close the active tab if there's more than
    /// one; otherwise close the foreground window scene. Dirty tabs
    /// route through `requestCloseTab` first so the user sees the
    /// unsaved-changes confirmation; the confirm handlers then
    /// detect the "session has 0 closable tabs left" case and tear
    /// down the window after Discard / Save resolves.
    static func closeActiveTab() {
        guard let session = Self.session,
              let tab = session.tabs.first(where: { $0.id == session.selectedTabID }) else { return }
        if session.tabs.count > 1 {
            requestCloseTab(session.selectedTabID, in: session)
            return
        }
        // Last tab in the window. Dirty buffer → show the same
        // confirm dialog and let the resolve path destroy the
        // window. Clean buffer → close the window immediately on
        // multi-window devices; on iPhone there's nothing to
        // destroy (single-window) so swallow ⌘W.
        if shouldWarnBeforeClose(tab) {
            requestCloseTab(session.selectedTabID, in: session)
            return
        }
        destroyForegroundWindowScene()
    }

    /// Resolve the foreground scene from UIApplication's connected
    /// list and ask the system to tear it down. iPad / multi-window
    /// device only — on iPhone there's only one scene and the
    /// request is a no-op.
    static func destroyForegroundWindowScene() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) else { return }
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: nil
        )
    }

    /// Public entry point for "the user asked to close this tab."
    /// Routes through a confirmation dialog when the tab has unsaved
    /// content; closes directly otherwise. Use this instead of
    /// `session.closeTab(_:)` from any UI surface (tab pill ×,
    /// switcher swipe-to-close, context menu, ⌘W) so the warning
    /// fires uniformly.
    static func requestCloseTab(_ tabID: UUID, in session: EditorSession) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else { return }
        if shouldWarnBeforeClose(tab) {
            Self.context.editing.pendingClose = PendingClose(
                sessionID: ObjectIdentifier(session),
                tabID: tabID,
                displayName: tab.document.fileURL?.lastPathComponent ?? "Untitled",
                isUntitled: tab.document.fileURL == nil
            )
        } else {
            _ = session.closeTab(tabID)
        }
    }

    /// Discard-and-close confirmed by the user. Bypasses the warning
    /// and uses `.discard` disposition so the buffer is NOT archived
    /// to ClosedTabsStore — a deliberate throw-away must not be
    /// resurrectable via ⇧⌘T. Also drops the per-doc scratch shadow
    /// so abandoned bytes don't sit alongside the source file. If
    /// this was the last tab, tear down the window scene.
    static func confirmDiscardAndClose(_ pending: PendingClose) {
        defer { Self.context.editing.pendingClose = nil }
        guard let (session, tab) = Self.resolveSession(for: pending) else { return }
        tab.document.deleteScratchFile()
        let wasLastTab = (session.tabs.count == 1)
        _ = session.closeTab(pending.tabID, disposition: .discard)
        if wasLastTab { destroyForegroundWindowScene() }
    }

    /// User picked Save & Close in the unsaved-changes dialog. For
    /// URL-backed docs this saves to disk then closes; for untitled
    /// docs it routes to Save As (tab stays open until the user picks
    /// a location). If the save itself fails (encoding error, disk
    /// full, expired security-scoped resource), surface the error
    /// and KEEP the tab open — closing would silently destroy the
    /// buffer.
    static func confirmSaveAndClose(_ pending: PendingClose) {
        guard let (session, tab) = Self.resolveSession(for: pending) else {
            Self.context.editing.pendingClose = nil
            return
        }
        guard tab.document.fileURL != nil else {
            // Untitled — route to Save As. The tab stays open; the
            // user picks a location, the save flow runs, and they
            // can re-trigger close afterwards.
            Self.context.pickers.pending = .saveAs
            Self.context.editing.pendingClose = nil
            return
        }
        do {
            try tab.document.save()
        } catch {
            Self.context.editing.openErrorMessage =
                "Couldn't save \(pending.displayName): \(error.localizedDescription)"
            // Keep the tab open so the user can retry / Save As.
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

    /// Look up the (session, tab) pair referenced by a PendingClose.
    /// Both `confirmSaveAndClose` and `confirmDiscardAndClose` need
    /// it; centralizing kills the matching pyramid and ensures both
    /// paths reach the same definition of "the targeted tab."
    private static func resolveSession(for pending: PendingClose) -> (EditorSession, TabModel)? {
        let sessions = Self.context.scenes.allOpenSessions
        guard let session = sessions.first(where: { ObjectIdentifier($0) == pending.sessionID }),
              let tab = session.tabs.first(where: { $0.id == pending.tabID })
        else { return nil }
        return (session, tab)
    }

    /// Warning gate: untitled buffers with any content, or saved
    /// files with unsaved edits, get a confirmation. Empty untitled
    /// scratches close silently — losing zero bytes isn't worth a
    /// dialog.
    private static func shouldWarnBeforeClose(_ tab: TabModel) -> Bool {
        // `document.text` is a 300 ms-debounced snapshot. A user who
        // types a single character into an untitled window and then
        // immediately hits ⌘W (or the tab's ×) would otherwise sail
        // past the warning because the debounce hadn't fired yet.
        // Pull the engine's live buffer when it's reachable.
        let liveText = tab.state.textView?.text ?? tab.document.text
        if tab.document.fileURL == nil {
            return !liveText.isEmpty
        }
        return tab.document.isDirty
    }

    /// Public peek at the same predicate — used by UI surfaces (tab
    /// switcher, palette) that need to know whether closing will
    /// pop a confirmation, so they can dismiss themselves first.
    /// iOS only hosts one modal per scene; presenting the dialog
    /// from under another sheet would either silently drop it (data
    /// loss) or wedge the app.
    static func tabNeedsCloseConfirmation(_ tab: TabModel) -> Bool {
        shouldWarnBeforeClose(tab)
    }

    /// "Duplicate File" — spawn a new untitled tab in the current
    /// session whose buffer is a copy of the active tab's text.
    /// Useful for branching from a known state without touching the
    /// original. The duplicate starts dirty so the user is reminded
    /// it isn't saved anywhere.
    /// Open a recovered draft from the launch-time
    /// `DraftsRecoverySheet`. Two paths:
    ///
    ///   - **URL-backed draft** (metadata has a source bookmark):
    ///     resolve the bookmark, set `fileURL` so the tab is tied
    ///     to the original location, then apply the drafted text
    ///     on top (marking dirty so the user knows the on-disk
    ///     file still holds the pre-edit bytes). `savedBaselineText`
    ///     is seeded with the file's current on-disk content so the
    ///     change-history gutter highlights *only* the unsaved
    ///     edits vs. the file on disk.
    ///   - **Untitled draft** (no metadata): open as a fresh
    ///     Untitled tab with the bytes loaded. `fileURL` stays nil
    ///     so the title shows "edited"; `draftURL` is inherited so
    ///     subsequent autosaves overwrite the SAME on-disk draft
    ///     file rather than orphaning the old one.
    static func recoverDraft(_ draft: DraftRecord) {
        guard let session = Self.session else { return }
        let text = (try? String(contentsOf: draft.url, encoding: .utf8))
            ?? (try? String(contentsOf: draft.url, encoding: .isoLatin1))
            ?? ""
        let tab = session.newTab()
        tab.document.text = text
        tab.document.isDirty = true
        tab.document.draftURL = draft.url
        tab.state.text = text

        if let bookmark = draft.metadata?.sourceBookmark,
           let resolved = resolveBookmark(bookmark) {
            // URL-backed: re-attach the source, seed baseline with
            // the file's on-disk content (so unsaved deltas show
            // in the gutter), and inherit the saved encoding.
            tab.document.fileURL = resolved.url
            tab.state.fileURL = resolved.url
            tab.state.languageIdentifier = LanguageRegistry.identifier(for: resolved.url)
            if let rawEncoding = draft.metadata?.sourceEncodingRaw {
                let encoding = String.Encoding(rawValue: rawEncoding)
                tab.document.fileEncoding = FileEncoding(encoding: encoding)
                tab.state.fileEncoding = tab.document.fileEncoding
            }
            // Pull the current on-disk text for the diff baseline.
            // Best-effort: if the file is unreadable (perm flip,
            // user deleted it), fall back to "" so every line in
            // the recovered draft shows as added.
            let onDisk = (try? String(contentsOf: resolved.url, encoding: .utf8))
                ?? (try? String(contentsOf: resolved.url, encoding: .isoLatin1))
                ?? ""
            tab.state.savedBaselineText = onDisk
            if resolved.isStale {
                // Refresh the bookmark on next autosave — the
                // resolved URL may no longer match what was
                // bookmarked (file moved, provider re-indexed).
                tab.document.draftURL = draft.url
            }
        } else {
            // Untitled draft: fresh tab, no associated URL.
            tab.state.savedBaselineText = ""
        }
    }

    /// Resolve a security-scoped bookmark to a usable URL. Returns
    /// `nil` if the file no longer exists or the bookmark is
    /// unresolvable.
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

    static func duplicateCurrentTab() {
        guard let session = Self.session else { return }
        let source = session.activeTab
        // Pull live text from the engine first — `document.text` is
        // a 300 ms-debounced snapshot, so a Duplicate fired right
        // after typing would otherwise copy stale bytes.
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

    /// Inline rename invoked by tapping the title bar. `newName` is
    /// the user's typed text; we preserve the original file extension
    /// unless the user typed one explicitly. Renames the file on
    /// disk and updates both `document.fileURL` and `state.fileURL`
    /// so the rest of the app picks up the new path immediately.
    static func renameCurrentFile(to newName: String) {
        guard let session = Self.session else { return }
        let document = session.activeTab.document
        let state = session.activeTab.state
        guard let oldURL = document.fileURL else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Preserve the original extension unless the user typed
        // a dot in the new name (in which case they're explicitly
        // overriding it).
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
        let tab = session.newTab()
        if let snapshot = record.unsavedSnapshot {
            tab.document.text = snapshot
            tab.document.isDirty = true
            tab.state.text = snapshot
        }
    }

    // MARK: - View setting toggles

    /// Generic toggle for a boolean view setting. Flips both the
    /// persisted preference (so other open windows pick it up via
    /// `@AppStorage`) and the currently focused editor's state.
    private static func toggleViewSetting(
        defaultsKey: String,
        statePath: ReferenceWritableKeyPath<EditorState, Bool>
    ) {
        let newValue = !UserDefaults.standard.bool(forKey: defaultsKey)
        UserDefaults.standard.set(newValue, forKey: defaultsKey)
        Self.context.scenes.currentEditor?[keyPath: statePath] = newValue
    }

    static func toggleShowLineNumbers() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.showLineNumbers, statePath: \.showLineNumbers)
    }
    static func toggleWrapLines() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.wrapLines, statePath: \.wrapLines)
    }
    static func toggleShowInvisibles() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.showInvisibles, statePath: \.showInvisibles)
    }
    static func toggleShowPageGuide() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.showPageGuide, statePath: \.showPageGuide)
    }
    static func toggleShowStatusBar() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.showStatusBar, statePath: \.showStatusBar)
    }
    static func toggleShowToolbar() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.showToolbar, statePath: \.showToolbar)
    }
    static func toggleLiveMatchHighlight() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.liveMatchHighlight, statePath: \.liveMatchHighlight)
    }
    static func toggleHighlightCurrentLine() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.highlightCurrentLine, statePath: \.highlightCurrentLine)
    }
    static func toggleHighlightMatchingBrackets() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.highlightMatchingBrackets, statePath: \.highlightMatchingBrackets)
    }
    static func toggleShowChangeHistoryGutter() {
        toggleViewSetting(defaultsKey: AppPreferenceKey.showChangeHistoryGutter, statePath: \.showChangeHistoryGutter)
    }

    // MARK: - Find

    /// Native UIKit find bar — UIFindInteraction's incremental
    /// search with live match highlighting and a match count.
    /// Lighter than the full Find/Replace sheet; routed to ⌥⌘F so
    /// ⌘F can stay on the more powerful sheet.
    static func presentSystemFindBar() {
        actions?.presentFindNavigator()
    }

    /// Opens the unified find / replace / query-replace sheet. The
    /// selection-seed is split into its own method so menu actions
    /// that route the sheet through `@FocusedValue` can seed first,
    /// then present via the focused-scene presenter.
    static func presentFindNavigator() {
        seedFindFromSelection()
        presentSheet(.findReplace)
    }

    /// Copies a single-line selection into the find query field. No-op
    /// for empty / multi-line selections so we don't blow away the
    /// user's current search string for a stray double-tap.
    static func seedFindFromSelection() {
        guard let textView = actions,
              textView.selectedRange.length > 0,
              let selected = textView.text(in: textView.selectedRange),
              !selected.contains("\n")
        else { return }
        Self.context.find.context.query = selected
    }

    /// Recursive search across a folder, the open tabs, or every
    /// editor window. iPad presents it as its own scene so it stays
    /// on screen while the user clicks results; iPhone presents as
    /// a sheet on the active editor. `requestOpenWindow` is always
    /// called so the scene's onAppear restore-guard passes uniformly
    /// in either path.
    static func presentMultiFileSearch() {
        Self.context.scenes.requestOpenWindow(.multiFileSearch)
        if DeviceIdiom.isPhone {
            Self.context.editing.presentedSheet = .multiFileSearch
        } else {
            Self.context.scenes.openWindowAction?(.multiFileSearch)
        }
    }

    /// Steps the cursor to the next match using the persistent search
    /// context. Works whether or not the find sheet is open — keeps ⌘G
    /// useful after dismissing the sheet.
    static func findNext() {
        stepToMatch(forward: true)
    }

    static func findPrevious() {
        stepToMatch(forward: false)
    }

    static func findNextOccurrenceOfSelection() {
        actions?.findNextOccurrenceOfSelection()
        recordPositionIfJumped()
    }
    static func findPreviousOccurrenceOfSelection() {
        actions?.findPreviousOccurrenceOfSelection()
        recordPositionIfJumped()
    }

    /// Jumps to the first match in the document, ignoring the cursor's
    /// position. Wrap-around equivalent without confusion.
    static func findFirst() {
        guard let textView = actions else { return }
        let ctx = Self.context.find.context
        guard !ctx.query.isEmpty else { return }
        let length = (textView.text as NSString).length
        if let match = try? matchInDocument(context: ctx, forward: true, startingAt: 0, totalLength: length) {
            textView.setSelection(match.range)
            textView.scrollSelectionToVisible()
            recordPositionIfJumped()
        }
    }

    /// Replaces every match within the current selection only.
    static func replaceAllInSelection() {
        replaceAll(inRange: actions?.selectedRange)
    }

    /// Replaces every match from the cursor to the end of the document.
    static func replaceToEnd() {
        guard let textView = actions else { return }
        let cursor = textView.selectedRange.location
        let length = (textView.text as NSString).length
        guard cursor < length else { return }
        replaceAll(inRange: NSRange(location: cursor, length: length - cursor))
    }

    /// Shared implementation for "replace all within a fixed range".
    /// Used by Replace All in Selection and Replace to End so they share
    /// regex handling, case-sensitivity, and undo grouping.
    private static func replaceAll(inRange range: NSRange?) {
        guard let textView = actions, let range, range.length > 0 else { return }
        guard let original = textView.text(in: range) else { return }
        let ctx = Self.context.find.context
        guard !ctx.query.isEmpty else { return }
        do {
            let pattern = effectivePattern(for: ctx)
            let useRegex = ctx.useRegex || ctx.wholeWord
            let newText: String
            if useRegex {
                var opts: NSRegularExpression.Options = []
                if !ctx.caseSensitive { opts.insert(.caseInsensitive) }
                let re = try NSRegularExpression(pattern: pattern, options: opts)
                newText = re.stringByReplacingMatches(
                    in: original,
                    options: [],
                    range: NSRange(location: 0, length: (original as NSString).length),
                    withTemplate: ctx.replacement
                )
            } else {
                newText = original.replacingOccurrences(
                    of: ctx.query,
                    with: ctx.replacement,
                    options: ctx.caseSensitive ? [] : [.caseInsensitive]
                )
            }
            textView.replace(range, withText: newText)
            commitTextChange()
        } catch {
            // Invalid regex — silently no-op; sheet surfaces user errors.
        }
    }

    static func jumpToSelection() { actions?.scrollSelectionToVisible() }

    // MARK: - Find iteration

    static func stepToMatch(forward: Bool) {
        guard let textView = actions else { return }
        let ctx = Self.context.find.context
        guard !ctx.query.isEmpty else { return }
        let cursor = forward
            ? NSMaxRange(textView.selectedRange)
            : textView.selectedRange.location
        do {
            let length = (textView.text as NSString).length
            if let match = try matchInDocument(context: ctx, forward: forward, startingAt: cursor, totalLength: length) {
                textView.setSelection(match.range)
                textView.scrollSelectionToVisible()
                recordPositionIfJumped()
            } else if let wrap = try matchInDocument(
                context: ctx,
                forward: forward,
                startingAt: forward ? 0 : length,
                totalLength: length
            ) {
                textView.setSelection(wrap.range)
                textView.scrollSelectionToVisible()
                recordPositionIfJumped()
            }
        } catch {
            // Invalid regex etc. — surfaced by the sheet UI; nothing to do here.
        }
    }

    /// Compile the persistent context's pattern + find the first match at
    /// or after `cursor`. Returns nil if no match in the search range.
    static func matchInDocument(
        context: FindContext,
        forward: Bool,
        startingAt cursor: Int,
        totalLength: Int
    ) throws -> QueryReplaceMatch? {
        let pattern = effectivePattern(for: context)
        let useRegex = context.useRegex || context.wholeWord
        return try Self.nextQueryReplaceMatch(
            query: pattern,
            replacement: context.replacement,
            useRegex: useRegex,
            caseSensitive: context.caseSensitive,
            startingAt: forward ? cursor : 0,
            searchUpTo: forward ? totalLength : cursor,
            preferLast: !forward
        )
    }

    private static func effectivePattern(for context: FindContext) -> String {
        guard context.wholeWord else { return context.query }
        let inner = context.useRegex
            ? context.query
            : NSRegularExpression.escapedPattern(for: context.query)
        return #"\b"# + inner + #"\b"#
    }

    // MARK: - Selection / line ops

    static func selectCurrentWord()       { actions?.selectCurrentWord() }
    static func selectCurrentLine()       { actions?.selectCurrentLine() }
    static func indentSelection()         { actions?.shiftSelectionRight() }
    static func outdentSelection()        { actions?.shiftSelectionLeft() }
    static func moveLineUp()              { actions?.moveSelectedLinesUp() }
    static func moveLineDown()            { actions?.moveSelectedLinesDown() }

    static func duplicateLine() {
        actions?.duplicateCurrentLine()
        commitTextChange()
    }

    static func deleteLine() {
        actions?.deleteCurrentLines()
        commitTextChange()
    }

    // MARK: - Markdown formatting

    /// Wrap the selection with `**…**` (or insert empty paired markers
    /// at the cursor). ⌘B in the Markdown menu.
    static func markdownBold()    { markdownSurround(open: "**", close: "**") }
    static func markdownItalic()  { markdownSurround(open: "*",  close: "*")  }
    static func markdownCode()    { markdownSurround(open: "`",  close: "`")  }
    static func markdownStrike()  { markdownSurround(open: "~~", close: "~~") }

    /// Prefix every selected line with the corresponding `#` block —
    /// `markdownHeader(1)` writes `# ` etc. Re-running on an existing
    /// heading just stacks another marker on (intentional; users
    /// who want to demote rerun the action). Levels 1–6.
    static func markdownHeader(level: Int) {
        let clamped = max(1, min(6, level))
        let marker = String(repeating: "#", count: clamped) + " "
        applyLinePrefix { _ in marker }
    }

    static func markdownBlockquote() {
        applyLinePrefix { _ in "> " }
    }

    /// Insert a horizontal rule (`---`) on its own line. If the cursor
    /// is mid-line, we insert a newline first so the rule lives alone.
    static func markdownHorizontalRule() {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let cursor = textView.selectedRange.location
        let lineEnding = state?.lineEnding.string ?? "\n"
        let line = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let onBlankLine = nsText.substring(with: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let insertion: String
        if onBlankLine {
            insertion = "---\(lineEnding)"
            textView.replace(NSRange(location: line.location, length: 0), withText: insertion)
            textView.setSelection(NSRange(location: line.location + (insertion as NSString).length, length: 0))
        } else {
            insertion = "\(lineEnding)---\(lineEnding)"
            let endOfLine = line.location + line.length
            textView.replace(NSRange(location: endOfLine, length: 0), withText: insertion)
            textView.setSelection(NSRange(location: endOfLine + (insertion as NSString).length, length: 0))
        }
        commitTextChange()
    }

    /// Insert `[text](url)` around the selection. When nothing is
    /// selected, the cursor lands inside the empty `[]` so the user
    /// types the link text first.
    static func markdownLink() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            textView.replace(range, withText: "[](url)")
            textView.setSelection(NSRange(location: range.location + 1, length: 0))
        } else {
            let selected = (textView.text as NSString).substring(with: range)
            let wrapped = "[\(selected)](url)"
            textView.replace(range, withText: wrapped)
            // Highlight "url" so the user can replace it immediately.
            let urlStart = range.location + (selected as NSString).length + 3
            textView.setSelection(NSRange(location: urlStart, length: 3))
        }
        commitTextChange()
    }

    /// Insert `![alt](url)` around the selection. Empty: cursor lands
    /// on `alt`. With selection: selection becomes alt text and `url`
    /// is highlighted.
    static func markdownImage() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            textView.replace(range, withText: "![alt](url)")
            textView.setSelection(NSRange(location: range.location + 2, length: 3))
        } else {
            let selected = (textView.text as NSString).substring(with: range)
            let wrapped = "![\(selected)](url)"
            textView.replace(range, withText: wrapped)
            let urlStart = range.location + (selected as NSString).length + 4
            textView.setSelection(NSRange(location: urlStart, length: 3))
        }
        commitTextChange()
    }

    /// Open the "Insert Markdown Table" sheet.
    static func presentMarkdownTable() {
        presentSheet(.markdownTable)
    }

    /// Show the Markdown Preview for the current document. iPad and
    /// other multi-window devices get a real new scene (Stage Manager
    /// — friendly, can sit side-by-side with the editor). iPhone is
    /// single-window, so it gets a dismissable sheet on the current
    /// editor — opening a new scene there is a silent no-op.
    static func presentMarkdownPreview() {
        if DeviceIdiom.supportsMultipleWindows {
            Self.context.scenes.requestOpenWindow(.markdownPreview)
            Self.context.scenes.openWindowAction?(.markdownPreview)
        } else {
            presentSheet(.markdownPreview)
        }
    }

    /// Run a JavaScript transform slot by 1-based id. Looks up the
    /// slot in the shared store; no-op if the slot is empty or the
    /// id is out of range. Errors from inside the script surface via
    /// the standard error alert.
    static func runJSTransform(slotID: Int) {
        guard let slot = JSTransformStore.shared.slot(id: slotID) else { return }
        JSTransformRunner.run(slot)
    }

    /// Insert a footnote reference (`[^N]`) at the cursor and append
    /// the matching `[^N]: ` definition at the end of the document.
    /// `N` is the smallest unused integer footnote id in the buffer.
    /// Cursor lands at the end of the definition so the user can type
    /// the footnote body immediately.
    static func markdownFootnote() {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let lineEnding = state?.lineEnding.string ?? "\n"

        // Find the smallest unused integer id by scanning `[^N]`
        // references already in the buffer.
        var used = Set<Int>()
        if let pattern = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) {
            let matches = pattern.matches(in: textView.text,
                                          range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges >= 2 {
                if let n = Int(nsText.substring(with: match.range(at: 1))) {
                    used.insert(n)
                }
            }
        }
        var nextId = 1
        while used.contains(nextId) { nextId += 1 }

        let ref = "[^\(nextId)]"
        let cursor = textView.selectedRange
        textView.replace(cursor, withText: ref)
        // Build the definition; pad with newlines if the doc doesn't
        // already end on a fresh line, so the footnote sits at the
        // file's footer rather than wedged into the last paragraph.
        let textNow = textView.text as NSString
        let endsWithNL = textNow.length > 0 && textNow.substring(from: textNow.length - 1) == lineEnding
        let prefix = endsWithNL ? lineEnding : lineEnding + lineEnding
        let definition = "\(prefix)[^\(nextId)]: "
        let appendAt = textNow.length
        textView.replace(NSRange(location: appendAt, length: 0), withText: definition)
        // Land at the end of the new definition.
        let defEnd = appendAt + (definition as NSString).length
        textView.setSelection(NSRange(location: defEnd, length: 0))
        textView.scrollSelectionToVisible()
        commitTextChange()
    }

    /// Placement options for the Organize Footnotes flow — picked
    /// in `OrganizeFootnotesSheet`.
    enum FootnotePlacement {
        case endOfDocument
        case endOfParagraph
    }

    /// Re-number every footnote reference (`[^id]`) in the buffer
    /// based on appearance order in the body — the user may have
    /// inserted footnotes out of order — and move the matching
    /// definitions either to the end of the document or to the end
    /// of each paragraph that references them. Idempotent on a
    /// well-organized buffer.
    static func organizeFootnotes(placement: FootnotePlacement) {
        guard let textView = actions else { return }
        let original = textView.text
        let (body, defs) = Self.extractFootnoteDefinitions(from: original)
        // Build remap: old id → new sequential number based on first
        // appearance in body. Refs without a matching definition still
        // get renumbered (so a `[^foo]` typo stays consistent).
        let refOrder = Self.footnoteReferenceOrder(in: body)
        var remap: [String: String] = [:]
        for id in refOrder where remap[id] == nil {
            remap[id] = "\(remap.count + 1)"
        }
        let rewrittenBody = Self.applyFootnoteRemap(remap, to: body)
        let renamedDefs: [(id: String, content: String)] = defs.map { def in
            (remap[def.id] ?? def.id, def.content)
        }
        let defLookup = Dictionary(renamedDefs.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })

        let output: String
        switch placement {
        case .endOfDocument:
            let sorted = renamedDefs.sorted {
                (Int($0.id) ?? .max) < (Int($1.id) ?? .max)
            }
            let defsText = sorted.map { "[^\($0.id)]: \($0.content)" }.joined(separator: "\n")
            let trimmedBody = rewrittenBody.trimmingCharacters(in: .whitespacesAndNewlines)
            output = defsText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(defsText)\n"
        case .endOfParagraph:
            output = Self.placeFootnotesAfterParagraphs(body: rewrittenBody, defs: defLookup)
        }

        let full = NSRange(location: 0, length: (original as NSString).length)
        textView.replace(full, withText: output)
        commitTextChange()
    }

    /// Strips footnote definition lines (`[^id]: body…`) from the
    /// input. Continuation lines indented by 4 spaces or a tab join
    /// their definition. Returns the cleaned body plus the
    /// definitions in source order.
    private static func extractFootnoteDefinitions(from text: String) -> (body: String, defs: [(id: String, content: String)]) {
        let lines = text.components(separatedBy: "\n")
        var keep: [String] = []
        var defs: [(id: String, content: String)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let match = Self.footnoteDefinitionMatch(line) {
                var content = match.body
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    if next.hasPrefix("    ") || next.hasPrefix("\t") {
                        let trimmed = next.drop(while: { $0 == " " || $0 == "\t" })
                        content += "\n" + String(trimmed)
                        j += 1
                    } else { break }
                }
                defs.append((match.id, content))
                i = j
                continue
            }
            keep.append(line)
            i += 1
        }
        return (keep.joined(separator: "\n"), defs)
    }

    private static func footnoteDefinitionMatch(_ line: String) -> (id: String, body: String)? {
        guard line.hasPrefix("[^"), let closeBracket = line.range(of: "]:") else { return nil }
        let id = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket.lowerBound])
        let body = String(line[closeBracket.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (id, body)
    }

    /// Footnote reference ids (`[^id]`) in source order, allowing
    /// duplicates so the caller can decide whether to dedupe.
    private static func footnoteReferenceOrder(in body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Rewrites every `[^oldID]` in `text` to `[^newID]` using the
    /// remap. Ids missing from the remap are left untouched. Skips
    /// any match whose NSRange can't be converted back to a Swift
    /// Range in the in-flight mutated string — better to drop one
    /// rewrite than to crash on a surrogate-pair / BOM edge case.
    private static func applyFootnoteRemap(_ remap: [String: String], to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let id = ns.substring(with: match.range(at: 1))
            guard let mapped = remap[id] else { continue }
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: "[^\(mapped)]")
        }
        return result
    }

    /// Walks `body` paragraph-by-paragraph (split on blank lines).
    /// For each paragraph, finds new footnote ids referenced and
    /// inserts the matching definitions after it. IDs already placed
    /// in a prior paragraph are skipped to avoid duplicate defs.
    private static func placeFootnotesAfterParagraphs(body: String, defs: [String: String]) -> String {
        let paragraphs = body.components(separatedBy: "\n\n")
        var placed = Set<String>()
        var output: [String] = []
        for para in paragraphs {
            output.append(para)
            let ids = Self.footnoteReferenceOrder(in: para)
            var newIds: [String] = []
            for id in ids where !placed.contains(id) && defs[id] != nil {
                placed.insert(id)
                newIds.append(id)
            }
            if !newIds.isEmpty {
                let defLines = newIds.map { "[^\($0)]: \(defs[$0] ?? "")" }
                output.append(defLines.joined(separator: "\n"))
            }
        }
        return output.joined(separator: "\n\n")
    }

    // Shared wrap helper for the **bold** / *italic* / `code` / ~~strike~~
    // family. Selection-aware: empty selection drops the cursor between
    // the markers so the user can type the wrapped content directly.
    private static func markdownSurround(open: String, close: String) {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        let openLen = (open as NSString).length
        if range.length == 0 {
            textView.replace(range, withText: open + close)
            textView.setSelection(NSRange(location: range.location + openLen, length: 0))
        } else {
            let selected = (textView.text as NSString).substring(with: range)
            let wrapped = open + selected + close
            textView.replace(range, withText: wrapped)
            textView.setSelection(NSRange(location: range.location + openLen,
                                          length: (selected as NSString).length))
        }
        commitTextChange()
    }

    // MARK: - Markdown list conversion

    /// Prefix every line touched by the selection (or just the cursor's
    /// line, if the selection is empty) with `- `. Always applies the
    /// prefix — this is a "convert to list" action, distinct from the
    /// toggle behaviour the keyboard accessory bar uses.
    static func convertToBulletListDash() {
        applyLinePrefix { _ in "- " }
    }

    /// Same as the dash variant but uses `*` — common Markdown
    /// convention for emphasized lists.
    static func convertToBulletListStar() {
        applyLinePrefix { _ in "* " }
    }

    /// Number each line sequentially: `1. ` on the first line of the
    /// selection, `2. ` on the second, and so on. Numbering is based
    /// on the line's position within the selection, not the file —
    /// rerunning on an existing numbered list re-numbers it.
    static func convertToNumberedList() {
        applyLinePrefix { idx in "\(idx + 1). " }
    }

    /// Walks each line touched by the selection and prepends the
    /// result of `prefixForLine(index)`. Edits are applied bottom-up
    /// so the line-start offsets stay valid as we go.
    private static func applyLinePrefix(_ prefixForLine: (Int) -> String) {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let selection = textView.selectedRange
        let block = nsText.lineRange(for: selection)

        var lineStarts: [Int] = []
        var scan = block.location
        while scan < block.location + block.length {
            lineStarts.append(scan)
            let lr = nsText.lineRange(for: NSRange(location: scan, length: 0))
            scan = lr.location + lr.length
        }
        if lineStarts.isEmpty { lineStarts = [block.location] }

        var totalInserted = 0
        var firstLineInserted = 0
        for (i, start) in lineStarts.enumerated().reversed() {
            let prefix = prefixForLine(i)
            let prefixLen = (prefix as NSString).length
            textView.replace(NSRange(location: start, length: 0), withText: prefix)
            totalInserted += prefixLen
            if i == 0 { firstLineInserted = prefixLen }
        }
        // Keep the selection aligned with the inserted text — anchor
        // shifts by the first line's prefix; length grows by the
        // total minus that anchor shift (so trailing edge tracks).
        let newLocation = selection.location + firstLineInserted
        let newLength = selection.length + (totalInserted - firstLineInserted)
        textView.setSelection(NSRange(location: newLocation, length: newLength))
        commitTextChange()
    }


    /// Removes one leading `>` (and the optional space after it) from
    /// every selected line. Useful for unwrapping email/Markdown quotes.
    static func stripQuoteLevel() {
        transformSelection { text in
            let nl = state?.lineEnding.string ?? "\n"
            let lines = text.components(separatedBy: nl)
            let stripped = lines.map { line -> String in
                var s = line
                // BBEdit's "Strip Quotes" removes all leading quote
                // markers, not just one level. Loop until none left.
                while s.hasPrefix("> ") { s.removeFirst(2) }
                while s.hasPrefix(">")  { s.removeFirst() }
                return s
            }
            return stripped.joined(separator: nl)
        }
    }

    // MARK: - Line operations

    static func sortLines()      { presentSheet(.sortLines) }

    static func reverseLines() {
        applyToWholeText { text in
            let separator = state?.lineEnding.string ?? "\n"
            return text.components(separatedBy: separator).reversed().joined(separator: separator)
        }
    }

    static func uniqueLines() {
        applyToWholeText { text in
            let separator = state?.lineEnding.string ?? "\n"
            var seen = Set<String>()
            var unique: [String] = []
            for line in text.components(separatedBy: separator) where seen.insert(line).inserted {
                unique.append(line)
            }
            return unique.joined(separator: separator)
        }
    }

    static func trimTrailingWhitespace() {
        applyToWholeText { text in
            let separator = state?.lineEnding.string ?? "\n"
            return text
                .components(separatedBy: separator)
                .map { line -> String in
                    var s = line
                    while let last = s.last, last == " " || last == "\t" { s.removeLast() }
                    return s
                }
                .joined(separator: separator)
        }
    }

    /// Collapse line breaks *within* paragraphs into single spaces.
    /// Paragraphs are delimited by blank lines (one or more empty
    /// lines); those delimiters are preserved. Useful for unwrapping
    /// hard-wrapped prose into single-line paragraphs.
    static func removeLinebreaks() {
        transformSelection { text in
            let nl = state?.lineEnding.string ?? "\n"
            let paragraphs = Transformations.splitParagraphs(text)
            let joined = paragraphs.map { paragraph -> String in
                paragraph
                    .components(separatedBy: CharacterSet.newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            return joined.joined(separator: nl + nl)
        }
    }

    /// Word-wrap each paragraph to ~72 columns. Whitespace inside each
    /// paragraph is normalised to single spaces first, then greedy-
    /// packed into lines that don't exceed the wrap column.
    static func addLinebreaks() {
        transformSelection { text in
            let nl = state?.lineEnding.string ?? "\n"
            let paragraphs = Transformations.splitParagraphs(text)
            let wrapped = paragraphs.map { Transformations.wordWrap($0, to: 72, separator: nl) }
            return wrapped.joined(separator: nl + nl)
        }
    }

    static func educateQuotes()    { transformSelection(Transformations.educateQuotes) }
    static func straightenQuotes() { transformSelection(Transformations.straightenQuotes) }

    static func tabsToSpaces() {
        let width = max(1, state?.indentWidth ?? 4)
        transformSelection { Transformations.tabsToSpaces($0, tabWidth: width) }
    }

    static func spacesToTabs() {
        let width = max(1, state?.indentWidth ?? 4)
        transformSelection { Transformations.spacesToTabs($0, tabWidth: width) }
    }

    static func normalizeSpaces()        { transformSelection(Transformations.normalizeSpaces) }
    /// Default Zap Gremlins (no UI): strips ASCII control + invisible
    /// Unicode, deletes them outright. Kept for the toolbar quick
    /// action and as the action behind the bare "Zap Gremlins" menu
    /// item. Use `presentZapGremlins` for the configurable sheet.
    static func zapGremlins() { transformSelection(Transformations.zapGremlins) }

    /// Apply a configurable Zap Gremlins pass, called by the sheet
    /// after the user picks categories and replacement.
    static func zapGremlinsConfigured(options: ZapGremlinsOptions) {
        transformSelection { Transformations.zapGremlins($0, options: options) }
    }

    /// Opens the BBEdit-style Zap Gremlins… dialog so the user can
    /// pick categories and replacement before zapping.
    static func presentZapGremlins() { presentSheet(.zapGremlins) }

    /// Browse and restore previous on-disk states of the current
    /// document. No-op for untitled buffers (no URL → no revisions).
    static func presentRevisions() { presentSheet(.revisions) }
    static func stripDiacritics()        { transformSelection(Transformations.stripDiacritics) }
    static func convertToASCII()         { transformSelection(Transformations.convertToASCII) }
    static func interpretEscapeSequences() { transformSelection(Transformations.interpretEscapeSequences) }
    static func escapeSpecialCharacters()  { transformSelection(Transformations.escapeSpecialCharacters) }
    static func addLineNumbers()         { transformSelection(Transformations.addLineNumbers) }
    static func removeLineNumbers()      { transformSelection(Transformations.removeLineNumbers) }
    static func removeBlankLines()       { transformSelection(Transformations.removeBlankLines) }
    static func increaseQuoteLevel()     { transformSelection(Transformations.increaseQuoteLevel) }
    static func decreaseQuoteLevel()     { transformSelection(Transformations.decreaseQuoteLevel) }

    /// Apply the document's current line-ending choice to every break
    /// in the buffer — useful after pasting from a source with mixed
    /// or different line endings.
    static func normalizeLineEndingsToDocument() {
        let ending = state?.lineEnding.string ?? "\n"
        applyToWholeText { Transformations.normalizeLineEndings($0, to: ending) }
    }

    // MARK: - Inserts

    static func insertLoremIpsum(paragraphs: Int) {
        let nl = state?.lineEnding.string ?? "\n"
        insertAtSelection(Transformations.lipsum(paragraphs: paragraphs, separator: nl + nl))
    }

    /// Form-feed (U+000C) — historical "next page" mark used by some
    /// printers and a handful of tools that paginate plain text.
    static func insertPageBreak() {
        insertAtSelection("\u{000C}")
    }

    // MARK: - Sheet triggers

    static func presentPrefixSuffixLines() { presentSheet(.prefixSuffixLines) }
    static func presentInsertLoremIpsum() { presentSheet(.insertLoremIpsum) }
    static func presentInsertFileContents() { Self.context.pickers.pending = .insertFile }
    static func presentInsertFolderListing() { Self.context.pickers.pending = .insertFolder }

    // MARK: - Navigation helpers

    /// Scroll the cursor's line into view at vertical center. Reuses
    /// the existing `goToLine` machinery (which centers as part of its
    /// jump) so the implementation stays in the engine adapter.
    static func centerLine() {
        guard let textView = actions, let state = state else { return }
        let (line, _) = TextMetrics.lineColumn(for: textView.selectedRange.location, in: textView.text as NSString)
        state.textView?.goToLine(line)
    }

    /// Applies a one-shot prefix and/or suffix to every line in the
    /// selection (whole text if no selection). Both can be empty
    /// independently — typical use is prefix-only.
    static func applyPrefixSuffix(prefix: String, suffix: String) {
        transformSelection { text in
            var out = text
            if !prefix.isEmpty { out = Transformations.prefixLines(out, with: prefix) }
            if !suffix.isEmpty { out = Transformations.suffixLines(out, with: suffix) }
            return out
        }
    }

    /// Wrap the current selection with `prefix` + `suffix`. Empty
    /// selection collapses to `prefix|suffix` with the cursor between
    /// the two markers so the user can keep typing the wrapped
    /// content. Used by the Text ▸ Surround Selection… sheet.
    static func surroundSelection(prefix: String, suffix: String) {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            textView.replace(range, withText: prefix + suffix)
            let cursor = range.location + (prefix as NSString).length
            textView.setSelection(NSRange(location: cursor, length: 0))
        } else {
            guard let selected = textView.text(in: range) else { return }
            let wrapped = prefix + selected + suffix
            textView.replace(range, withText: wrapped)
            // Restore the selection over the inner content so the
            // user can keep editing it; matches the bold/italic
            // wrap UX in the markdown helpers.
            let newLoc = range.location + (prefix as NSString).length
            textView.setSelection(NSRange(location: newLoc, length: range.length))
        }
        commitTextChange()
    }

    // MARK: - Speak Selection

    /// Speak the current selection (or whole document if none) via the
    /// system speech synthesizer. Calling again while speaking stops
    /// playback — toggles "say it" vs "shut up."
    static func speakSelection() {
        guard let textView = actions else { return }
        if Self.speechSynth.isSpeaking {
            Self.speechSynth.stopSpeaking(at: .immediate)
            return
        }
        let range = textView.selectedRange
        let body = range.length > 0
            ? (textView.text(in: range) ?? "")
            : textView.text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: body)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        Self.speechSynth.speak(utterance)
    }

    static func stopSpeaking() {
        Self.speechSynth.stopSpeaking(at: .immediate)
    }

    private static let speechSynth = AVSpeechSynthesizer()

    // MARK: - Snippets / Clipboard history

    /// Insert a snippet's body at the current cursor (replacing the
    /// selection if any). Snippets get inserted as-is — no placeholder
    /// substitution yet; that's a future hook.
    static func insertSnippet(_ snippet: Snippet) {
        insertAtSelection(snippet.content)
    }

    /// Save the current selection as a new snippet, named with a
    /// timestamp. The user can rename it later in Settings → Snippets.
    static func saveSelectionAsSnippet() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        guard range.length > 0, let body = textView.text(in: range) else { return }
        let name = "Snippet \(Self.snippetDateFormatter.string(from: Date()))"
        SnippetsStore.shared.add(Snippet(name: name, content: body))
    }

    static func presentSnippetPicker()    { presentSheet(.snippetPicker) }
    static func presentSnippetsManager()  { presentSheet(.snippetsManager) }
    static func presentClipboardHistory() { presentSheet(.clipboardHistory) }
    /// Open the drafts-recovery sheet on demand — surfaces the
    /// same list that the launch-time banner shows, so the user can
    /// re-find an unrecovered draft mid-session without having to
    /// relaunch the app. Drafts persist until explicitly discarded
    /// or saved-as.
    static func presentDraftsRecovery()   { presentSheet(.draftsRecovery) }
    static func presentProcessLines()      { presentSheet(.processLines) }
    static func presentCanonize()          { presentSheet(.canonize) }
    static func presentCharacterPanel()    { presentSheet(.characterPanel) }
    // (presentOutline retired — Show Outline opens the sidebar
    // via `showOutline()` instead of a bespoke sheet.)
    // (presentNotebooks removed — feature retired.)

    // (Multi-clipboards ring removed alongside ClipboardHistory.)

    // MARK: - Reflow paragraph (BBEdit hard-wrap)

    /// Hard-wrap the selected text (or current paragraph if no
    /// selection) at `column`. Preserves leading `>` quote prefixes
    /// per line so reflowing email/forum replies stays sane —
    /// strips them, wraps the body, re-applies them on output.
    static func reflowParagraph(column: Int = 80) {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let target: NSRange = {
            let sel = textView.selectedRange
            if sel.length > 0 { return nsText.lineRange(for: sel) }
            // Empty selection: expand to the current "paragraph" —
            // the run of non-blank lines around the cursor.
            return Self.paragraphRange(in: nsText, around: sel.location)
        }()
        guard target.length > 0, let block = textView.text(in: target) else { return }

        let reflowed = Self.reflow(block: block, column: max(20, column))
        textView.replace(target, withText: reflowed)
        commitTextChange()
    }

    /// Wrap `block` to `column` columns, preserving the leading
    /// `> ` quote prefix shared by its lines (or matched per-line
    /// when prefixes differ).
    private static func reflow(block: String, column: Int) -> String {
        let nl = state?.lineEnding.string ?? "\n"
        var lines = block.components(separatedBy: .newlines)
        // Drop trailing empty (from final separator).
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return block }

        // Quote prefix = leading sequence of `>` + space, captured
        // from the first line; if any line has a different prefix,
        // fall through to the no-prefix path.
        let firstPrefix = quotePrefix(of: lines[0])
        let samePrefix = lines.allSatisfy { quotePrefix(of: $0) == firstPrefix }
        let prefix = samePrefix ? firstPrefix : ""
        let bodyText = lines
            .map { samePrefix ? String($0.dropFirst(firstPrefix.count)) : $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let words = bodyText.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return block }

        var output: [String] = []
        var current = prefix
        let bodyBudget = max(1, column - prefix.count)
        for word in words {
            let wordStr = String(word)
            let needed = current == prefix
                ? wordStr.count
                : (current.count - prefix.count) + 1 + wordStr.count
            if needed > bodyBudget && current != prefix {
                output.append(current)
                current = prefix + wordStr
            } else if current == prefix {
                current += wordStr
            } else {
                current += " " + wordStr
            }
        }
        if !current.isEmpty { output.append(current) }
        return output.joined(separator: nl) + nl
    }

    /// `> ` or `>> ` etc. prefix at the start of a quoted line.
    /// Empty for unquoted lines.
    private static func quotePrefix(of line: String) -> String {
        var i = line.startIndex
        while i < line.endIndex, line[i] == ">" {
            i = line.index(after: i)
        }
        // Optional single trailing space after the run of `>`.
        if i < line.endIndex, line[i] == " " {
            i = line.index(after: i)
        }
        return String(line[..<i])
    }

    /// Expand a single-cursor location to the surrounding "paragraph"
    /// (non-blank run of lines). Returns the cursor's line if it
    /// sits on a blank line.
    private static func paragraphRange(in nsText: NSString, around location: Int) -> NSRange {
        let line = nsText.lineRange(for: NSRange(location: location, length: 0))
        var startLine = line
        while startLine.location > 0 {
            let prevLine = nsText.lineRange(for: NSRange(location: startLine.location - 1, length: 0))
            let body = nsText.substring(with: prevLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { break }
            startLine = prevLine
        }
        var endLine = line
        while endLine.location + endLine.length < nsText.length {
            let nextLine = nsText.lineRange(for: NSRange(location: endLine.location + endLine.length, length: 0))
            let body = nsText.substring(with: nextLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { break }
            endLine = nextLine
        }
        return NSRange(location: startLine.location,
                       length: endLine.location + endLine.length - startLine.location)
    }

    // MARK: - Sort by regex capture (Wave 1)

    /// Sort the selected lines (or whole document) using a regex
    /// capture group as the sort key. `pattern` is matched against
    /// each line; `captureIndex` (1-based) names which capture
    /// group's value sorts. Lines that don't match sort to the end
    /// (or start, in descending order).
    static func sortLinesByCapture(_ pattern: String, captureIndex: Int = 1, ascending: Bool = true) {
        guard let textView = actions else { return }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            Self.context.editing.openErrorMessage = "Bad sort pattern: \(pattern)"
            return
        }
        let nsText = textView.text as NSString
        let sel = textView.selectedRange
        let targetRange = sel.length > 0
            ? nsText.lineRange(for: sel)
            : NSRange(location: 0, length: nsText.length)
        guard let body = textView.text(in: targetRange) else { return }
        let nl = state?.lineEnding.string ?? "\n"
        let lines = body.components(separatedBy: .newlines)
        let trailingEmpty = lines.last == ""
        let payload = trailingEmpty ? Array(lines.dropLast()) : lines

        let sorted = payload.sorted { a, b in
            let keyA = Self.captureKey(in: a, regex: regex, captureIndex: captureIndex)
            let keyB = Self.captureKey(in: b, regex: regex, captureIndex: captureIndex)
            switch (keyA, keyB) {
            case (.some(let x), .some(let y)): return ascending ? x < y : x > y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
        var output = sorted.joined(separator: nl)
        if trailingEmpty { output += nl }
        textView.replace(targetRange, withText: output)
        commitTextChange()
    }

    private static func captureKey(in line: String,
                                    regex: NSRegularExpression,
                                    captureIndex: Int) -> String? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              captureIndex < match.numberOfRanges
        else { return nil }
        let r = match.range(at: captureIndex)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    // MARK: - Process Lines Containing (BBEdit)

    enum ProcessLinesAction {
        case keepMatching
        case deleteMatching
        case copyMatchingToClipboard
    }

    /// Filter the document (or selection) line-by-line against
    /// `pattern`. `regex == false` runs a substring contains check.
    /// `invert == true` operates on lines that DON'T match.
    static func processLines(pattern: String,
                              regex: Bool,
                              invert: Bool,
                              action: ProcessLinesAction) {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let sel = textView.selectedRange
        let scopeRange = sel.length > 0
            ? nsText.lineRange(for: sel)
            : NSRange(location: 0, length: nsText.length)
        guard let body = textView.text(in: scopeRange) else { return }
        let nl = state?.lineEnding.string ?? "\n"
        let lines = body.components(separatedBy: .newlines)
        let trailingEmpty = lines.last == ""
        let payload = trailingEmpty ? Array(lines.dropLast()) : lines

        let regexObj: NSRegularExpression? = regex ? (try? NSRegularExpression(pattern: pattern)) : nil
        if regex, regexObj == nil {
            Self.context.editing.openErrorMessage = "Bad pattern: \(pattern)"
            return
        }
        let matches: (String) -> Bool = { line in
            if let regexObj {
                let r = NSRange(location: 0, length: (line as NSString).length)
                return regexObj.firstMatch(in: line, range: r) != nil
            }
            return line.contains(pattern)
        }
        let kept = payload.filter { invert ? !matches($0) : matches($0) }

        switch action {
        case .keepMatching:
            var output = kept.joined(separator: nl)
            if trailingEmpty { output += nl }
            textView.replace(scopeRange, withText: output)
            commitTextChange()
        case .deleteMatching:
            let surviving = payload.filter { invert ? matches($0) : !matches($0) }
            var output = surviving.joined(separator: nl)
            if trailingEmpty { output += nl }
            textView.replace(scopeRange, withText: output)
            commitTextChange()
        case .copyMatchingToClipboard:
            UIPasteboard.general.string = kept.joined(separator: nl)
        }
    }

    // MARK: - Bookmark line ops

    /// Cut the text of every bookmarked line out of the document and
    /// place it (joined with line endings) on the clipboard.
    static func cutBookmarkedLines() {
        let collected = collectBookmarkedLines()
        UIPasteboard.general.string = collected.text
        removeLines(at: collected.ranges)
    }

    /// Copy bookmarked-line text to the clipboard without altering
    /// the document.
    static func copyBookmarkedLines() {
        UIPasteboard.general.string = collectBookmarkedLines().text
    }

    /// Drop every line that is NOT bookmarked. Lines with bookmarks
    /// move into "filter" mode — the result is an extract.
    static func keepBookmarkedLinesOnly() {
        guard let textView = actions, let state else { return }
        let bookmarkedSet = Set(state.bookmarks.values)
        let nsText = textView.text as NSString
        let nl = state.lineEnding.string
        var output: [String] = []
        var scan = 0
        while scan < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: scan, length: 0))
            if bookmarkedSet.contains(line.location) {
                var content = nsText.substring(with: line)
                if content.hasSuffix(nl) { content.removeLast(nl.count) }
                output.append(content)
            }
            scan = line.location + line.length
        }
        textView.text = output.joined(separator: nl)
        state.bookmarks.removeAll()
        commitTextChange()
    }

    /// Delete every bookmarked line.
    static func removeBookmarkedLines() {
        let collected = collectBookmarkedLines()
        removeLines(at: collected.ranges)
        state?.bookmarks.removeAll()
    }

    /// Flip bookmarks: every line currently bookmarked loses its
    /// flag; every other line whose start matches a freshly-assigned
    /// slot becomes bookmarked (limited to 10 slots).
    static func invertBookmarks() {
        guard let textView = actions, let state else { return }
        let oldStarts = Set(state.bookmarks.values)
        let nsText = textView.text as NSString
        var freshStarts: [Int] = []
        var scan = 0
        while scan < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: scan, length: 0))
            if !oldStarts.contains(line.location) {
                freshStarts.append(line.location)
            }
            scan = line.location + line.length
        }
        state.bookmarks.removeAll()
        for (slot, loc) in freshStarts.prefix(10).enumerated() {
            state.bookmarks[slot] = loc
        }
    }

    private struct BookmarkedLines {
        let text: String
        let ranges: [NSRange]
    }

    private static func collectBookmarkedLines() -> BookmarkedLines {
        guard let textView = actions, let state else { return BookmarkedLines(text: "", ranges: []) }
        let nsText = textView.text as NSString
        let nl = state.lineEnding.string
        let starts = state.bookmarks.values.sorted()
        var bodies: [String] = []
        var ranges: [NSRange] = []
        for start in starts where start >= 0 && start < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: start, length: 0))
            var body = nsText.substring(with: line)
            if body.hasSuffix(nl) { body.removeLast(nl.count) }
            bodies.append(body)
            ranges.append(line)
        }
        return BookmarkedLines(text: bodies.joined(separator: nl), ranges: ranges)
    }

    /// Delete a set of line ranges bottom-up so earlier offsets stay
    /// valid.
    private static func removeLines(at ranges: [NSRange]) {
        guard let textView = actions, !ranges.isEmpty else { return }
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            textView.replace(range, withText: "")
        }
        commitTextChange()
    }

    // MARK: - Canonize

    /// Apply a saved list of find/replace pairs (one pair per line,
    /// separated by a tab — left = find, right = replace) in order
    /// against the selection or whole document. `regex == true`
    /// treats the find side as a regular expression.
    static func applyCanonizePairs(_ raw: String, regex: Bool) {
        guard let textView = actions else { return }
        let pairs: [(find: String, replace: String)] = raw
            .components(separatedBy: .newlines)
            .compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { return nil }
                let find = parts[0]
                let replace = parts.dropFirst().joined(separator: "\t")
                guard !find.isEmpty else { return nil }
                return (find, replace)
            }
        guard !pairs.isEmpty else { return }

        let sel = textView.selectedRange
        let scope = sel.length > 0
            ? sel
            : NSRange(location: 0, length: (textView.text as NSString).length)
        guard let original = textView.text(in: scope) else { return }
        var working = original
        for pair in pairs {
            if regex {
                guard let r = try? NSRegularExpression(pattern: pair.find) else { continue }
                let range = NSRange(location: 0, length: (working as NSString).length)
                working = r.stringByReplacingMatches(in: working, range: range, withTemplate: pair.replace)
            } else {
                working = working.replacingOccurrences(of: pair.find, with: pair.replace)
            }
        }
        textView.replace(scope, withText: working)
        commitTextChange()
    }

    /// Used by `ClipboardHistorySheet` to insert any prior copy. Bypasses
    /// `UIPasteboard.string =` (which would mark the history dirty
    /// again) — writes straight into the text view at the cursor.
    static func pasteString(_ s: String) {
        insertAtSelection(s)
    }

    private static let snippetDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - Case / encoding transformations

    static func uppercase()      { transformSelection { $0.uppercased() } }
    static func lowercase()      { transformSelection { $0.lowercased() } }
    static func capitalize()     { transformSelection { $0.capitalized } }
    static func titleCase()      { transformSelection(Transformations.titleCase) }
    static func snakeCase()      { transformSelection(Transformations.snakeCase) }
    static func kebabCase()      { transformSelection(Transformations.kebabCase) }
    static func camelCase()      { transformSelection(Transformations.camelCase) }
    static func pascalCase()     { transformSelection(Transformations.pascalCase) }

    static func normalizeNFC()   { transformSelection { Transformations.normalize($0, form: .nfc) } }
    static func normalizeNFD()   { transformSelection { Transformations.normalize($0, form: .nfd) } }
    static func normalizeNFKC()  { transformSelection { Transformations.normalize($0, form: .nfkc) } }
    static func normalizeNFKD()  { transformSelection { Transformations.normalize($0, form: .nfkd) } }

    static func urlEncode()      { transformSelection(Transformations.urlEncode) }
    static func urlDecode()      { transformSelection(Transformations.urlDecode) }
    static func base64Encode()   { transformSelection(Transformations.base64Encode) }
    static func base64Decode()   { transformSelection(Transformations.base64Decode) }

    static func reverseSelection() { transformSelection(Transformations.reverseCharacters) }

    // MARK: - Inserts

    static func insertDateTime() { insertAtSelection(dateTimeFormatter.string(from: Date())) }
    static func insertDate()     { insertAtSelection(dateFormatter.string(from: Date())) }
    static func insertTime()     { insertAtSelection(timeFormatter.string(from: Date())) }
    static func insertFilePath() { if let url = state?.fileURL { insertAtSelection(url.path) } }
    static func insertFilename() { if let url = state?.fileURL { insertAtSelection(url.lastPathComponent) } }
    static func insertTab()      { insertAtSelection("\t") }
    static func insertNewline()  { insertAtSelection(state?.lineEnding.string ?? "\n") }

    // MARK: - Line ending application

    static func applyLineEnding(_ lineEnding: LineEnding) {
        guard let state = state, let actions = actions else { return }
        state.lineEnding = lineEnding
        // Read from the engine (live buffer), not `state.text` —
        // the latter is a 300 ms debounced snapshot that may lag
        // recent keystrokes.
        let converted = actions.text.replacingLineEndings(with: lineEnding)
        actions.text = converted
        actions.applyLineEndingRawValue(lineEnding.rawValue)
        state.setText?(converted)
    }

    static func setEncoding(_ encoding: FileEncoding) {
        state?.fileEncoding = encoding
    }

    static func reinterpretWithEncoding(_ encoding: FileEncoding) {
        state?.reinterpretWithEncoding?(encoding)
    }

    static func setLanguage(_ identifier: LanguageIdentifier) {
        state?.languageIdentifier = identifier
    }

    static func setIndentUsesTabs(_ value: Bool) {
        state?.usesTabs = value
    }

    static func setIndentWidth(_ width: Int) {
        state?.indentWidth = width
    }

    // MARK: - Select / filter lines

    enum LineMatchError: LocalizedError {
        case invalidRegex(String)
        case noMatches

        var errorDescription: String? {
            switch self {
            case .invalidRegex(let pattern): return "Invalid regular expression: \(pattern)"
            case .noMatches:                 return "No lines matched."
            }
        }
    }

    static func selectLinesContaining(query: String, useRegex: Bool, caseSensitive: Bool) throws {
        guard let textView = actions else { return }
        let matcher = try LineMatcher(query: query, useRegex: useRegex, caseSensitive: caseSensitive)
        let nsText = textView.text as NSString
        var firstStart: Int?
        var lastEnd: Int?
        var location = 0
        while location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let lineString = nsText.substring(with: lineRange)
            let contentOnly = lineString.trimmingCharacters(in: .newlines)
            if matcher.matches(contentOnly) {
                if firstStart == nil { firstStart = lineRange.location }
                let trailingNewlines = (lineString as NSString).length - (contentOnly as NSString).length
                lastEnd = lineRange.location + lineRange.length - trailingNewlines
            }
            if lineRange.length == 0 { break }
            location = lineRange.location + lineRange.length
        }
        guard let start = firstStart, let end = lastEnd else { throw LineMatchError.noMatches }
        textView.setSelection(NSRange(location: start, length: end - start))
        textView.scrollSelectionToVisible()
    }

    static func keepLinesMatching(query: String, useRegex: Bool, caseSensitive: Bool) throws {
        try applyLineFilter(query: query, useRegex: useRegex, caseSensitive: caseSensitive, keepMatching: true)
    }

    static func removeLinesMatching(query: String, useRegex: Bool, caseSensitive: Bool) throws {
        try applyLineFilter(query: query, useRegex: useRegex, caseSensitive: caseSensitive, keepMatching: false)
    }

    private static func applyLineFilter(
        query: String,
        useRegex: Bool,
        caseSensitive: Bool,
        keepMatching: Bool
    ) throws {
        guard let textView = actions else { return }
        let matcher = try LineMatcher(query: query, useRegex: useRegex, caseSensitive: caseSensitive)
        let separator = state?.lineEnding.string ?? "\n"
        let trailing = textView.text.hasSuffix(separator)
        var lines = textView.text.components(separatedBy: separator)
        if trailing && lines.last == "" { lines.removeLast() }
        let filtered = lines.filter { keepMatching ? matcher.matches($0) : !matcher.matches($0) }
        var result = filtered.joined(separator: separator)
        if trailing { result += separator }
        textView.text = result
        state?.setText?(result)
    }

    private struct LineMatcher {
        private let regex: NSRegularExpression?
        private let needle: String
        private let caseSensitive: Bool
        private let useRegex: Bool

        init(query: String, useRegex: Bool, caseSensitive: Bool) throws {
            self.useRegex = useRegex
            self.caseSensitive = caseSensitive
            self.needle = query
            if useRegex {
                let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                do {
                    self.regex = try NSRegularExpression(pattern: query, options: options)
                } catch {
                    throw LineMatchError.invalidRegex(query)
                }
            } else {
                self.regex = nil
            }
        }

        func matches(_ line: String) -> Bool {
            if let regex {
                let range = NSRange(line.startIndex..., in: line)
                return regex.firstMatch(in: line, range: range) != nil
            }
            if caseSensitive { return line.contains(needle) }
            return line.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Font size

    private static let fontSizeStops: [Double] = [
        9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32, 36, 42, 48, 56, 64, 72, 96
    ]

    static func increaseFontSize() {
        guard let state = state else { return }
        let current = state.fontSize
        if let next = fontSizeStops.first(where: { $0 > current }) {
            applyFontSize(next, to: state)
        }
    }

    static func decreaseFontSize() {
        guard let state = state else { return }
        let current = state.fontSize
        if let prev = fontSizeStops.reversed().first(where: { $0 < current }) {
            applyFontSize(prev, to: state)
        }
    }

    static func resetFontSize() {
        guard let state = state else { return }
        let stored = UserDefaults.standard.double(forKey: AppPreferenceKey.fontSize)
        applyFontSize(stored > 0 ? stored : 14, to: state)
    }

    private static func applyFontSize(_ value: Double, to state: EditorState) {
        state.fontSize = value
        UserDefaults.standard.set(value, forKey: AppPreferenceKey.fontSize)
    }

    // MARK: - Cursor / character ops

    static func smartMoveToLineStart() {
        actions?.smartMoveToLineStart()
    }
    static func transposeCharacters() {
        actions?.transposeCharacters()
        commitTextChange()
    }
    static func deleteToEndOfLine() {
        actions?.deleteToEndOfLine()
        commitTextChange()
    }
    static func deleteWordBackward() {
        actions?.deleteWordBackward()
        commitTextChange()
    }
    static func deleteWordForward() {
        actions?.deleteWordForward()
        commitTextChange()
    }
    static func joinLines() {
        actions?.joinLines()
        commitTextChange()
    }

    // MARK: - Spell check

    static func jumpToNextMisspelling() {
        actions?.jumpToNextMisspelling()
    }
    static func learnSelectedWord() {
        actions?.learnSelectedWord()
    }
    static func ignoreSelectedWord() {
        actions?.ignoreSelectedWord()
    }
    static func toggleSpellCheckLive() {
        guard let state = Self.state else { return }
        state.spellCheck.toggle()
        UserDefaults.standard.set(state.spellCheck, forKey: AppPreferenceKey.spellCheck)
    }
    /// One-shot spell-check pass that paints red highlights over
    /// every misspelled word. Works regardless of the per-tab
    /// `spellCheck` preference, so the user can audit a document
    /// even when the live checker is off.
    static func highlightAllMisspellings() {
        actions?.highlightAllMisspellings()
    }
    /// Drop the red marks added by `highlightAllMisspellings`.
    static func clearMisspellingHighlights() {
        actions?.clearMisspellingHighlights()
    }

    // MARK: - Folding

    static func toggleFoldAtCursor() {
        guard let state = state, let textView = actions else { return }
        let nsText = textView.text as NSString
        // 0-based line index for the cursor location.
        let row = currentLineIndex(in: nsText, atUtf16: textView.selectedRange.location)
        guard let body = FoldDiscovery.bodyRange(
            forHeaderRow: row,
            in: nsText,
            language: state.languageIdentifier
        ) else { return }
        let alreadyFolded = body.contains { textView.foldedLineIndices.contains($0) }
        textView.setLinesFolded(!alreadyFolded, range: body)
        persistFolds()
    }

    static func unfoldAll() {
        actions?.unfoldAll()
        persistFolds()
    }

    /// Clear every ad-hoc fold range declared by `Fold Selection`.
    /// Unfolds the lines and drops the gutter indicators — handy
    /// after experimenting with a bunch of manual folds. Language-
    /// derived folds (Markdown headers, code blocks) are
    /// untouched; only the `userFoldedBodyRanges` entries go away.
    static func clearManualFolds() {
        guard let state = Self.state else { return }
        let bodies = state.userFoldedBodyRanges
        guard !bodies.isEmpty else { return }
        for body in bodies {
            actions?.setLinesFolded(false, range: body)
        }
        state.userFoldedBodyRanges.removeAll()
    }

    static func foldAll() {
        guard let state = state, let textView = actions else { return }
        let nsText = textView.text as NSString
        let foldable = FoldDiscovery.allFoldableHeaders(in: nsText, language: state.languageIdentifier)
        for region in foldable {
            textView.setLinesFolded(true, range: region.bodyRange)
        }
        persistFolds()
    }

    private static func persistFolds() {
        guard let state = state, let textView = actions else { return }
        FoldPersistence.save(textView.foldedLineIndices, for: state.fileURL)
    }

    /// 0-based line index for a UTF-16 location into the supplied NSString.
    private static func currentLineIndex(in text: NSString, atUtf16 offset: Int) -> Int {
        let safe = max(0, min(offset, text.length))
        var line = 0
        var i = 0
        while i < safe {
            let c = text.character(at: i)
            if c == 0x0A {
                line += 1
                i += 1
            } else if c == 0x0D {
                line += 1
                i += 1
                if i < safe, text.character(at: i) == 0x0A { i += 1 }
            } else {
                i += 1
            }
        }
        return line
    }

    // MARK: - Brackets

    static func goToMatchingBracket() {
        actions?.goToMatchingBracket()
        recordPositionIfJumped()
    }

    // MARK: - Bookmarks

    static func setBookmark(_ slot: Int) {
        guard let textView = actions, let state = state else { return }
        state.bookmarks[slot] = textView.selectedRange.location
    }

    static func jumpToBookmark(_ slot: Int) {
        guard let textView = actions, let state = state, let location = state.bookmarks[slot] else { return }
        let length = (textView.text as NSString).length
        textView.setSelection(NSRange(location: min(location, length), length: 0))
        textView.scrollSelectionToVisible()
        recordPositionIfJumped()
    }

    static func clearBookmark(_ slot: Int) {
        state?.bookmarks[slot] = nil
    }

    // MARK: - Position history

    /// Records the current cursor location if it represents a jump (see
    /// PositionHistory.jumpThreshold). Trims forward history on insert.
    static func recordPositionIfJumped() {
        guard let textView = actions, let state = state else { return }
        state.positionHistory.record(textView.selectedRange.location)
    }

    static func positionBack() {
        guard let textView = actions, let state = state,
              let target = state.positionHistory.back() else { return }
        textView.setSelection(NSRange(location: target, length: 0))
        textView.scrollSelectionToVisible()
    }

    static func positionForward() {
        guard let textView = actions, let state = state,
              let target = state.positionHistory.forward() else { return }
        textView.setSelection(NSRange(location: target, length: 0))
        textView.scrollSelectionToVisible()
    }

    // MARK: - Query Replace

    /// Performs one step of a query-replace iteration. Sheet logic owns the
    /// match cursor; this just operates on the next/current match.
    struct QueryReplaceMatch {
        let range: NSRange
        let replacement: String
    }

    /// Find the next match. `preferLast` means "if scanning the entire
    /// search range, take the *last* match rather than the first" — that's
    /// how we get reverse-direction matching from the same forward primitives.
    static func nextQueryReplaceMatch(
        query: String,
        replacement: String,
        useRegex: Bool,
        caseSensitive: Bool,
        startingAt cursor: Int,
        searchUpTo upperBound: Int? = nil,
        preferLast: Bool = false
    ) throws -> QueryReplaceMatch? {
        guard let textView = actions, !query.isEmpty else { return nil }
        let nsText = textView.text as NSString
        let totalLength = nsText.length
        let cap = upperBound ?? totalLength
        guard cursor < cap else { return nil }
        let searchRange = NSRange(location: cursor, length: cap - cursor)

        if useRegex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: query, options: options)
            } catch {
                throw LineMatchError.invalidRegex(query)
            }
            if preferLast {
                let matches = regex.matches(in: textView.text, range: searchRange)
                guard let last = matches.last else { return nil }
                let replaced = regex.replacementString(for: last, in: textView.text, offset: 0, template: replacement)
                return QueryReplaceMatch(range: last.range, replacement: replaced)
            }
            guard let match = regex.firstMatch(in: textView.text, range: searchRange) else { return nil }
            let replaced = regex.replacementString(for: match, in: textView.text, offset: 0, template: replacement)
            return QueryReplaceMatch(range: match.range, replacement: replaced)
        } else {
            var opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            if preferLast { opts.insert(.backwards) }
            let range = nsText.range(of: query, options: opts, range: searchRange)
            guard range.location != NSNotFound else { return nil }
            return QueryReplaceMatch(range: range, replacement: replacement)
        }
    }

    static func applyQueryReplaceMatch(_ match: QueryReplaceMatch) {
        guard let textView = actions else { return }
        textView.replace(match.range, withText: match.replacement)
        commitTextChange()
    }

    static func revealMatch(_ match: QueryReplaceMatch) {
        guard let textView = actions else { return }
        textView.setSelection(match.range)
        textView.scrollSelectionToVisible()
    }

    // MARK: - Helpers

    /// Test seam: swap this for a stub `CommandContext` (via
    /// `CommandActions.context = stub`) to drive commands in
    /// isolation. Production code path is untouched — the default
    /// is the real bus singleton. Every helper below routes through
    /// `Self.context`, so a stubbed context flows through all
    /// reads / writes the command issues.
    static var context: any CommandContext = AppStateBus.shared

    private static var state: EditorState? {
        context.scenes.currentEditor
    }

    private static var session: EditorSession? {
        context.scenes.currentSession
    }

    private static var actions: (any EditorActions)? {
        state?.textView
    }

    private static func commitTextChange() {
        if let textView = actions { state?.setText?(textView.text) }
    }

    private static func transformSelection(_ transform: (String) -> String) {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            let newText = transform(textView.text)
            textView.text = newText
            state?.setText?(newText)
            return
        }
        guard let selected = textView.text(in: range) else { return }
        let replacement = transform(selected)
        textView.replace(range, withText: replacement)
        commitTextChange()
    }

    private static func applyToWholeText(_ transform: (String) -> String) {
        guard let textView = actions else { return }
        let newText = transform(textView.text)
        textView.text = newText
        state?.setText?(newText)
    }

    private static func insertAtSelection(_ string: String) {
        guard let textView = actions else { return }
        textView.replace(textView.selectedRange, withText: string)
        commitTextChange()
    }

    // DateFormatter construction is multi-millisecond on cold cache, so cache.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
