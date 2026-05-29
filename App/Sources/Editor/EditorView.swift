import SwiftUI
import UniformTypeIdentifiers
import FileEncoding

struct EditorView: View {

    let document: PlainTextDocument
    let state: EditorState
    /// Replaces `splitOrSingleEditor` while keeping the surrounding
    /// chrome (toolbar / status bar / accessory). Launcher + inline
    /// file browser use this so they show *inside* the tab.
    let tabContentOverride: AnyView?

    init(document: PlainTextDocument, state: EditorState, tabContentOverride: AnyView? = nil) {
        self.document = document
        self.state = state
        self.tabContentOverride = tabContentOverride
    }

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.openWindow) private var openWindow
    /// Read direct from `@AppStorage` so View ▸ Show Toolbar reaches every
    /// window, not just the one that was active when the flag flipped.
    @AppStorage(AppPreferenceKey.showToolbar) private var showToolbarPref: Bool = true
    /// `.onChange` syncs into `state.themeName` so Settings reaches every
    /// open scene, not only newly-spawned ones.
    @AppStorage(AppPreferenceKey.themeName) private var themeNamePref: String = AppThemeName.automatic.rawValue
    @AppStorage(AppPreferenceKey.fontSize) private var fontSizePref: Double = 14
    @AppStorage(AppPreferenceKey.fontName) private var fontNamePref: String = EditorFont.systemMono.rawValue
    var body: some View {
        observeStateForEngineUpdates()
        // Editor ignores keyboard safe area; UITextView's own contentInset
        // scrolls the cursor in. Status bar is a separate ZStack layer
        // that DOES respect keyboard safe area, so SwiftUI lifts only it.
        // VStack + bottom-padding had visibly squashed the editor on iPad
        // portrait.
        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // No transition between launcher and editor: nav title +
                // accessory bar + keyboard animations made the kind-flip
                // visibly janky on iPhone when a new tab was created.
                Group {
                    if let override = tabContentOverride {
                        override
                    } else {
                        splitOrSingleEditor
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if state.showStatusBar {
                EditorStatusBar(document: document, state: state)
            }
        }
        // Non-modal so the editor stays editable while the user browses
        // metadata or the outline.
        .inspector(isPresented: Binding(
            get: { state.inspectorOpen },
            set: { state.inspectorOpen = $0 }
        )) {
            InfoInspectorSheet(document: document, state: state, onJump: { goToLine($0) })
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        // Blocks typing into a buffer that's about to be replaced.
        .overlay {
            if document.isLoading { loadingOverlay }
        }
        // isActive gate: shared bus flag surfaces only on the focused window.
        .sheet(item: isActive ? $bus.editing.presentedSheet : .constant(nil)) { sheet in
            sheetContent(for: sheet)
        }
        .alert(
            "Couldn't open file",
            isPresented: openErrorAlertBinding,
            presenting: bus.editing.openErrorMessage
        ) { _ in
            Button("OK") { bus.editing.openErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        // `.alert` not `.confirmationDialog`: iPad popover-with-tail needs
        // an anchor, and close paths come from disparate places (tab
        // strip, switcher, ⌘W, palette) with no single sensible anchor.
        .alert(
            "Close \(bus.editing.pendingClose?.displayName ?? "tab")?",
            isPresented: pendingCloseBinding,
            presenting: bus.editing.pendingClose
        ) { pending in
            // Saved files write back to the existing URL; untitled
            // buffers open Save As, then the tab closes.
            Button(pending.isUntitled ? "Save…" : "Save and Close") {
                CommandActions.confirmSaveAndClose(pending)
            }
            // Save as Draft keeps the edits in the unsaved-drafts
            // list (reachable from the launcher) without writing
            // them to a file — fastest way out of the dialog when
            // the user isn't ready to pick a filename.
            Button("Save as Draft") {
                CommandActions.saveAsDraftAndClose(pending)
            }
            Button("Discard Changes", role: .destructive) {
                CommandActions.confirmDiscardAndClose(pending)
            }
            Button("Cancel", role: .cancel) { CommandActions.cancelPendingClose() }
        } message: { pending in
            Text(pending.isUntitled
                 ? "This document is untitled. Save it to a file, keep it as an unsaved draft, or discard the contents."
                 : "This document has unsaved changes since its last save.")
        }
        // Three stale-source flavors, one alert. ViewModifier extraction
        // keeps the body's modifier chain under the type-checker budget.
        .modifier(StaleSourceAlertModifier(
            title: staleAlertTitle,
            presented: staleCheckBinding,
            check: bus.editing.sourceStaleCheck,
            cancel: { bus.editing.sourceStaleCheck = nil }
        ))
        // Fires for Close Other / Close to Right / Close All when at least
        // one tab in the set is dirty. Extracted for same type-checker
        // reason as the stale alert.
        .modifier(BatchCloseAlertModifier(
            presented: pendingBatchCloseBinding,
            pending: bus.editing.pendingBatchClose,
            message: batchCloseMessage
        ))
        .onAppear {
            primeStateFromDocument()
            AppStateBus.shared.scenes.currentEditor = state
            if let session = AppStateBus.shared.scenes.currentSession {
                AppStateBus.shared.scenes.registerSession(session)
            }
        }
        // No matching .onDisappear: SwiftUI fires it on any focus loss
        // (palette / preferences / multitasking swipe), which dimmed the
        // menu bar despite a live editor behind another window.
        // `currentEditor` is weak — nils on EditorState dealloc.
        .onChange(of: state.fileEncoding) { _, newValue in document.fileEncoding = newValue }
        .onChange(of: state.lineEnding)   { _, newValue in document.lineEnding = newValue }
        .onChange(of: themeNamePref) { _, raw in
            // Per-window override (info inspector) outranks Settings.
            guard state.themeOverride == nil else { return }
            state.themeName = AppThemeName(stored: raw)
        }
        .onChange(of: fontSizePref) { _, newValue in
            // Ignore 0 in case UserDefaults returns 0 mid-write.
            guard state.fontSizeOverride == nil else { return }
            if newValue > 0 { state.fontSize = newValue }
        }
        .onChange(of: fontNamePref) { _, newRaw in
            guard state.fontOverride == nil else { return }
            state.font = EditorFont(stored: newRaw)
        }
        // Settings → live state. Without this, prefs only land on freshly
        // opened tabs. Extracted to a modifier to keep this body's
        // .onChange chain inside the type-checker budget.
        .modifier(EditorPrefSync(state: state))
        // `bufferRevision` is a UInt64 bumped per edit — O(1) to observe.
        // Watching `document.text` would cascade the whole String through
        // the observation graph per keystroke (the McCartney-file freeze).
        .onChange(of: document.bufferRevision) { _, _ in
            scheduleAutoSave()
            scheduleLiveSpellCheckIfEnabled()
        }
        // Repaint/clear immediately so the user sees the toggle take.
        .onChange(of: state.spellCheck) { _, isOn in
            if isOn {
                state.textView?.highlightAllMisspellings()
            } else {
                state.liveSpellTask?.cancel()
                state.liveSpellTask = nil
                state.textView?.clearMisspellingHighlights()
            }
        }
        // Tap-to-suggest on a highlighted misspelling: only fire when the
        // caret crosses INTO a new misspelling range, never on arrow-key
        // movement within the same word, never while another sheet is up.
        .onChange(of: state.selectedRange) { oldValue, newValue in
            guard newValue.length == 0,
                  AppStateBus.shared.editing.presentedSheet == nil,
                  let actions = state.textView,
                  let entered = actions.misspellingRange(at: newValue.location),
                  actions.misspellingRange(at: oldValue.location) != entered
            else { return }
            CommandActions.presentSpellCheckSheet()
        }
        // Load / revert / restore flow through document.text; the engine's
        // updateUIView picks them up via lastPushedDocumentText.
        .navigationTitle(documentTitle)
        .navigationSubtitle(documentSubtitle)
        .navigationBarTitleDisplayMode(.inline)
        // iPad swaps the system nav bar for the WindowToolbar pill;
        // iPhone keeps the system bar (where the filename lives).
        .toolbar(
            (DeviceIdiom.supportsMultipleWindows && showToolbarPref) ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            // iPhone nav bar: gear, file (leading); undo, palette
            // (trailing). Same-placement items render in declaration order.
            if DeviceIdiom.isPhone {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        claimFocus()
                        CommandActions.presentPreferences()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        claimFocus()
                        CommandActions.presentFileBrowser()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Open File")
                }
                ToolbarItem(placement: .principal) {
                    // Replaces the system navigationTitle with the
                    // tappable / renameable button.
                    EditableTitleView(
                        title: documentTitle,
                        titleFont: .headline,
                        maxRenameWidth: 200
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        claimFocus()
                        CommandActions.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Undo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    phonePaletteEntry
                }
            }
        }
    }

    private var isActive: Bool { bus.scenes.isActive(state) }

    /// Match by session id so the dialog fires on the originating window
    /// even when focus has shifted by the time the user answers.
    private var pendingCloseBinding: Binding<Bool> {
        Binding(
            get: {
                guard let pending = bus.editing.pendingClose else { return false }
                let mySession = bus.scenes.allOpenSessions.first { session in
                    session.tabs.contains { $0.state === state }
                }
                // Registry-stale fallback: show on active rather than
                // silently drop (the don't-lose-user-data path).
                guard let mySession else { return isActive }
                return ObjectIdentifier(mySession) == pending.sessionID
            },
            set: { newValue in
                if !newValue { bus.editing.pendingClose = nil }
            }
        )
    }

    /// Renders the alert only in the window that owns the closing tabs.
    private var pendingBatchCloseBinding: Binding<Bool> {
        Binding(
            get: {
                guard let pending = bus.editing.pendingBatchClose,
                      let mySession = session
                else { return false }
                return ObjectIdentifier(mySession) == pending.sessionID
            },
            set: { newValue in
                if !newValue { bus.editing.pendingBatchClose = nil }
            }
        )
    }

    private func batchCloseMessage(_ pending: PendingBatchClose) -> String {
        let scope = pending.description
        let suffix = pending.dirtyCount == 1
            ? "1 of them has unsaved changes."
            : "\(pending.dirtyCount) of them have unsaved changes."
        return "\(scope). \(suffix) Save to Drafts keeps the edits in the unsaved-drafts list so you can pick them up later; Discard throws them away."
    }

    /// Only the owning scene presents — otherwise every window stacks it.
    private var staleCheckBinding: Binding<Bool> {
        Binding(
            get: {
                guard let check = bus.editing.sourceStaleCheck else { return false }
                let tabID: UUID
                switch check {
                case .missing(let t, _), .changedOnAdopt(let t, _), .changedOnSave(let t, _):
                    tabID = t
                }
                return session?.tabs.contains(where: { $0.id == tabID }) ?? false
            },
            set: { newValue in
                if !newValue { bus.editing.sourceStaleCheck = nil }
            }
        )
    }

    private var staleAlertTitle: String {
        switch bus.editing.sourceStaleCheck {
        case .missing:        return "Source file missing"
        case .changedOnAdopt: return "Source file changed"
        case .changedOnSave:  return "Source file changed"
        case .none:           return ""
        }
    }

    private var session: EditorSession? {
        bus.scenes.allOpenSessions.first { $0.tabs.contains(where: { $0.state === state }) }
    }

    private var openErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { isActive && bus.editing.openErrorMessage != nil },
            set: { newValue in
                if !newValue { bus.editing.openErrorMessage = nil }
            }
        )
    }

    private var documentTitle: String {
        document.displayName
    }

    /// "edited" hint + location, middle-dot joined. Brand-new Untitled
    /// with no edits is NOT "edited"; only flips once `isDirty` does.
    private var documentSubtitle: String {
        let unsaved = document.isDirty
        let location: String = document.fileURL.map { DocumentLocation.describe(parentOf: $0) } ?? ""
        switch (unsaved, location.isEmpty) {
        case (true, true):   return "edited"
        case (true, false):  return "edited · \(location)"
        case (false, true):  return ""
        case (false, false): return location
        }
    }

    /// updateUIView only fires when SwiftUI re-evaluates THIS body, which
    /// only happens when an @Observable is read here. Touch every engine-
    /// relevant property to force propagation.
    ///
    /// Do NOT add `document.bufferRevision` — per-keystroke body re-eval
    /// is exactly the cost we're avoiding. `document.text` is safe: only
    /// changes on load / revert / restore + 300 ms debounced snapshot.
    private func observeStateForEngineUpdates() {
        _ = document.text  // load / revert / restore pushes
        _ = state.languageIdentifier
        _ = state.themeName
        _ = state.font
        _ = state.fontSize
        _ = state.lineHeight
        _ = state.showLineNumbers
        _ = state.wrapLines
        _ = state.highlightCurrentLine
        _ = state.highlightMatchingBrackets
        _ = state.showPageGuide
        _ = state.pageGuideColumn
        _ = state.showInvisibles
        _ = state.showInvisibleSpace
        _ = state.showInvisibleTab
        _ = state.showInvisibleNewline
        _ = state.showInvisibleNonBreakingSpace
        _ = state.usesTabs
        _ = state.indentWidth
        _ = state.insertCharacterPairs
        _ = state.autoCorrect
        _ = state.autoCapitalize
        _ = state.smartQuotes
        _ = state.spellCheck
        _ = state.autoLinkDetection
        _ = state.savedBaselineText
        _ = state.showChangeHistoryGutter
        _ = state.overscroll
        _ = state.sidebarOpen
        _ = state.splitOpen
        _ = state.splitFraction
        _ = state.splitOrientation
    }

    private func primeStateFromDocument() {
        state.text = document.text
        // Diff-gutter baseline. Save flows rewrite this so the gutter
        // resets after a successful write.
        state.savedBaselineText = document.text
        state.fileEncoding = document.fileEncoding
        state.lineEnding = document.lineEnding
        state.fileURL = document.fileURL
        if let url = document.fileURL {
            state.languageIdentifier = LanguageRegistry.identifier(for: url)
        }
        // Background tabs miss `.onChange(of:)` while unmounted —
        // re-seed from defaults on appear unless user set a per-window
        // override.
        let d = UserDefaults.standard
        if state.themeOverride == nil {
            state.themeName = AppThemeName(stored: d.string(forKey: AppPreferenceKey.themeName))
        }
        if state.fontOverride == nil {
            state.font = EditorFont(stored: d.string(forKey: AppPreferenceKey.fontName))
        }
        if state.fontSizeOverride == nil {
            let stored = d.double(forKey: AppPreferenceKey.fontSize)
            state.fontSize = stored > 0 ? stored : 14
        }
        // Weak captures: closures stored on `state` would ARC-cycle.
        state.setText = { [weak state, weak document] newText in
            guard state != nil, let document else { return }
            if document.text != newText {
                document.text = newText
                document.isDirty = true
            }
        }
        state.reinterpretWithEncoding = { [weak state, weak document] newEncoding in
            guard let state, let document else { return }
            guard let data = document.originalData else {
                document.fileEncoding = newEncoding
                state.fileEncoding = newEncoding
                return
            }
            do {
                let (decoded, encoding) = try String.string(
                    data: data,
                    decodingStrategy: .specific(newEncoding.encoding)
                )
                document.text = decoded
                document.fileEncoding = FileEncoding(
                    encoding: encoding.encoding,
                    withUTF8BOM: newEncoding.withUTF8BOM
                )
                state.text = decoded
                state.fileEncoding = document.fileEncoding
            } catch {
                document.fileEncoding = newEncoding
                state.fileEncoding = newEncoding
            }
        }
    }

    // MARK: - Loading overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.06).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(loadingMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel") {
                    state.loadTask?.cancel()
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var loadingMessage: String {
        // Open-in-new-window: document.fileURL is nil until applyPayload.
        let url = document.fileURL ?? state.fileURL
        guard let url else { return "Loading…" }
        let provider = DocumentLocation.describe(parentOf: url)
            .split(separator: "›").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let name = url.lastPathComponent
        if provider.isEmpty {
            return "Loading \(name)…"
        }
        return "Loading \(name)\nfrom \(provider)…"
    }

    @ViewBuilder
    private var phonePaletteEntry: some View {
        if showToolbarPref {
            phoneCombinedMenu
        } else {
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Image(systemName: "command.square")
            }
            .accessibilityLabel("Command Palette")
        }
    }

    /// Two editors over the same document; pane size tracks splitFraction.
    @ViewBuilder
    private var splitOrSingleEditor: some View {
        if state.splitOpen, let session = bus.scenes.currentSession,
           let tab = session.tabs.first(where: { $0.state === state }) {
            GeometryReader { proxy in
                switch state.splitOrientation {
                case .horizontal:
                    let total = max(proxy.size.width, 1)
                    let leftWidth = max(120, min(total - 120, total * state.splitFraction))
                    HStack(spacing: 0) {
                        EditorTextView(document: document, state: state)
                            .frame(width: leftWidth)
                        splitDivider(in: total, axis: .horizontal)
                        EditorTextView(document: document, state: tab.ensureSecondaryState())
                    }
                case .vertical:
                    let total = max(proxy.size.height, 1)
                    let topHeight = max(120, min(total - 120, total * state.splitFraction))
                    VStack(spacing: 0) {
                        EditorTextView(document: document, state: state)
                            .frame(height: topHeight)
                        splitDivider(in: total, axis: .vertical)
                        EditorTextView(document: document, state: tab.ensureSecondaryState())
                    }
                }
            }
        } else {
            EditorTextView(document: document, state: state)
        }
    }

    @ViewBuilder
    private func splitDivider(in totalSize: CGFloat, axis: SplitOrientation) -> some View {
        Color(.separator)
            .frame(width:  axis == .horizontal ? 6 : nil,
                   height: axis == .vertical   ? 6 : nil)
            .overlay {
                switch axis {
                case .horizontal: Rectangle().fill(Color.secondary).frame(width: 1)
                case .vertical:   Rectangle().fill(Color.secondary).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let delta: CGFloat
                        switch axis {
                        case .horizontal: delta = value.translation.width
                        case .vertical:   delta = value.translation.height
                        }
                        let newFraction = (totalSize * state.splitFraction + delta) / totalSize
                        state.splitFraction = max(0.1, min(0.9, newFraction))
                    }
            )
    }

    /// Beats the iPad Stage Manager / Split View race where scenePhase
    /// fires late and the sheet would land on the wrong window.
    private func claimFocus() {
        bus.scenes.claimFocus(state: state)
    }

    @ViewBuilder
    private var phoneCombinedMenu: some View {
        let slots = ToolbarConfig.shared.slots
        Menu {
            // Palette pinned at top — same affordance with toolbar off.
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Label("Command Palette…", systemImage: "command.square")
            }
            if !slots.isEmpty {
                Divider()
                ForEach(slots) { slot in
                    if let cmd = CommandRegistry.lookup(id: slot.commandId) {
                        Button {
                            claimFocus()
                            if cmd.isEnabled() { cmd.action() }
                        } label: {
                            Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                        }
                        .disabled(!cmd.isEnabled())
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.rectangle")
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel("Toolbar Actions")
    }

    /// ~800 ms after last edit. URL-backed → autoSave (write+revision);
    /// untitled → autoSnapshot (revision only, since sandbox demands a
    /// user-granted location). loadAsync opts out to avoid echoing.
    private func scheduleAutoSave() {
        guard !document.isLoading, document.isDirty else { return }
        state.autoSaveTask?.cancel()
        state.autoSaveTask = Task { @MainActor [weak document, weak state] in
            defer { state?.autoSaveTask = nil }
            try? await Task.sleep(for: Timing.autoSaveDebounce)
            if Task.isCancelled { return }
            guard let document, document.isDirty else { return }
            // Engine live buffer; document.text is a 300 ms snapshot and
            // one dropped tick would autosave stale bytes.
            if let live = state?.textView?.text {
                document.text = live
            }
            if document.fileURL != nil {
                document.autoSave()
            } else {
                document.autoSnapshot()
            }
        }
    }

    /// 400 ms debounce matches autocorrect's "stopped typing" feel
    /// without thrashing the highlight list per keystroke.
    private func scheduleLiveSpellCheckIfEnabled() {
        guard state.spellCheck, !document.isLoading else { return }
        state.liveSpellTask?.cancel()
        state.liveSpellTask = Task { @MainActor [weak state] in
            defer { state?.liveSpellTask = nil }
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            state?.textView?.highlightAllMisspellings()
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for sheet: EditorSheet) -> some View {
        switch sheet {
        case .encodingPicker:
            EncodingPickerSheet(
                current: document.fileEncoding,
                onSelect: { encoding, action in
                    switch action {
                    case .convert:
                        state.fileEncoding = encoding
                    case .reinterpret:
                        state.reinterpretWithEncoding?(encoding)
                    }
                }
            )
        case .lineEndingPicker:
            LineEndingPickerSheet(
                current: document.lineEnding,
                onSelect: { lineEnding in
                    state.lineEnding = lineEnding
                    document.text = document.text.replacingLineEndings(with: lineEnding)
                }
            )
        case .languagePicker:
            LanguagePickerSheet(
                current: state.languageIdentifier,
                onSelect: { identifier in
                    state.languageIdentifier = identifier
                }
            )
        case .characterInspector:
            CharacterInspectorSheet(text: document.text, range: state.selectedRange)
        case .sortLines:
            SortLinesSheet(
                text: document.text,
                lineEnding: document.lineEnding,
                onApply: { sorted in document.text = sorted }
            )
        case .goToLine:
            GoToLineSheet(
                lineCount: lineCount(in: document.text),
                onApply: { line in goToLine(line) }
            )
        case .selectLinesContaining:
            SelectLinesContainingSheet()
        case .prefixSuffixLines:
            PrefixSuffixLinesSheet()
        case .insertLoremIpsum:
            InsertLoremIpsumSheet()
        case .snippetsManager:
            SnippetsManagerSheet()
        case .draftsRecovery:
            DraftsRecoverySheet()
        case .clipboardHistory:
            ClipboardHistorySheet()
        case .findReplace:
            FindReplaceSheet()
        case .zapGremlins:
            ZapGremlinsSheet()
        case .revisions:
            RevisionsSheet(document: document)
        case .commandPalette:
            CommandPaletteSheet()
        case .fileBrowser:
            FileBrowserSheetView()
        case .multiFileSearch:
            MultiFileSearchSheet()
        case .preferences:
            NavigationStack { PreferencesView() }
        case .tabSwitcher:
            // EditorScene presents the switcher inline so the editor frame
            // can morph into the active card via matchedGeometryEffect.
            EmptyView()
        case .processLines:
            ProcessLinesSheet()
        case .canonize:
            CanonizeSheet()
        case .characterPanel:
            CharacterPanelSheet()
        case .markdownTable:
            MarkdownTableSheet()
        case .markdownPreview:
            MarkdownPreviewSheet()
        case .organizeFootnotes:
            OrganizeFootnotesSheet()
        case .spellCheck:
            SpellCheckSheet()
        }
    }

    private func lineCount(in text: String) -> Int {
        TextMetrics.lineCount(in: text as NSString)
    }

    private func goToLine(_ line: Int) {
        state.textView?.goToLine(line)
    }
}

