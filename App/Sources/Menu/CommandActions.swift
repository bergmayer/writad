import SwiftUI
import AVFoundation
import FileEncoding
import LineEnding
import LineSort

/// Menu and palette actions. Both surfaces resolve the current editor
/// through `Self.context.scenes.currentEditor`.
@MainActor
enum CommandActions {

    // MARK: - Sheets

    static func presentSheet(_ sheet: EditorSheet) {
        Self.context.editing.presentedSheet = sheet
    }

    // MARK: - Window / file commands

    /// Spawn a new editor scene. The fresh window picks the user's
    /// default launch behaviour.
    static func newWindow() {
        Self.context.scenes.openWindowAction?(.editor)
    }

    /// Every user-initiated new tab/window offers drafts recovery so
    /// an unsaved buffer isn't buried behind a fresh blank surface.
    static func newTab() {
        Self.context.scenes.currentSession?.newTab()
        offerDraftsIfAvailable()
    }

    /// Shared by every "user opened a new surface" entry point.
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

    static func presentCommandPalette() {
        Self.context.editing.presentedSheet = .commandPalette
    }

    /// Window destination: one fresh browser scene per pick. Tab
    /// destination: sheet on the active editor — picks add tabs to
    /// the same session ("everything in this window").
    static func presentFileBrowser() {
        switch DocumentDestination.current() {
        case .window:
            Self.context.scenes.requestOpenWindow(.fileBrowser)
            Self.context.scenes.openWindowAction?(.fileBrowser)
        case .tab:
            Self.context.editing.presentedSheet = .fileBrowser
        }
    }

    /// One-shot destination override for "Open in New Tab…" /
    /// "Open in New Window…". Cleared by `EditorScene.route(open:)`
    /// once the picked URL lands.
    static func presentFileBrowser(forceDestination destination: DocumentDestination) {
        Self.context.pending.nextOpenDestinationOverride = destination
        presentFileBrowser()
    }

    /// Inline browser tab — UIDocumentBrowserViewController hosted
    /// inside the tab. The pick handler flips kind back to `.editor`
    /// and loads the URL into the same tab.
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

    /// `EditorActions` doesn't surface `undoManager`, but the sole
    /// conformer is a UITextView subclass, so a UIResponder cast is
    /// safe.
    static func undo() {
        (actions as? UIResponder)?.undoManager?.undo()
    }

    static func redo() {
        (actions as? UIResponder)?.undoManager?.redo()
    }

    // MARK: - Tabs

    /// EditorScene observes `tabSwitcherActive` and runs the
    /// matchedGeometry morph. Second press dismisses (Safari parity).
    static func showTabSwitcher() {
        withAnimation(.appSwitcherMorph) {
            Self.context.editing.tabSwitcherActive.toggle()
        }
    }

    // MARK: - Same-file new window (split-view surrogate)

    /// iPad-native side-by-side: same URL, two scenes. A true split
    /// would need engine-side shared text storage. Untitled buffers
    /// are no-ops — no URL to reload from.
    static func openCurrentDocumentInNewWindow() {
        guard let url = Self.context.scenes.currentEditor?.fileURL else { return }
        Self.context.pending.newWindow = url
        Self.context.scenes.openWindowAction?(.editor)
    }

    // MARK: - Sidebar

    /// Compat shim — older callers used `toggleSidebar`; the sidebar
    /// IS the outline panel, so the user-facing name is Show Outline.
    static func toggleSidebar() { showOutline() }

    static func showOutline() {
        guard let state = Self.state else { return }
        withAnimation(.appSnappyPanel) {
            state.sidebarOpen.toggle()
        }
    }

    /// `state.inspectorOpen` is the shared per-tab flag — menu and
    /// the status-bar ⓘ both write it.
    static func toggleInspector() {
        guard let state = Self.state else { return }
        state.inspectorOpen.toggle()
    }

    // MARK: - Split editor view

    /// One button for the three states (off → horizontal → vertical
    /// → off) so the user doesn't juggle "toggle on" + "toggle
    /// orientation" separately. Resets to 50/50 on each change so a
    /// width↔height flip can't leave a sliver pane.
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

    /// Used for the cycle button's icon / accessibility label.
    static func currentSplitState() -> (open: Bool, orientation: SplitOrientation)? {
        guard let state = Self.state else { return nil }
        return (state.splitOpen, state.splitOrientation)
    }

    // (Fold Selection moved to CommandActions+Folding.swift)

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
                displayName: tab.document.fileURL?.lastPathComponent ?? "Untitled",
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
        let tab = session.newTab()
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

    // (Find sections moved to CommandActions+Find.swift)

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

    // (Markdown formatting + list conversion moved to CommandActions+Markdown.swift)

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

    /// Collapses intra-paragraph breaks into spaces. Blank-line
    /// paragraph delimiters survive — unwraps hard-wrapped prose.
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

    /// Greedy 72-column word wrap; whitespace is normalised to single
    /// spaces first.
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
    /// No UI — strips ASCII control + invisible Unicode outright.
    /// Backs the toolbar quick action and the bare menu item; use
    /// `presentZapGremlins` for the configurable sheet.
    static func zapGremlins() { transformSelection(Transformations.zapGremlins) }

    /// Called by the sheet after the user picks categories and a
    /// replacement.
    static func zapGremlinsConfigured(options: ZapGremlinsOptions) {
        transformSelection { Transformations.zapGremlins($0, options: options) }
    }

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

    // MARK: - Sort by regex capture

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

    // (Folding moved to CommandActions+Folding.swift)

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

    // `internal` (no `private`) so the +Find / +Folding / +Markdown
    // extensions in their own files can reach the same shared helpers.
    static var state: EditorState? {
        context.scenes.currentEditor
    }

    static var session: EditorSession? {
        context.scenes.currentSession
    }

    static var actions: (any EditorActions)? {
        state?.textView
    }

    static func commitTextChange() {
        if let textView = actions { state?.setText?(textView.text) }
    }

    static func transformSelection(_ transform: (String) -> String) {
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

    static func applyToWholeText(_ transform: (String) -> String) {
        guard let textView = actions else { return }
        let newText = transform(textView.text)
        textView.text = newText
        state?.setText?(newText)
    }

    static func insertAtSelection(_ string: String) {
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
