import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

/// Top-level scene root. Owns one `EditorSession` (tab collection)
/// per window, threads the active tab's document + state through
/// `EditorView`, and hosts the scene-level modifiers — file pickers,
/// sheet presentation, scene-phase lifecycle, and the bus registrations
/// that let menu commands target this scene.
///
/// File I/O goes through SwiftUI's `.fileImporter` / `.fileExporter`
/// rather than `DocumentGroup`, because the `com.apple.FileProvider.
/// LocalStorage` indexer on the iOS 26.5 simulator misroutes bookmarks
/// just-imported documents — see `PlainTextDocument` for the long form.
struct EditorScene: View {

    @State private var session = EditorSession()
    @Bindable private var bus = AppStateBus.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    /// Tracks whether this scene's `onAppear` has fired before, so a
    /// focus-change re-appearance doesn't re-show the drafts sheet
    /// after the user already dismissed it. `onAppear` fires for every
    /// foreground transition, not just the first mount.
    @State private var didOfferDraftsForThisScene = false
    /// Drives the scene's `.preferredColorScheme` so the nav bar,
    /// status bar, and modal sheets tone-match the editor theme
    /// (Dracula → dark chrome, Solarized Light → light chrome, etc.).
    @AppStorage(AppPreferenceKey.themeName) private var themeNamePref: String = AppThemeName.automatic.rawValue
    @AppStorage(AppPreferenceKey.showToolbar) private var showToolbarPref: Bool = true

    /// Namespace shared between the active editor stack and the tab
    /// switcher's active card. Drives the Safari-style morph: the
    /// editor's frame shrinks into the card on present and grows
    /// back out on dismiss.
    @Namespace private var tabSwitcherNS

    /// Convenience accessors so the existing modifier chain below didn't
    /// have to be rewritten to thread `session.activeTab` through every
    /// reference. Active tab is the source of truth — these just unwrap.
    private var document: PlainTextDocument { session.activeTab.document }

    /// Build the encoded snapshot for Save As. Pulls live text from
    /// the engine before encoding so a Save-As immediately after a
    /// keystroke captures the actual buffer, not the 300 ms-
    /// debounced `document.text` snapshot.
    ///
    /// **Must be side-effect free.** SwiftUI evaluates the
    /// `.fileExporter(document:)` argument on every body re-render —
    /// not just when Save As is invoked. An earlier version assigned
    /// the live text back into `document.text` here, which raced with
    /// `applyPayload`'s loaded text and intermittently wiped a
    /// freshly-loaded file (post-load body re-eval read the still-
    /// empty `state.textView?.text` and clobbered the buffer back to
    /// "" before `updateUIView` had a chance to push). Treat this as
    /// a pure read.
    private func liveEncodedSnapshot() -> Data {
        let liveText = state.textView?.text ?? document.text
        let defaults = UserDefaults.standard
        return (try? PlainTextDocument.encode(
            text: liveText,
            encoding: document.fileEncoding,
            lineEnding: document.lineEnding,
            trimTrailingWhitespace: defaults.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave),
            ensureTrailingNewline: defaults.bool(forKey: AppPreferenceKey.ensureTrailingNewline),
            saveUTF8BOMPref: defaults.bool(forKey: AppPreferenceKey.saveUTF8BOM)
        )) ?? Data()
    }
    private var state: EditorState { session.activeTab.state }

    /// `true` while this scene owns the foreground editor. File pickers
    /// (Open / Save As / Insert File / Insert Folder) read from the
    /// shared `pickers.pending` bus, so without this gate **every**
    /// open window would present the picker when a menu command set
    /// the pending flag — visible bug: long-pressing the title and
    /// choosing "Save…" surfaced a Save dialog on every window. Only
    /// the focused scene should react.
    private var isActive: Bool {
        bus.scenes.currentEditor === state
    }

    /// Plain document name — the unsaved indicator lives in the
    /// subtitle now ("edited") instead of a bullet glyph in front of
    /// the title. Lives on the scene because WindowToolbar reads
    /// these too.
    private var documentTitle: String {
        document.fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Combines the macOS-style "edited" hint with the file's
    /// location breadcrumb. Either piece can be empty (untitled
    /// + clean = empty subtitle); we join with a middle dot only
    /// when both sides have content.
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

    var body: some View {
        // NavigationStack gives each window a real title-bar region so
        // iPadOS draws its window controls (close / minimize / resize)
        // in the standard top-left position instead of squeezing a
        // resize grabber into the middle of our content.
        NavigationStack {
            ZStack {
                editorStack
                    // matchedGeometryEffect on the entire editor
                    // column so its frame animates to the active
                    // tab's grid card position when the switcher
                    // comes up. The card's matching effect (in
                    // TabSwitcherView) acts as the destination.
                    .matchedGeometryEffect(
                        id: switcherMatchID,
                        in: tabSwitcherNS,
                        properties: .frame,
                        isSource: !bus.editing.tabSwitcherActive
                    )
                    // Fade the editor under the switcher so the
                    // morph reads as "editor → card" rather than
                    // "editor + card overlapping".
                    .opacity(bus.editing.tabSwitcherActive ? 0 : 1)
                    .allowsHitTesting(!bus.editing.tabSwitcherActive)

                if bus.editing.tabSwitcherActive {
                    TabSwitcherView(
                        session: session,
                        namespace: tabSwitcherNS,
                        matchID: switcherMatchID,
                        onDismiss: dismissSwitcher
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
        .preferredColorScheme(scenePreferredScheme)
        // Publish the session as a focused-scene value so menu bar
        // commands (New Tab, Close Tab, Reopen, Next/Previous Tab,
        // Jump to Tab N, Show All Tabs, Open Current File in New
        // Window, etc.) always hit the foreground scene's session
        // even when `AppStateBus.scenes.currentSession` lags.
        .focusedSceneValue(\.focusedSession, session)
        // Per-scene sheet presenter — menu bar commands resolve this
        // via @FocusedValue, so any sheet trigger from the menu lands
        // on the foreground scene. The closure refreshes both
        // currentEditor and currentSession on the bus so sheet
        // content (Clipboard History, command palette, etc.) reads
        // the same window the user is actually looking at — fixes
        // the "modal shows up on the wrong window" class of bug.
        .focusedSceneValue(\.presentEditorSheet, SheetPresenter { [session] sheet in
            AppStateBus.shared.scenes.currentSession = session
            AppStateBus.shared.scenes.currentEditor = session.activeTab.state
            AppStateBus.shared.editing.presentedSheet = sheet
        })
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    // Reclaim "current" pointers so the menu bar's
                    // File commands target the focused scene rather
                    // than whichever one appeared most recently.
                    AppStateBus.shared.scenes.currentSession = session
                    AppStateBus.shared.scenes.registerSession(session)
                    AppStateBus.shared.scenes.currentEditor = session.activeTab.state
                    AppStateBus.shared.scenes.openWindowAction = { id in openWindow(id: id.rawValue) }
                    AppStateBus.shared.scenes.routeOpenURL = { url in route(open: url) }
                    AppStateBus.shared.editing.saveCurrentDocument = { [weak session] in
                        guard let session, session.activeTab.document.fileURL != nil else {
                            AppStateBus.shared.pickers.pending = .saveAs
                            return
                        }
                        let tab = session.activeTab
                        // The engine text view holds the live buffer;
                        // `document.text` is a 300 ms-debounced snapshot.
                        // For an explicit ⌘S we want the user's latest
                        // characters, so pull from the engine before
                        // encoding.
                        if let live = tab.state.textView?.text {
                            tab.document.text = live
                        }
                        do {
                            try tab.document.save()
                            // Save just made the disk and the buffer
                            // agree — reset the change-history gutter
                            // baseline so its bars zero out.
                            tab.state.savedBaselineText = tab.document.text
                        } catch { /* errors surface via PlainTextDocument */ }
                    }
                    return
                }
                // Background autosave: snapshot live buffer first
                // (debounced `document.text` may be ~300 ms stale
                // when the scene backgrounds during a fast pause),
                // then write the scratch shadow off-main.
                for tab in session.tabs where tab.document.isDirty {
                    if let live = tab.state.textView?.text {
                        tab.document.text = live
                    }
                    tab.document.autoSave()
                }
            }
            .onAppear {
                AppStateBus.shared.scenes.currentSession = session
                AppStateBus.shared.scenes.registerSession(session)
                AppStateBus.shared.scenes.routeOpenURL = { url in route(open: url) }
                AppStateBus.shared.editing.saveCurrentDocument = { [weak session] in
                    guard let session, session.activeTab.document.fileURL != nil else {
                        AppStateBus.shared.pickers.pending = .saveAs
                        return
                    }
                    let tab = session.activeTab
                    if let live = tab.state.textView?.text {
                        tab.document.text = live
                    }
                    try? tab.document.save()
                }
                let wasFirstScene = isColdLaunchFirstScene
                applyLaunchBehaviorIfFirstScene()
                consumePendingNewWindowURL()
                adoptPendingTabIfAvailable()
                // New-window prompt: anything OTHER than the cold-
                // launch first scene is a user-spawned (or state-
                // restored) window — offer the drafts sheet so the
                // user can recover instead of starting blank.
                offerDraftsIfNotFirstScene(wasFirstScene: wasFirstScene)
            }
            // System file-hand-off: Files app "Open in Ayyyy", any
            // app's share sheet, and the `LSSupportsOpeningDocuments
            // InPlace` plumbing all surface here. Route through the
            // standard open path so the user's `DocumentDestination`
            // preference (new window vs new tab) is honoured.
            .onOpenURL { url in
                route(open: url)
            }
            .onDisappear {
                AppStateBus.shared.scenes.deregisterSession(session)
                // No explicit `currentSession = nil` — the weak ref
                // self-nils on deallocation. Clearing on disappear
                // would also fire on focus change (SwiftUI quirk),
                // which strands menu commands with no target.
                AppStateBus.shared.editing.saveCurrentDocument = nil
                // Cancel any in-flight loads owned by tabs in this
                // session — otherwise closing a window that's still
                // pulling bytes from a slow File Provider leaves the
                // Task running on the main actor, blocking everything
                // until URLSession eventually finishes.
                for tab in session.tabs {
                    tab.state.loadTask?.cancel()
                    tab.state.loadTask = nil
                }
                // Window-close salvage: snapshot every tab that still
                // has content into the persistent Recently Closed
                // pool. Saved files we skip (their bytes are already
                // on disk); untitled buffers we capture so the user
                // can recover from ⇧⌘T after the window's gone.
                // Read live engine text — `document.text` is debounced
                // and may be empty even when the user just typed.
                for tab in session.tabs {
                    if tab.document.fileURL != nil { continue }
                    let liveText = tab.state.textView?.text ?? tab.document.text
                    guard !liveText.isEmpty else { continue }
                    ClosedTabsStore.shared.record(
                        EditorSession.snapshotRecord(of: tab)
                    )
                }
            }
            // File pickers — each `.fileImporter` / `.fileExporter`
            // is attached to its own invisible background view so
            // SwiftUI gives them independent presentation contexts.
            // Stacking multiple `.fileImporter` modifiers on the
            // SAME view silently coalesces to one (only the first
            // binding's `true` flag actually presents anything), so
            // Insert File Contents and Insert Folder Listing never
            // surfaced their pickers — File → Open masked them.
            // The `.background(EmptyView().fileImporter(...))`
            // pattern gives each its own anchor view.
            .background(
                EmptyView().fileImporter(
                    isPresented: isActive ? bus.pickers.binding(for: .open) : .constant(false),
                    allowedContentTypes: PlainTextDocument.supportedReadTypes
                ) { result in
                    if case let .success(url) = result { route(open: url) }
                }
            )
            .background(
                EmptyView().fileExporter(
                    isPresented: isActive ? bus.pickers.binding(for: .saveAs) : .constant(false),
                    document: TextFileWrapperProxy(snapshot: liveEncodedSnapshot()),
                    contentType: PlainTextDocument.supportedWriteType,
                    defaultFilename: state.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
                ) { result in
                    if case let .success(url) = result {
                        document.fileURL = url
                        state.fileURL = url
                        state.languageIdentifier = LanguageRegistry.identifier(for: url)
                        RecentFilesStore.shared.record(url)
                    }
                }
            )
            .background(
                EmptyView().fileImporter(
                    isPresented: isActive ? bus.pickers.binding(for: .insertFile) : .constant(false),
                    allowedContentTypes: [.text, .plainText, .sourceCode, .data]
                ) { result in
                    if case let .success(url) = result {
                        insertFileContents(at: url)
                    }
                }
            )
            .background(
                EmptyView().fileImporter(
                    isPresented: isActive ? bus.pickers.binding(for: .insertFolder) : .constant(false),
                    allowedContentTypes: [.folder]
                ) { result in
                    if case let .success(url) = result {
                        insertFolderListing(at: url)
                    }
                }
            )
            .onChange(of: bus.pending.openInPlace) { _, url in
                guard let url else { return }
                openURL(url)
                bus.pending.openInPlace = nil
            }
            .onChange(of: bus.scenes.pendingShortcut) { _, shortcut in
                guard let shortcut else { return }
                applyHomeShortcut(shortcut)
                bus.scenes.pendingShortcut = nil
            }
            .onChange(of: bus.editing.revertRequestCount) { _, _ in
                guard let url = document.fileURL else { return }
                try? document.load(from: url)
                state.text = document.text
                state.savedBaselineText = document.text
                state.fileEncoding = document.fileEncoding
                state.lineEnding = document.lineEnding
            }
    }

    // MARK: - Tab switcher morph

    /// The editor column laid out as it always was — the tab strip
    /// (iPad only, multi-tab only) above the active tab's content.
    /// Pulled out so the ZStack in `body` stays readable. The active
    /// tab's `kind` decides whether the lower region is the editor
    /// or the inline file browser.
    @ViewBuilder
    private var editorStack: some View {
        VStack(spacing: 0) {
            // Safari-style chrome: top row is the toolbar (title +
            // pill + trailing controls), then the tab strip attached
            // directly to the document below it, then the active
            // tab's content. Toolbar is iPad-only (iPhone uses its
            // own nav-bar items).
            if DeviceIdiom.supportsMultipleWindows && showToolbarPref {
                WindowToolbar(
                    title: documentTitle,
                    subtitle: documentSubtitle,
                    onInteraction: {
                        // User tapped a toolbar button — this scene
                        // is definitively the foreground one even if
                        // scenePhase hasn't fired yet, so claim
                        // currentSession / currentEditor here so the
                        // upcoming sheet / picker lands on us.
                        AppStateBus.shared.scenes.currentSession = session
                        AppStateBus.shared.scenes.currentEditor = session.activeTab.state
                    }
                )
            }
            if session.tabs.count > 1, !DeviceIdiom.isPhone {
                TabBarView(session: session)
            }
            HStack(spacing: 0) {
                // Inline outline sidebar — toggled by the leading
                // sidebar button in WindowToolbar. iPad-only (iPhone
                // would eat too much editor width).
                if state.sidebarOpen, !DeviceIdiom.isPhone {
                    OutlineSidebar(state: state)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                activeTabContent
                    .id(session.selectedTabID)   // remount when the
                                                 // active tab swaps so
                                                 // the engine view
                                                 // doesn't try to swap
                                                 // text in place.
            }
        }
    }

    /// What the lower region shows for the active tab. Editor tabs
    /// get the engine view; file-browser tabs get the inline
    /// UIDocumentBrowserViewController, whose pick handler
    /// transforms the tab back to editor mode in place.
    @ViewBuilder
    private var activeTabContent: some View {
        switch session.activeTab.kind {
        case .editor:
            EditorView(document: document, state: state)
        case .fileBrowser:
            FileBrowserTabContent(onPick: { url in
                adoptPickedFileIntoActiveTab(url)
            })
        }
    }

    /// Picker callback from an in-tab browser. Flips the active tab
    /// back to `.editor` and loads the chosen URL into its existing
    /// `PlainTextDocument` — same identity, so the tab pill stays
    /// stable across the transition and the cursor / scroll state
    /// resets cleanly.
    private func adoptPickedFileIntoActiveTab(_ url: URL) {
        let tab = session.activeTab
        tab.kind = .editor
        openURL(url)
    }

    /// Geometry id paired between the editor stack and the active
    /// tab's card in the switcher. Keyed by tab id so swapping tabs
    /// while the switcher is open animates correctly.
    private var switcherMatchID: String {
        "tab-morph-\(session.selectedTabID)"
    }

    private func dismissSwitcher() {
        withAnimation(.appSwitcherMorph) {
            bus.editing.tabSwitcherActive = false
        }
    }

    /// `nil` → defer to system (Automatic). Otherwise force the
    /// scene's color scheme to match the active theme's tonality.
    /// Reads from `@AppStorage` so the change applies to all open
    /// scenes immediately.
    private var scenePreferredScheme: ColorScheme? {
        switch AppThemeName(stored: themeNamePref).preferredColorScheme {
        case .light: return .light
        case .dark:  return .dark
        case .none:  return nil
        case .some(_): return nil
        }
    }

    /// Reads `url`'s text contents and replaces the current selection
    /// (or inserts at the cursor) with them. Cap the read at 5 MB so a
    /// careless tap on a giant file doesn't kill the buffer.
    private func insertFileContents(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 5 * 1024 * 1024 else {
            bus.editing.openErrorMessage = "\(url.lastPathComponent) is too large to insert (>5 MB)."
            return
        }
        if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            state.textView?.replace(state.selectedRange, withText: s)
        }
    }

    /// Walks the top level of `url` (one directory deep) and inserts a
    /// tree-style listing at the cursor. Directories get a trailing
    /// slash so they're visually distinct.
    private func insertFolderListing(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) else { return }
        var lines: [String] = ["\(url.lastPathComponent)/"]
        for entry in contents {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            lines.append("├── \(entry.lastPathComponent)\(isDir ? "/" : "")")
        }
        let nl = state.lineEnding.string
        state.textView?.replace(state.selectedRange, withText: lines.joined(separator: nl) + nl)
    }

    /// On the very first scene appearance per process, honour the
    /// `launchBehavior` preference: if the user opted for the file picker
    /// and this is a fresh blank document, open the picker. Subsequent
    /// new windows are user-initiated (⌘N) and skipped.
    /// `true` once any scene in the process has already finished
    /// its first-time launch handling. The very first scene to
    /// appear at cold launch returns `false` here; every subsequent
    /// scene (state-restored or user-spawned) sees `true`.
    private var isColdLaunchFirstScene: Bool {
        !AppStateBus.shared.scenes.hasAppliedLaunchBehavior
    }

    private func applyLaunchBehaviorIfFirstScene() {
        guard !AppStateBus.shared.scenes.hasAppliedLaunchBehavior else { return }
        AppStateBus.shared.scenes.hasAppliedLaunchBehavior = true
        // The very first scene at cold launch is a fresh blank
        // surface — by user spec we don't disrupt it with a
        // recoverable-drafts prompt. Subsequent windows/tabs get
        // the prompt via `offerDraftsForUserAction()`.
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.launchBehavior) ?? LaunchBehavior.newBlank.rawValue
        guard LaunchBehavior(rawValue: raw) == .openPicker,
              document.fileURL == nil,
              document.text.isEmpty else { return }
        // Defer one tick so the scene is on screen before the sheet animates in.
        DispatchQueue.main.async {
            AppStateBus.shared.pickers.pending = .open
        }
    }

    /// Surface the recovery sheet on a newly-mounted scene unless it's
    /// the cold-launch first scene. Per-scene `@State` flag prevents
    /// re-prompting after the user dismisses it once (every
    /// foreground transition fires `onAppear`).
    private func offerDraftsIfNotFirstScene(wasFirstScene: Bool) {
        guard !wasFirstScene,
              !didOfferDraftsForThisScene,
              !DraftsStore.shared.loadAll().isEmpty
        else { return }
        didOfferDraftsForThisScene = true
        DispatchQueue.main.async {
            AppStateBus.shared.scenes.currentSession = session
            AppStateBus.shared.scenes.currentEditor = session.activeTab.state
            AppStateBus.shared.editing.presentedSheet = .draftsRecovery
        }
    }

    /// "Move Tab to New Window" hands the detached tab off through
    /// `pending.adoptedTab`; the freshly-spawned scene runs this on
    /// onAppear to swap its default blank tab for the adopted one,
    /// preserving the document, state, and dirty-flag.
    private func adoptPendingTabIfAvailable() {
        guard let adopted = AppStateBus.shared.pending.adoptedTab,
              session.tabs.count == 1,
              session.activeTab.document.fileURL == nil,
              session.activeTab.document.text.isEmpty
        else { return }
        AppStateBus.shared.pending.adoptedTab = nil
        // Drop the placeholder tab the session was born with, then
        // attach the adopted tab. Order matters: insert before remove
        // would briefly leave the session with two tabs and trigger
        // the strip animation; remove-then-insert is invisible.
        let placeholder = session.activeTab
        session.attachTab(adopted)
        if let idx = session.tabs.firstIndex(where: { $0 === placeholder }) {
            session.tabs.remove(at: idx)
        }
    }

    private func consumePendingNewWindowURL() {
        guard let url = AppStateBus.shared.pending.newWindow,
              document.fileURL == nil,
              document.text.isEmpty else { return }
        AppStateBus.shared.pending.newWindow = nil
        openURL(url)
    }

    /// Acts on a home-screen quick action surfaced by `AppDelegateBridge`.
    /// New File spawns a fresh editor window; Command Palette opens its
    /// sheet on the active editor.
    private func applyHomeShortcut(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .newFile:
            openWindow(id: SceneID.editor.rawValue)
        case .commandPalette:
            CommandActions.presentCommandPalette()
        }
    }

    /// Spawn a fresh tab or window per the user's `DocumentDestination`
    /// preference. Hop through `Task { @MainActor in … }` so the
    /// picker / browser scene has a runloop tick to dismiss before
    /// the new scene takes over.
    private func route(open url: URL) {
        let destination = DocumentDestination.current()
        // Clear the one-shot override now that we've committed to a
        // destination — keeps the next unrelated Open from inheriting
        // it.
        AppStateBus.shared.pending.nextOpenDestinationOverride = nil
        switch destination {
        case .window:
            AppStateBus.shared.pending.newWindow = url
            Task { @MainActor in openWindow(id: SceneID.editor.rawValue) }
        case .tab:
            Task { @MainActor in
                session.newTab()
                openURL(url)
            }
        }
    }

    private func openURL(_ url: URL) {
        // Cancel any in-flight load on this scene's active state first.
        state.loadTask?.cancel()

        // Capture the values we need explicitly and weakly so a window
        // close mid-download lets the Task bail in its `defer` instead
        // of pinning the document until URLSession returns.
        // Task explicitly @MainActor so we don't add a redundant
        // MainActor.run hop after the read.
        state.loadTask = Task { @MainActor [weak state, weak document] in
            defer { state?.loadTask = nil }
            guard let state, let document else { return }
            do {
                try await document.loadAsync(from: url)
            } catch is CancellationError {
                document.isLoading = false
                return
            } catch {
                AppStateBus.shared.editing.openErrorMessage = error.localizedDescription
                return
            }
            if Task.isCancelled { return }
            state.fileURL = url
            let limit = SyntaxLimit.current()
            let byteCount = document.originalData?.count ?? document.text.utf8.count
            state.isLargeFile = !limit.allows(byteCount: byteCount)
            state.languageIdentifier = LanguageRegistry.identifier(for: url)
            state.text = document.text
            // Seed the change-history gutter baseline with the as-
            // loaded text so a freshly-opened file shows zero diff
            // bars (rather than the entire file colored "added"
            // green from baseline = "" → current = loaded text).
            state.savedBaselineText = document.text
            state.fileEncoding = document.fileEncoding
            state.lineEnding = document.lineEnding
            RecentFilesStore.shared.record(url)
            let persisted = FoldPersistence.ranges(for: url)
            if !persisted.isEmpty {
                DispatchQueue.main.async { [weak state] in
                    state?.textView?.applyFoldRanges(persisted)
                }
            }
            // Multi-File Search results post a target line alongside the
            // URL. The text view may not be mounted on the first runloop
            // tick after `state.text` is set, so dispatch the jump.
            if let line = AppStateBus.shared.pending.goToLine {
                AppStateBus.shared.pending.goToLine = nil
                DispatchQueue.main.async { [weak state] in
                    state?.textView?.goToLine(line)
                }
            }
        }
    }
}
