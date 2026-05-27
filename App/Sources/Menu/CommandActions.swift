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

    /// New tabs land on the launcher (templates + drafts), so the
    /// old "offer drafts banner" plumbing is gone — the launcher
    /// itself surfaces the same list inline.
    static func newTab() {
        Self.context.scenes.currentSession?.newTab()
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
    // (Tab move / close / duplicate / rename / navigate moved to
    //  CommandActions+Tabs.swift)

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

    // (Line operations moved to CommandActions+LineOps.swift)

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

    /// Insert the named slot's body at the current cursor (replacing
    /// the selection if any). Empty/unconfigured slots no-op so menu
    /// shortcuts can't insert blank strings.
    static func insertSnippet(slotID: Int) {
        guard let slot = SnippetsStore.shared.slot(id: slotID),
              slot.isConfigured else { return }
        insertAtSelection(slot.content)
    }

    /// Save the current selection into the first unconfigured slot,
    /// named with a timestamp. Silently no-ops if every slot is in
    /// use — the user manages the ten-slot pool from Manage Snippets.
    static func saveSelectionAsSnippet() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        guard range.length > 0, let body = textView.text(in: range) else { return }
        let name = "Snippet \(Self.snippetDateFormatter.string(from: Date()))"
        SnippetsStore.shared.saveToFirstEmpty(name: name, content: body)
    }

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

    /// Used by `ClipboardHistorySheet` to insert any prior copy. Bypasses
    /// `UIPasteboard.string =` (which would mark the history dirty
    /// again) — writes straight into the text view at the cursor.
    static func pasteString(_ s: String) {
        insertAtSelection(s)
    }

    static let snippetDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // (Reflow, Sort by capture, Process Lines, Canonize, and Case /
    //  encoding transforms moved to CommandActions+TextTransforms.swift)
    // (Bookmark line ops moved to CommandActions+Bookmarks.swift)

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

    /// Lightweight "set the document's line-ending preference"
    /// — only affects how subsequent newline insertions render.
    /// Use `applyLineEnding(_:)` to also rewrite every existing
    /// break in the buffer.
    static func setLineEnding(_ lineEnding: LineEnding) {
        state?.lineEnding = lineEnding
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

    // (Select / filter lines moved to CommandActions+SelectLines.swift)

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

    // (Spell check moved to CommandActions+Spelling.swift)
    // (Folding moved to CommandActions+Folding.swift)

    // MARK: - Brackets

    static func goToMatchingBracket() {
        actions?.goToMatchingBracket()
        recordPositionIfJumped()
    }

    // (Bookmark slot ops moved to CommandActions+Bookmarks.swift)

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
