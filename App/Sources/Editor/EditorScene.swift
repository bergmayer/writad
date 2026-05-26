import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

/// One `EditorSession` per window. Hosts the scene-level modifiers
/// (pickers, sheets, scene-phase lifecycle, bus registrations).
/// I/O bypasses `DocumentGroup` because of the iOS 26.5 simulator
/// FileProvider FP-1005 bug — see `PlainTextDocument`.
struct EditorScene: View {

    @State private var session = EditorSession()
    @Bindable private var bus = AppStateBus.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    /// `onAppear` fires on every foreground transition. This flag
    /// stops a re-appearance from re-offering the drafts sheet after
    /// the user already dismissed it.
    @State private var didOfferDraftsForThisScene = false
    /// Set from `.onOpenURL` so URL-launched scenes (Files app, share
    /// sheet) skip the drafts banner — the user already declared
    /// intent for a specific file, no need to surface unsaved work.
    @State private var sceneReceivedOpenURL = false
    /// Tracks whether we've already applied a stored `SessionRecord`.
    /// onAppear fires on every foreground transition; restoration is
    /// a one-shot.
    @State private var didApplySessionRecord = false
    /// Per-scene id for the `SessionsStore` record. Fresh per launch
    /// — the restore-queue handles cross-launch identity instead of
    /// trying to match scenes via `@SceneStorage` (SwiftUI only
    /// restores one window by default on iOS).
    @State private var sceneUUID: String = ""
    /// Drives `.preferredColorScheme` so nav bar / sheets tone-match
    /// the editor theme.
    @AppStorage(AppPreferenceKey.themeName) private var themeNamePref: String = AppThemeName.automatic.rawValue
    @AppStorage(AppPreferenceKey.showToolbar) private var showToolbarPref: Bool = true

    /// Shared with the tab switcher's active card so the editor's
    /// frame morphs into the card on present.
    @Namespace private var tabSwitcherNS

    private var document: PlainTextDocument { session.activeTab.document }

    /// **Must be side-effect free.** SwiftUI evaluates the
    /// `.fileExporter(document:)` argument on every body re-render,
    /// not just when Save As fires. An earlier version assigned the
    /// live text back into `document.text` here and raced with
    /// `applyPayload` — a freshly-loaded file would clobber back to
    /// "" before `updateUIView` could push. Treat this as a pure read.
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

    /// Gates the file pickers — they share a bus flag, so without
    /// this every window would present when a menu set the flag.
    /// (Visible bug: title long-press → Save… opened a Save dialog
    /// on every window.)
    private var isActive: Bool {
        bus.scenes.currentEditor === state
    }

    /// On the scene because WindowToolbar reads it too.
    private var documentTitle: String {
        document.fileURL?.lastPathComponent ?? "Untitled"
    }

    /// "edited" hint + location breadcrumb, middle-dot joined when
    /// both apply.
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
        // NavigationStack gives the window a real title-bar region;
        // without it iPadOS squeezes a resize grabber into the middle
        // of our content instead of the standard top-left chrome.
        NavigationStack {
            ZStack {
                editorStack
                    .matchedGeometryEffect(
                        id: switcherMatchID,
                        in: tabSwitcherNS,
                        properties: .frame,
                        isSource: !bus.editing.tabSwitcherActive
                    )
                    // Fade under the switcher so the morph reads as
                    // "editor → card", not "editor + card overlap".
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
        // Menu-bar tab commands resolve this via @FocusedValue —
        // foreground session even when `currentSession` lags.
        .focusedSceneValue(\.focusedSession, session)
        // Per-scene sheet presenter. The closure refreshes both
        // current* pointers so sheet content (Clipboard History,
        // palette, etc.) reads the same window the user sees —
        // fixes the "modal on wrong window" class of bug.
        .focusedSceneValue(\.presentEditorSheet, SheetPresenter { [session] sheet in
            AppStateBus.shared.scenes.currentSession = session
            AppStateBus.shared.scenes.currentEditor = session.activeTab.state
            AppStateBus.shared.editing.presentedSheet = sheet
        })
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    // Reclaim focus pointers so menu-bar commands
                    // target this scene, not whichever appeared last.
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
                        // ⌘S needs the freshest bytes — `document.text`
                        // is a 300 ms snapshot, so pull engine-live.
                        if let live = tab.state.textView?.text {
                            tab.document.text = live
                        }
                        do {
                            try tab.document.save()
                            // Disk + buffer agree — zero the diff bars.
                            tab.state.savedBaselineText = tab.document.text
                        } catch { /* errors surface via PlainTextDocument */ }
                    }
                    return
                }
                // Background autosave; snapshot engine-live first
                // since the debounce may be stale. `persistSessionRecord`
                // re-runs the same loop, but going through it here gets
                // drafts on disk before the OS suspends us.
                for tab in session.tabs where tab.document.isDirty {
                    if let live = tab.state.textView?.text {
                        tab.document.text = live
                    }
                    tab.document.autoSave()
                }
                persistSessionRecord()
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
                applySessionRestoreIfNeeded()
                applyLaunchBehaviorIfFirstScene()
                consumePendingNewWindowURL()
                adoptPendingTabIfAvailable()
                // Drafts banner only on brand-new blank scenes —
                // restored or URL-launched scenes already have intent.
                // Defer past one runloop so `.onOpenURL` has a chance
                // to set its flag before the gate evaluates.
                Task { @MainActor in
                    try? await Task.sleep(for: Timing.paletteHandoff)
                    offerDraftsIfNotFirstScene(wasFirstScene: wasFirstScene)
                }
            }
            // Files app "Open in Ayyyy", share sheet, and the
            // `LSSupportsOpeningDocumentsInPlace` plumbing all
            // funnel through here.
            .onOpenURL { url in
                sceneReceivedOpenURL = true
                route(open: url)
            }
            .onDisappear {
                AppStateBus.shared.scenes.deregisterSession(session)
                // Don't clear `currentSession` here — the weak ref
                // self-nils on dealloc, and onDisappear also fires
                // on focus change, which would strand menu commands.
                AppStateBus.shared.editing.saveCurrentDocument = nil
                // Final session snapshot before any cancel/teardown so
                // a kill mid-disappear still restores correctly.
                persistSessionRecord()
                // Cancel in-flight loads — otherwise closing during
                // a slow File Provider pull keeps the Task pinned on
                // the main actor until URLSession finishes.
                for tab in session.tabs {
                    tab.state.loadTask?.cancel()
                    tab.state.loadTask = nil
                }
                // Salvage unsaved tabs into the closed-tab pool so
                // ⇧⌘T can rescue them post-close. Engine-live text;
                // `document.text` may be debounced-empty.
                for tab in session.tabs {
                    if tab.document.fileURL != nil { continue }
                    let liveText = tab.state.textView?.text ?? tab.document.text
                    guard !liveText.isEmpty else { continue }
                    ClosedTabsStore.shared.record(
                        EditorSession.snapshotRecord(of: tab)
                    )
                }
            }
            // Hands the scene's UIWindowScene to SessionsStore so the
            // `didDisconnectNotification` observer can evict our
            // record when the user closes this window.
            .background(SceneRegistrationBridge(sceneUUID: sceneUUID))
            // Each picker attaches to its own invisible background.
            // Stacking `.fileImporter`s on the SAME view silently
            // coalesces to one (only the first binding presents) —
            // Insert File / Insert Folder never surfaced before this
            // pattern.
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

    @ViewBuilder
    private var editorStack: some View {
        VStack(spacing: 0) {
            // iPad-only Safari-style chrome: toolbar → tab strip →
            // active tab content. iPhone uses its nav-bar items.
            if DeviceIdiom.supportsMultipleWindows && showToolbarPref {
                WindowToolbar(
                    title: documentTitle,
                    subtitle: documentSubtitle,
                    onInteraction: {
                        // The toolbar tap proves this scene is
                        // foreground even if scenePhase hasn't fired
                        // — claim the bus pointers so the upcoming
                        // sheet/picker lands here.
                        AppStateBus.shared.scenes.currentSession = session
                        AppStateBus.shared.scenes.currentEditor = session.activeTab.state
                    }
                )
            }
            if session.tabs.count > 1, !DeviceIdiom.isPhone {
                TabBarView(session: session)
            }
            HStack(spacing: 0) {
                if state.sidebarOpen, !DeviceIdiom.isPhone {
                    OutlineSidebar(state: state)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                activeTabContent
                    // Remount on tab swap so the engine doesn't try
                    // to swap text in place.
                    .id(session.selectedTabID)
            }
        }
    }

    /// File-browser tabs get the inline picker; its pick handler
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

    /// Loads the URL into the active tab's existing document — same
    /// identity, so the tab pill stays stable across the transition.
    private func adoptPickedFileIntoActiveTab(_ url: URL) {
        let tab = session.activeTab
        tab.kind = .editor
        openURL(url)
    }

    /// Keyed by tab id so swapping tabs mid-switcher animates right.
    private var switcherMatchID: String {
        "tab-morph-\(session.selectedTabID)"
    }

    private func dismissSwitcher() {
        withAnimation(.appSwitcherMorph) {
            bus.editing.tabSwitcherActive = false
        }
    }

    /// `nil` → defer to system (Automatic). Otherwise force the
    /// scene's tonality to match the theme.
    private var scenePreferredScheme: ColorScheme? {
        switch AppThemeName(stored: themeNamePref).preferredColorScheme {
        case .light: return .light
        case .dark:  return .dark
        case .none:  return nil
        case .some(_): return nil
        }
    }

    /// Caps the read at 5 MB so a tap on a giant file can't wedge
    /// the buffer.
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

    /// Top level only (one directory deep). Directories get a
    /// trailing slash for visual distinction.
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

    /// `false` only for the cold-launch first scene; every later
    /// scene (state-restored or user-spawned) sees `true`.
    private var isColdLaunchFirstScene: Bool {
        !AppStateBus.shared.scenes.hasAppliedLaunchBehavior
    }

    private func applyLaunchBehaviorIfFirstScene() {
        guard !AppStateBus.shared.scenes.hasAppliedLaunchBehavior else { return }
        AppStateBus.shared.scenes.hasAppliedLaunchBehavior = true
        // The cold-launch first scene is a fresh blank surface — by
        // spec, no drafts prompt. Subsequent scenes get it via
        // `offerDraftsIfNotFirstScene`.
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.launchBehavior) ?? LaunchBehavior.newBlank.rawValue
        guard LaunchBehavior(rawValue: raw) == .openPicker,
              document.fileURL == nil,
              document.text.isEmpty else { return }
        // Defer one tick so the scene's on screen before the sheet.
        DispatchQueue.main.async {
            AppStateBus.shared.pickers.pending = .open
        }
    }

    /// `didOfferDraftsForThisScene` stops re-prompting after a
    /// foreground re-enter dismisses the sheet. URL-launched scenes
    /// and scenes built from a restored `SessionRecord` skip the
    /// banner — both already have clear intent.
    private func offerDraftsIfNotFirstScene(wasFirstScene: Bool) {
        guard !wasFirstScene,
              !didOfferDraftsForThisScene,
              !sceneReceivedOpenURL,
              !didApplySessionRecord,
              !DraftsStore.shared.loadAll().isEmpty
        else { return }
        didOfferDraftsForThisScene = true
        DispatchQueue.main.async {
            AppStateBus.shared.scenes.currentSession = session
            AppStateBus.shared.scenes.currentEditor = session.activeTab.state
            AppStateBus.shared.editing.presentedSheet = .draftsRecovery
        }
    }

    /// One-shot per scene. The first scene to call this seeds the
    /// `SessionsStore` pending-restore queue from the previous
    /// launch's records and spawns extra `WindowGroup` scenes for
    /// any beyond this one — SwiftUI only restores one scene on its
    /// own. Every scene then pops the next pending record (if any)
    /// and applies it.
    private func applySessionRestoreIfNeeded() {
        guard !didApplySessionRecord else { return }
        didApplySessionRecord = true
        if sceneUUID.isEmpty {
            sceneUUID = UUID().uuidString
        }
        // First caller seeds the queue. Returns the count of records
        // pending — we need to open `count - 1` extra windows
        // (the current scene covers the first).
        let pendingCount = SessionsStore.shared.initiateRestoreSweep()
        if pendingCount > 1 {
            for _ in 0..<(pendingCount - 1) {
                openWindow(id: SceneID.editor.rawValue)
            }
        }
        if let record = SessionsStore.shared.consumePendingRestore() {
            SessionRestore.apply(record, to: session)
        }
    }

    /// Snapshots current tabs (file bookmarks + draft refs + active
    /// index) under the scene's UUID. Re-saves on every background
    /// transition so a force-quit picks up the latest state.
    private func persistSessionRecord() {
        guard !sceneUUID.isEmpty else { return }
        // Pull engine-live text into drafts so the snapshot's
        // `draftFilename` references current bytes, not a 300 ms-old
        // debounce.
        for tab in session.tabs where tab.document.isDirty {
            if let live = tab.state.textView?.text {
                tab.document.text = live
            }
            tab.document.autoSave()
        }
        let record = SessionRecord(scene: sceneUUID, session: session)
        SessionsStore.shared.save(record)
    }

    /// "Move Tab to New Window" hands the tab off through
    /// `pending.adoptedTab`; the new scene swaps it in for its
    /// blank placeholder, preserving document + state + dirty flag.
    private func adoptPendingTabIfAvailable() {
        guard let adopted = AppStateBus.shared.pending.adoptedTab,
              session.tabs.count == 1,
              session.activeTab.document.fileURL == nil,
              session.activeTab.document.text.isEmpty
        else { return }
        AppStateBus.shared.pending.adoptedTab = nil
        // Insert-then-remove (not the reverse) so the session never
        // briefly hosts two tabs — that would trigger the strip
        // animation. This way is invisible.
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

    /// Home-screen quick action handler — surfaced by
    /// `AppDelegateBridge`.
    private func applyHomeShortcut(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .newFile:
            openWindow(id: SceneID.editor.rawValue)
        case .commandPalette:
            CommandActions.presentCommandPalette()
        }
    }

    /// Hops through `Task { @MainActor in … }` so the dismissing
    /// picker has a runloop tick before the new scene takes over.
    private func route(open url: URL) {
        let destination = DocumentDestination.current()
        // Committed — clear the override so the next unrelated Open
        // doesn't inherit it.
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
        state.loadTask?.cancel()

        // Weak captures so a close mid-download lets the Task bail
        // in its `defer` instead of pinning the document until
        // URLSession returns.
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
            // Seed the diff baseline with as-loaded text — without
            // this, a freshly-opened file shows every line "added"
            // green (baseline "" → current = loaded text).
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
            // Multi-File Search posts a target line; the text view
            // may not be mounted on the first tick after `state.text`
            // is set, so dispatch the jump.
            if let line = AppStateBus.shared.pending.goToLine {
                AppStateBus.shared.pending.goToLine = nil
                DispatchQueue.main.async { [weak state] in
                    state?.textView?.goToLine(line)
                }
            }
        }
    }
}
