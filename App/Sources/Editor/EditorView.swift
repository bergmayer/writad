import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

struct EditorView: View {

    let document: PlainTextDocument
    let state: EditorState

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.openWindow) private var openWindow
    // `showingInfo` lives on EditorState now (state.inspectorOpen)
    // so menu commands (View ▸ Show File Information) and the
    // status-bar ⓘ button hit the same source of truth.
    /// Read directly from `@AppStorage` (not the per-window
    /// `EditorState.showToolbar` mirror) so the View → Show Toolbar
    /// toggle propagates to *every* open window, not just the one that
    /// was active when the user flipped it.
    @AppStorage(AppPreferenceKey.showToolbar) private var showToolbarPref: Bool = true
    /// Per-process theme preference. Synced into `state.themeName`
    /// on change so existing scenes pick up Settings ▸ Editor ▸
    /// Appearance changes immediately — without this, state.themeName
    /// only matched the pref at scene init.
    @AppStorage(AppPreferenceKey.themeName) private var themeNamePref: String = AppThemeName.automatic.rawValue
    /// Same pattern for the body font size and font face — Settings
    /// changes should hit every open window, not just newly-spawned
    /// ones. The Stepper / Picker in Preferences writes UserDefaults;
    /// the `.onChange` below syncs each into `state`, which the
    /// engine then picks up via `observeStateForEngineUpdates`.
    @AppStorage(AppPreferenceKey.fontSize) private var fontSizePref: Double = 14
    @AppStorage(AppPreferenceKey.fontName) private var fontNamePref: String = EditorFont.systemMono.rawValue
    /// `.compact` when the host window is too narrow for the wide iPad
    /// chrome — happens in iPad Split View, Slide Over, and Stage
    /// Manager's skinny side panel, where each status-bar label would
    /// otherwise wrap glyph-by-glyph into a vertical column. Drives
    /// the choice between `statusBar` and the overflow-menu `phoneStatusBar`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// True when the scene is wider than ~phone width. Anything narrower
    /// (Stage Manager skinny, Split View ⅓, etc.) collapses into the
    /// compact phone-style chrome regardless of device idiom.
    private var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        observeStateForEngineUpdates()
        // Layout reasoning:
        //
        // The previous design (VStack + .padding(.bottom, keyboardOverlap))
        // lifted the *entire* editor stack by the on-screen keyboard's
        // height. That kept the status bar above the keyboard but
        // shrank the editor body — on iPad portrait the editor ended
        // up squashed into the top ~30 % of the window while the
        // accessory bar sat just above the keyboard. The user's
        // complaint was exactly that: the keyboard area looked like
        // it took over the window.
        //
        // New layout: the editor extends full height (ignores the
        // keyboard safe area), so UITextView's own contentInset is
        // what scrolls the cursor into view — same trick Notes /
        // Mail / Safari use. The status bar is a separate ZStack
        // layer that respects the keyboard safe area, so SwiftUI's
        // automatic avoidance lifts it above the keyboard without
        // resizing the editor underneath.
        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // WindowToolbar lives in EditorScene now (above the
                // TabBarView, Safari-style). EditorView only owns the
                // text view and the status bar overlay.
                splitOrSingleEditor
                    .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if state.showStatusBar {
                // Compact width = iPhone OR narrow iPad multitasking
                // slot. The wide `statusBar` wraps every label
                // glyph-by-glyph at sub-tablet widths; the compact
                // variant folds the per-document settings (encoding,
                // line endings, syntax) into an overflow menu so the
                // bar stays one line tall.
                if DeviceIdiom.isPhone || isCompactWidth {
                    phoneStatusBar
                } else {
                    statusBar
                }
            }
            // Floating status bar — sits on top of the editor's
            // lowest ~40 pt when the keyboard is down, and gets
            // automatically pushed above the keyboard when it's up.
            // No explicit padding / notification observers needed.
        }
        // CotEditor-style side inspector. Slides in from the trailing
        // edge of this scene (not modal), so the editor stays editable
        // while the user reads the file metadata or jumps through the
        // outline. Triggered by the ⓘ button in the bottom-right status bar.
        .inspector(isPresented: Binding(
            get: { state.inspectorOpen },
            set: { state.inspectorOpen = $0 }
        )) {
            InfoInspectorSheet(document: document, state: state, onJump: { goToLine($0) })
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        // Lightweight overlay while a load is in flight — covers the
        // editor surface so the user can't type into a buffer that's
        // about to be replaced, and signals that the file (which may be
        // downloading from a File Provider) is on its way.
        .overlay {
            if document.isLoading { loadingOverlay }
        }
        // Sheets and file pickers gate on `isActive` so they only present
        // on the window the user is interacting with — not every window
        // bound to the shared AppStateBus.
        .sheet(item: isActive ? $bus.editing.presentedSheet : .constant(nil)) { sheet in
            sheetContent(for: sheet)
        }
        // (Per-scene SheetPresenter was here; moved to EditorScene
        // where the session is in scope, so the closure can update
        // both `currentEditor` and `currentSession` — sheets that
        // read either now consistently land on the foreground
        // window.)
        // Error alert for load failures (file too large, decode error,
        // security-scoped resource denied, etc.) — only fires on the
        // currently active editor so a popup doesn't appear in every
        // open window.
        .alert(
            "Couldn't open file",
            isPresented: openErrorAlertBinding,
            presenting: bus.editing.openErrorMessage
        ) { _ in
            Button("OK") { bus.editing.openErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        // Unsaved-changes confirmation. Hosted on every editor scene
        // (gated by `isActive`) so a stray prompt from a background
        // window doesn't surface on the wrong scene. The pending
        // record carries its source session id, so the discard /
        // save paths target the right window regardless.
        // Centered modal alert instead of a popover-style
        // confirmationDialog — on iPad the dialog rendered as a
        // popover with an arrow tail pointing back to whatever
        // close control fired it, which made no sense in this app
        // (the close paths originate from disparate places: tab
        // strip, switcher, ⌘W, command palette). An alert always
        // centers and never grows a tail.
        .alert(
            "Close \(bus.editing.pendingClose?.displayName ?? "tab")?",
            isPresented: pendingCloseBinding,
            presenting: bus.editing.pendingClose
        ) { pending in
            // For saved files this writes back to the existing URL;
            // for untitled buffers it opens Save As (the user picks
            // a location, then we close the tab).
            Button(pending.isUntitled ? "Save…" : "Save and Close") {
                CommandActions.confirmSaveAndClose(pending)
            }
            Button("Discard Changes", role: .destructive) {
                CommandActions.confirmDiscardAndClose(pending)
            }
            Button("Cancel", role: .cancel) { CommandActions.cancelPendingClose() }
        } message: { pending in
            Text(pending.isUntitled
                 ? "This document is untitled. Save it to a file or discard the contents."
                 : "This document has unsaved changes since its last save.")
        }
        .onAppear {
            primeStateFromDocument()
            AppStateBus.shared.scenes.currentEditor = state
            AppStateBus.shared.scenes.openWindowAction = { id in openWindow(id: id.rawValue) }
            if let session = AppStateBus.shared.scenes.currentSession {
                AppStateBus.shared.scenes.registerSession(session)
            }
        }
        // No `.onDisappear` clearing `currentEditor`: SwiftUI fires
        // `onDisappear` whenever the scene loses focus (palette window,
        // preferences, multi-tasking swipe). Nil'ing the weak ref here
        // left the menu bar dimmed even though the editor was still
        // alive behind another window. `currentEditor` is a `weak var`,
        // so it auto-nils when the `EditorState` is genuinely
        // deallocated (the user actually closed every window).
        .onChange(of: state.fileEncoding) { _, newValue in document.fileEncoding = newValue }
        .onChange(of: state.lineEnding)   { _, newValue in document.lineEnding = newValue }
        // Theme preference → per-window state. The engine recreates
        // the theme from `state.themeName`; the sync makes a Settings
        // change apply to every open scene, not just newly-spawned ones.
        .onChange(of: themeNamePref) { _, raw in
            // Per-window override wins — global Settings changes
            // don't clobber a theme the user set locally via the
            // info inspector's Window Theme picker.
            guard state.themeOverride == nil else { return }
            state.themeName = AppThemeName(stored: raw)
        }
        .onChange(of: fontSizePref) { _, newValue in
            // Stepper writes 9–96; ignore zero in case UserDefaults
            // briefly returns 0 during a write race. Per-window
            // override wins — global Settings doesn't clobber it.
            guard state.fontSizeOverride == nil else { return }
            if newValue > 0 { state.fontSize = newValue }
        }
        .onChange(of: fontNamePref) { _, newRaw in
            guard state.fontOverride == nil else { return }
            state.font = EditorFont(stored: newRaw)
        }
        // Autosave runs on a buffer-changed signal, not on full text
        // observation. `document.bufferRevision` is a tiny UInt64
        // bumped by the engine's text-view coordinator on every edit;
        // observing it avoids re-evaluating the body — and re-running
        // every observed sub-view's body modifiers — on every
        // keystroke. The previous `onChange(of: document.text)`
        // pattern pulled the full buffer (a Swift String reference
        // copy is cheap, but observation invalidation on a 1 MB+
        // value cascading through the SwiftUI rendering graph is
        // not) — that was the per-keystroke freeze on McCartney.
        .onChange(of: document.bufferRevision) { _, _ in
            scheduleAutoSave()
        }
        // External writers (load, revert, restore-from-revisions) DO
        // change `document.text` wholesale. The engine text view's
        // `updateUIView` already detects those via its
        // `lastPushedDocumentText` cache and pushes them; nothing
        // else needs to observe `document.text` per render here.
        // No `.task(id:)` for the debounce — using a stored Task on
        // EditorState gives us cooperative cancellation across rapid
        // edits without restarting from SwiftUI's identity machinery.
        .navigationTitle(documentTitle)
        .navigationSubtitle(documentSubtitle)
        .navigationBarTitleDisplayMode(.inline)
        // iPad: hide the system nav bar when the custom WindowToolbar
        // pill is up (title is shown there). iPhone: always show the
        // system nav bar — that's where the filename lives.
        .toolbar(
            (DeviceIdiom.supportsMultipleWindows && showToolbarPref) ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            // iPhone-only nav bar buttons. Leading edge: gear (Settings),
            // then file (document shell). Trailing edge: undo, then
            // command palette. Items with the same placement render in
            // declaration order from leading-to-trailing.
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
                    // Replace the system navigationTitle with the
                    // tappable / renameable title button. Stays in
                    // sync with `documentTitle` via the SwiftUI
                    // value chain — the bus-read in EditableTitleView
                    // covers state/document mutations.
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

    /// `true` while this scene is the foreground/focused editor in a
    /// multi-window session. Used to gate sheet / picker presentation so
    /// shared bus flags only affect the active window.
    private var isActive: Bool {
        bus.scenes.currentEditor === state
    }

    /// Binding for the unsaved-changes confirmation dialog. Matches
    /// the pending tab's owning session against this scene's session
    /// so the dialog fires on the right window in multi-window setups
    /// — without freezing the app. `allOpenSessions` is now read-
    /// only (no in-getter mutation), so it's safe to call directly
    /// from a binding.
    private var pendingCloseBinding: Binding<Bool> {
        Binding(
            get: {
                guard let pending = bus.editing.pendingClose else { return false }
                let mySession = bus.scenes.allOpenSessions.first { session in
                    session.tabs.contains { $0.state === state }
                }
                // Fall back to identity check when the registry hasn't
                // caught up — better to show the dialog on the active
                // scene than to silently drop it, since this is the
                // "don't lose user data" path.
                guard let mySession else { return isActive }
                return ObjectIdentifier(mySession) == pending.sessionID
            },
            set: { newValue in
                if !newValue { bus.editing.pendingClose = nil }
            }
        )
    }

    private var openErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { isActive && bus.editing.openErrorMessage != nil },
            set: { newValue in
                if !newValue { bus.editing.openErrorMessage = nil }
            }
        )
    }

    /// Plain document name. The unsaved indicator is surfaced in the
    /// subtitle ("edited") so the title itself stays uncluttered.
    private var documentTitle: String {
        document.fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Subtitle = "edited" hint + file-location breadcrumb, joined
    /// with a middle dot when both apply. Untitled documents count
    /// as "edited" until first save. Clean URL-backed docs show
    /// just the location.
    private var documentSubtitle: String {
        let unsaved = document.fileURL == nil || document.isDirty
        let location: String = document.fileURL.map { DocumentLocation.describe(parentOf: $0) } ?? ""
        switch (unsaved, location.isEmpty) {
        case (true, true):   return "edited"
        case (true, false):  return "edited · \(location)"
        case (false, true):  return ""
        case (false, false): return location
        }
    }

    /// `UIViewRepresentable.updateUIView` only runs when SwiftUI re-evaluates
    /// this body, and that only happens when an `@Observable` property is
    /// *read here*. Touching every state property the engine cares about
    /// guarantees menu changes propagate. NOTE: do NOT touch
    /// `document.bufferRevision` here — that bumps on every keystroke
    /// and would re-introduce the per-keystroke body re-eval cost we
    /// just removed. `document.text` is safe to touch: it changes only
    /// on external writes (load / revert / restore) and on a 300 ms-
    /// debounced snapshot after editing pauses.
    private func observeStateForEngineUpdates() {
        _ = document.text  // catches load / revert / restore-from-revision pushes
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
        _ = state.sidebarOpen
        _ = state.splitOpen
        _ = state.splitFraction
        _ = state.splitOrientation
    }

    private func primeStateFromDocument() {
        state.text = document.text
        // Treat the as-loaded text as the diff baseline. Save flows
        // also rewrite this (see EditorScene's save closure) so the
        // gutter resets after a successful write.
        state.savedBaselineText = document.text
        state.fileEncoding = document.fileEncoding
        state.lineEnding = document.lineEnding
        state.fileURL = document.fileURL
        if let url = document.fileURL {
            state.languageIdentifier = LanguageRegistry.identifier(for: url)
        }
        // Background tabs miss `.onChange(of:)` while they're not
        // mounted, so a Settings ▸ Theme / Font change between
        // their init and their next activation would otherwise
        // leave them stale. Re-seed from current defaults whenever
        // this view appears, unless the user has set a per-window
        // override (in which case override wins).
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
        // Capture `state` weakly: closures stored on `state` that capture
        // it strongly would create an ARC cycle.
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
                    // Cancel the in-flight load. The task's defer
                    // clears state.loadTask; the catch on
                    // CancellationError flips `isLoading` off.
                    state.loadTask?.cancel()
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Friendly "Loading <name>… from <provider>" message shown in the
    /// overlay. Provider name comes from the same breadcrumb logic the
    /// title-bar subtitle uses.
    private var loadingMessage: String {
        // During an Open-in-new-window load, document.fileURL is still
        // nil until applyPayload — pull the URL from state if available.
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

    // MARK: - Status bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 12) {
            // Split cycle lives at the lower-left of the iPad window
            // so it's reachable with a thumb regardless of how the
            // status bar's center metrics expand. The cycle glyph
            // updates to reflect the current state (rectangle /
            // split-2x1 / split-1x2).
            splitCycleButton
            Divider().frame(height: 14)
            counts.foregroundStyle(.secondary)
            Spacer(minLength: 8)
            byteCountLabel.foregroundStyle(.secondary)
            Divider().frame(height: 14)
            encodingMenu
            Divider().frame(height: 14)
            lineEndingMenu
            Divider().frame(height: 14)
            languageMenu
            Divider().frame(height: 14)
            revisionsButton
            Divider().frame(height: 14)
            infoToggle
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Compact iPhone status bar: an overflow menu for the
    /// per-document settings (encoding / line endings / language /
    /// revisions) and the info ⓘ. Palette and Settings live in the
    /// nav bar on iPhone; counts / byte size are reachable through
    /// the info inspector — fitting them on a phone width turns
    /// into wrapped, unreadable text.
    @ViewBuilder
    private var phoneStatusBar: some View {
        HStack(spacing: 16) {
            phoneTabsButton
            splitCycleButton
            Spacer()
            revisionsButton
            phoneOverflowMenu
            infoToggle
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        // Horizontal swipe on the strip = prev/next tab, matching
        // Safari's URL-bar swipe. Threshold is comfortably large so
        // a stray scroll on the bar doesn't toggle tabs.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                    if value.translation.width < -40 {
                        CommandActions.nextTab()
                    } else if value.translation.width > 40 {
                        CommandActions.previousTab()
                    }
                }
        )
    }

    /// iPhone-only nav-bar control combining the command palette
    /// and the customizable toolbar menu. When the user has the
    /// toolbar enabled in Settings, this renders as a `Menu` with
    /// **Command Palette…** as the first row and every
    /// `ToolbarConfig.shared.slots` entry beneath it. When the
    /// toolbar is turned off, it collapses to a plain
    /// command-palette button — keeps the nav bar from
    /// permanently growing a third trailing icon.
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

    /// Single editor, OR two editors over the same document when
    /// split mode is on. Horizontal orientation lays them out
    /// left/right (HStack); vertical lays them top/bottom (VStack).
    /// The divider is a draggable 6 pt strip; pane size tracks
    /// `state.splitFraction` along the orientation's axis.
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

    // (documentTextBinding retired with the per-keystroke buffer
    // flow refactor. The engine's text view owns the live buffer;
    // `document.text` is now a debounced snapshot for eventual-
    // consistency consumers and is only assigned wholesale on
    // load / revert / restore paths.)

    @ViewBuilder
    private func splitDivider(in totalSize: CGFloat, axis: SplitOrientation) -> some View {
        // Draggable 6 pt strip — width vs height swap depending on
        // split axis. Drag offset reads from the same axis so a
        // top/bottom split tracks vertical drags, not horizontal.
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

    /// Claim "I'm the foreground scene" on the bus. Called from every
    /// in-scene button that fires a presentation action, so the
    /// resulting sheet / picker / window lands on this scene even
    /// when SwiftUI's scenePhase hasn't fired yet (iPad Stage Manager
    /// + Split View race that bites the menu-bar Open / Palette
    /// flow).
    private func claimFocus() {
        bus.scenes.currentEditor = state
        if let session = bus.scenes.currentSession,
           !session.tabs.contains(where: { $0.state === state }) {
            // The session pointer was stale (different window's
            // session). Find the session that owns this state and
            // promote it.
            for candidate in bus.scenes.allOpenSessions {
                if candidate.tabs.contains(where: { $0.state === state }) {
                    bus.scenes.currentSession = candidate
                    break
                }
            }
        }
    }

    @ViewBuilder
    private var phoneCombinedMenu: some View {
        let registry = CommandRegistry.all()
        let slots = ToolbarConfig.shared.slots
        Menu {
            // Command Palette is pinned at the top of the menu — same
            // affordance the standalone button gives when the toolbar
            // is disabled, just folded into the toolbar menu so the
            // nav bar carries one icon instead of two.
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Label("Command Palette…", systemImage: "command.square")
            }
            if !slots.isEmpty {
                Divider()
                ForEach(slots) { slot in
                    if let cmd = registry.first(where: { $0.id == slot.commandId }) {
                        Button {
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

    /// iPhone-only: Safari-style tabs button. Tap opens the tab
    /// switcher sheet; the badge shows current tab count when > 1.
    @ViewBuilder
    private var phoneTabsButton: some View {
        Button {
            CommandActions.showTabSwitcher()
        } label: {
            ZStack {
                Image(systemName: "square.on.square")
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                if let count = phoneTabBadgeCount {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: .capsule)
                        .offset(x: 10, y: -8)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show All Tabs")
        .accessibilityLabel("Show All Tabs")
    }

    private var phoneTabBadgeCount: Int? {
        let count = bus.scenes.currentSession?.tabs.count ?? 1
        return count > 1 ? count : nil
    }

    @ViewBuilder
    private var phoneOverflowMenu: some View {
        Menu {
            Menu("Encoding")      { encodingMenuChoices }
            Menu("Line Endings")  { lineEndingMenuChoices }
            Menu("Syntax")        { languageMenuChoices }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .help("Document settings")
    }

    /// Cycle button for split view (off → horizontal → vertical →
    /// off). Glyph mirrors the current state so the user can read
    /// the bar at a glance: side-by-side rectangle for horizontal,
    /// stacked for vertical, single rectangle when off.
    @ViewBuilder
    private var splitCycleButton: some View {
        Button {
            CommandActions.cycleSplitView()
        } label: {
            Image(systemName: splitCycleSymbolName)
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(splitCycleLabel)
        .help(splitCycleLabel)
    }

    private var splitCycleSymbolName: String {
        switch (state.splitOpen, state.splitOrientation) {
        case (false, _):          return "rectangle"
        case (true, .horizontal): return "rectangle.split.2x1"
        case (true, .vertical):   return "rectangle.split.1x2"
        }
    }

    private var splitCycleLabel: String {
        switch (state.splitOpen, state.splitOrientation) {
        case (false, _):          return "Open Split View"
        case (true, .horizontal): return "Switch to Vertical Split"
        case (true, .vertical):   return "Close Split View"
        }
    }

    /// Snapshot the document ~800 ms after typing stops. Disk-backed
    /// docs round-trip through `autoSave` (write to URL + record
    /// revision); untitled buffers get `autoSnapshot` (revision only,
    /// no disk touch — the sandbox requires a user-granted location).
    /// Initial loads opt out so `loadAsync`'s text stream doesn't
    /// immediately echo back.
    private func scheduleAutoSave() {
        guard !document.isLoading, document.isDirty else { return }
        state.autoSaveTask?.cancel()
        state.autoSaveTask = Task { @MainActor [weak document, weak state] in
            defer { state?.autoSaveTask = nil }
            try? await Task.sleep(for: Timing.autoSaveDebounce)
            if Task.isCancelled { return }
            guard let document, document.isDirty else { return }
            // Snapshot live buffer from the engine before encoding.
            // `document.text` is a 300 ms-debounced snapshot — at the
            // autosave debounce (800 ms after typing stop) it's
            // usually up to date, but a single dropped tick would
            // mean autosaving stale bytes. Cheap to be explicit.
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

    /// Status-bar entry into the document's revision history. Always
    /// enabled — untitled buffers still capture in-memory snapshots
    /// keyed by the tab's UUID, so there's something useful to browse.
    @ViewBuilder
    private var revisionsButton: some View {
        Button {
            CommandActions.presentRevisions()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Browse and restore previous versions of this document")
    }

    /// Tiny chevron-less button at the bottom-right of the status bar.
    /// Toggles the side `.inspector` panel that shows File / Outline /
    /// Count. The current tinted style indicates open vs. closed at a
    /// glance — matching CotEditor's persistent inspector button.
    @ViewBuilder
    private var infoToggle: some View {
        Button {
            state.inspectorOpen.toggle()
        } label: {
            // CotEditor-style: outline-less "i" glyph (the `info`
            // SF symbol). The standalone `i` reads as plain text
            // weight, so it doesn't compete with the surrounding
            // status-bar dropdowns.
            Image(systemName: "info")
                .font(.system(size: 14, weight: state.inspectorOpen ? .bold : .regular))
                .foregroundStyle(state.inspectorOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show file info, outline, and counts")
    }

    @ViewBuilder
    private var counts: some View {
        let nsText = document.text as NSString
        let (line, column) = TextMetrics.lineColumn(for: state.selectedRange.location, in: nsText)
        let lineCount = TextMetrics.lineCount(in: nsText)
        HStack(spacing: 8) {
            Text("Lines: \(lineCount)  ·  Chars: \(nsText.length)  ·  Loc: \(state.selectedRange.location)  ·  Ln \(line):\(column)")
            if state.liveMatchCount > 0 {
                Text("·  \(state.liveMatchCount) match\(state.liveMatchCount == 1 ? "" : "es")")
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var byteCountLabel: some View {
        let bytes = document.originalData?.count ?? document.text.utf8.count
        Text("\(byteFormatter(bytes)) bytes")
    }

    private func byteFormatter(_ bytes: Int) -> String {
        // Compact integer with grouping separators — matches CotEditor's
        // "14 bytes" / "1,276,305 bytes" style.
        bytes.formatted(.number)
    }

    /// CotEditor-style encoding popover. Lists every encoding the platform
    /// reports plus a "with BOM" toggle for UTF-8; selection re-decodes the
    /// original file bytes if possible.
    @ViewBuilder
    private var encodingMenu: some View {
        Menu { encodingMenuChoices } label: {
            statusMenuLabel(document.fileEncoding.localizedName)
        }
    }

    @ViewBuilder
    private var encodingMenuChoices: some View {
        ForEach(statusEncodingChoices, id: \.self) { encoding in
            let title = String.localizedName(of: encoding)
            Button {
                state.fileEncoding = FileEncoding(encoding: encoding)
            } label: {
                if document.fileEncoding.encoding == encoding && !document.fileEncoding.withUTF8BOM {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
        if statusEncodingChoices.contains(.utf8) {
            Divider()
            Button {
                state.fileEncoding = FileEncoding(encoding: .utf8, withUTF8BOM: true)
            } label: {
                if document.fileEncoding.encoding == .utf8 && document.fileEncoding.withUTF8BOM {
                    Label("Unicode (UTF-8) with BOM", systemImage: "checkmark")
                } else {
                    Text("Unicode (UTF-8) with BOM")
                }
            }
        }
    }

    @ViewBuilder
    private var lineEndingMenu: some View {
        Menu { lineEndingMenuChoices } label: {
            statusMenuLabel(document.lineEnding.label)
        }
    }

    @ViewBuilder
    private var lineEndingMenuChoices: some View {
        ForEach(LineEnding.allCases, id: \.self) { ending in
            Button {
                state.lineEnding = ending
            } label: {
                if document.lineEnding == ending {
                    Label("\(ending.label) (\(ending.description))", systemImage: "checkmark")
                } else {
                    Text("\(ending.label) (\(ending.description))")
                }
            }
        }
    }

    @ViewBuilder
    private var languageMenu: some View {
        Menu { languageMenuChoices } label: {
            statusMenuLabel(LanguageRegistry.displayName(for: state.languageIdentifier))
        }
    }

    @ViewBuilder
    private var languageMenuChoices: some View {
        ForEach(LanguageRegistry.all, id: \.identifier) { language in
            Button {
                state.languageIdentifier = language.identifier
            } label: {
                if state.languageIdentifier == language.identifier {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    private func statusMenuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }

    /// Same logic as `EncodingPickerSheet.encodingChoices` — kept local
    /// so the status menu doesn't need to import the sheet.
    private var statusEncodingChoices: [String.Encoding] {
        String.sortedAvailableStringEncodings.compactMap { $0 }
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
        case .snippetPicker:
            SnippetPickerSheet()
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
            // No longer routed through .sheet — EditorScene presents
            // it inline so the editor frame can morph into the active
            // tab's grid card via matchedGeometryEffect.
            EmptyView()
        case .processLines:
            ProcessLinesSheet()
        case .canonize:
            CanonizeSheet()
        case .characterPanel:
            CharacterPanelSheet()
        // .notebooks case removed — feature retired.
        case .markdownTable:
            MarkdownTableSheet()
        case .markdownPreview:
            MarkdownPreviewSheet()
        case .organizeFootnotes:
            OrganizeFootnotesSheet()
        }
    }

    private func lineCount(in text: String) -> Int {
        TextMetrics.lineCount(in: text as NSString)
    }

    private func goToLine(_ line: Int) {
        state.textView?.goToLine(line)
    }
}

