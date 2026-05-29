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
        document.displayName
    }

    /// "edited" hint + location breadcrumb, middle-dot joined when
    /// both apply. A brand-new Untitled doc with no edits is NOT
    /// "edited" — the indicator only appears once the buffer is
    /// actually dirty (`isDirty == true`).
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

    var body: some View {
        // NavigationStack gives the window a real title-bar region;
        // without it iPadOS squeezes a resize grabber into the middle
        // of our content instead of the standard top-left chrome.
        NavigationStack {
            ZStack {
                editorStack
                    // Cross-fade against the switcher. The earlier
                    // matchedGeometryEffect that drove an editor →
                    // card "zoom" morph cached the source frame and
                    // wouldn't grow back when the window resized
                    // (Stage Manager / Slide Over), leaving the
                    // editor stuck at a smaller-than-window size.
                    // Plain opacity is layout-safe and good enough.
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
                        guard let session else { return }
                        // saveDocumentSafely handles Untitled → Save As,
                        // stale-source warnings, and the actual write.
                        CommandActions.saveDocumentSafely(session.activeTab, session: session)
                    }
                    return
                }
                // Background autosave; snapshot engine-live first
                // since the debounce may be stale. `persistSessionRecord`
                // re-runs the same loop, but going through it here gets
                // drafts on disk before the OS suspends us.
                // commitDraft: app is going to the background and
                // could be killed by the OS, so push every dirty
                // buffer to the synced folder for cross-device /
                // post-launch recovery.
                for tab in session.tabs where tab.document.isDirty {
                    if let live = tab.state.textView?.text {
                        tab.document.text = live
                    }
                    tab.document.autoSave(commitDraft: true)
                }
                persistSessionRecord()
            }
            .onAppear {
                AppStateBus.shared.scenes.currentSession = session
                AppStateBus.shared.scenes.registerSession(session)
                AppStateBus.shared.scenes.routeOpenURL = { url in route(open: url) }
                AppStateBus.shared.editing.saveCurrentDocument = { [weak session] in
                    guard let session else { return }
                    CommandActions.saveDocumentSafely(session.activeTab, session: session)
                }
                applySessionRestoreIfNeeded()
                markColdLaunchHandled()
                consumePendingNewWindowURL()
                adoptPendingTabIfAvailable()
                // Shortcut delivered via `configurationForConnecting`
                // (cold launch or new-scene activation) lands in
                // `pendingShortcut` BEFORE this scene's `.onChange`
                // subscribes — so the change is missed. Catch it
                // here too.
                if let pending = bus.scenes.pendingShortcut {
                    bus.scenes.pendingShortcut = nil
                    applyHomeShortcut(pending)
                }
                // Drafts banner gone: the launcher tab now lists
                // unsaved drafts inline, so the old non-first-scene
                // banner would be a duplicate. The drafts sheet
                // stays reachable from Edit ▸ Recover Drafts….
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
                    defaultFilename: state.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName
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

    /// Every tab kind funnels through `EditorView` so the window
    /// keeps its toolbar, status bar, and keyboard accessory regardless
    /// of what's filling the editor's text-area region. `.launcher`
    /// and `.fileBrowser` inject their UI via `tabContentOverride`;
    /// `.editor` lets EditorView render its text view normally.
    @ViewBuilder
    private var activeTabContent: some View {
        switch session.activeTab.kind {
        case .editor:
            EditorView(document: document, state: state)
        case .fileBrowser:
            EditorView(
                document: document,
                state: state,
                tabContentOverride: AnyView(
                    FileBrowserTabContent(
                        onPick: { url in
                            adoptPickedFileIntoActiveTab(url)
                        },
                        onCancel: {
                            // Back out to the launcher in the same
                            // tab. The user landed on the file
                            // browser via the launcher's "Open File…"
                            // row, so this restores the surface they
                            // came from.
                            session.activeTab.kind = .launcher
                        }
                    )
                )
            )
        case .launcher:
            EditorView(
                document: document,
                state: state,
                tabContentOverride: AnyView(launcherOverride)
            )
        }
    }

    @ViewBuilder
    private var launcherOverride: some View {
        NewDocumentLauncherView(
            onPickTemplate: { template in
                adoptTemplateIntoActiveTab(template)
            },
            onPickDraft: { draft in
                adoptDraftIntoActiveTab(draft)
            },
            onPickOpenFile: {
                session.activeTab.kind = .fileBrowser
            },
            onPickClipboard: { text in
                adoptClipboardIntoActiveTab(text)
            },
            // Single-tab session means this launcher IS the window;
            // sibling tabs mean it's just another tab.
            isWindowScopeLauncher: session.tabs.count == 1,
            onCancel: {
                // Cancel = "I'm done with this surface". If the
                // launcher is one of several tabs, close just that
                // tab. If it's the only tab in the window, the user
                // is asking to dismiss the window itself — on iPad
                // that destroys the scene; on iPhone (single-window)
                // it falls through to a close-and-respawn since
                // there's nowhere meaningful to go.
                if session.tabs.count == 1 {
                    if DeviceIdiom.supportsMultipleWindows {
                        CommandActions.closeWindow()
                    } else {
                        CommandActions.requestCloseTab(session.activeTab.id, in: session)
                    }
                } else {
                    CommandActions.requestCloseTab(session.activeTab.id, in: session)
                }
            },
            // Hide Cancel only when it would have nowhere useful to
            // go: a single-tab launcher on iPhone, where closing
            // the window isn't an option.
            showsCancel: session.tabs.count > 1 || DeviceIdiom.supportsMultipleWindows
        )
    }

    /// Loads the URL into the active tab's existing document — same
    /// identity, so the tab pill stays stable across the transition.
    private func adoptPickedFileIntoActiveTab(_ url: URL) {
        let tab = session.activeTab
        tab.kind = .editor
        openURL(url)
    }

    /// Seeds the active launcher tab with the pasteboard's text as
    /// a fresh Untitled buffer. The buffer is marked dirty so the
    /// autosave loop picks it up immediately — closing the window
    /// without saving leaves it recoverable from the launcher's
    /// Drafts list.
    private func adoptClipboardIntoActiveTab(_ text: String) {
        let tab = session.activeTab
        tab.document.text = text
        tab.document.fileURL = nil
        tab.document.isDirty = !text.isEmpty
        tab.state.text = text
        tab.state.fileURL = nil
        tab.state.savedBaselineText = ""
        tab.kind = .editor
    }

    /// Seeds the active launcher tab with a template's bytes as a
    /// new Untitled buffer. The template file itself is never opened
    /// — `fileURL` stays nil so ⌘S prompts for a save location, and
    /// the next keystroke kicks the draft autosave loop.
    private func adoptTemplateIntoActiveTab(_ template: TemplateRecord) {
        let tab = session.activeTab
        let body = TemplatesStore.shared.loadContent(template) ?? ""
        tab.document.text = body
        tab.document.fileURL = nil
        tab.document.isDirty = !body.isEmpty
        tab.state.text = body
        tab.state.fileURL = nil
        tab.state.savedBaselineText = ""
        tab.state.languageIdentifier = LanguageRegistry.identifier(for: template.url)
        tab.kind = .editor
    }

    /// Adopts an existing draft into the active launcher tab. URL-
    /// backed drafts re-bind to their source so ⌘S writes back; the
    /// drafted text on top stays dirty until explicit save.
    ///
    /// For URL-backed drafts this also runs the stale-source
    /// safeguard: if the original file is gone we drop the URL link
    /// and surface a "Source missing" notice; if the file's been
    /// modified since the draft was captured we surface a "Continue
    /// editing / Reload" choice. The tab transitions to `.editor`
    /// either way — the user keeps the drafted bytes while
    /// resolving.
    private func adoptDraftIntoActiveTab(_ draft: DraftRecord) {
        let tab = session.activeTab
        let text = (try? String(contentsOf: draft.url, encoding: .utf8))
            ?? (try? String(contentsOf: draft.url, encoding: .isoLatin1))
            ?? ""
        tab.document.text = text
        tab.document.isDirty = true
        tab.state.text = text
        // Check the draft out of the synced folder. While the tab
        // is open the buffer lives only in local scratch; on close
        // the draft is re-written so the launcher (and other
        // devices) can pick it up again. This is what stops the
        // same draft from being opened simultaneously on iPhone
        // and iPad — once it's gone from the synced folder, the
        // other device's launcher won't see it.
        DraftsStore.shared.discard(draft.url)
        tab.document.draftURL = nil

        if let bookmark = draft.metadata?.sourceBookmark,
           let resolved = Self.resolveBookmark(bookmark) {
            let attrs = PlainTextDocument.diskAttrs(of: resolved.url)
            if attrs == nil {
                // File can no longer be reached. Adopt the bytes as
                // an Untitled buffer and surface a notice — the
                // dialog's OK button (`acknowledgeSourceMissing`)
                // clears the URL link.
                tab.document.fileURL = resolved.url
                tab.state.fileURL = resolved.url
                tab.state.languageIdentifier = LanguageRegistry.identifier(for: resolved.url)
                tab.state.savedBaselineText = ""
                tab.kind = .editor
                bus.editing.sourceStaleCheck = .missing(
                    tabID: tab.id,
                    displayName: resolved.url.lastPathComponent
                )
                return
            }
            tab.document.fileURL = resolved.url
            tab.state.fileURL = resolved.url
            tab.state.languageIdentifier = LanguageRegistry.identifier(for: resolved.url)
            if let rawEncoding = draft.metadata?.sourceEncodingRaw {
                let encoding = String.Encoding(rawValue: rawEncoding)
                tab.document.fileEncoding = FileEncoding(encoding: encoding)
                tab.state.fileEncoding = tab.document.fileEncoding
            }
            tab.document.sourceMtimeAtLoad = attrs?.mtime
            tab.document.sourceSizeAtLoad = attrs?.size
            let onDisk = (try? String(contentsOf: resolved.url, encoding: .utf8))
                ?? (try? String(contentsOf: resolved.url, encoding: .isoLatin1))
                ?? ""
            tab.state.savedBaselineText = onDisk
            tab.kind = .editor
            // Did anything change between draft creation and now?
            // Compare the draft's recorded attrs to current disk.
            // If we don't have recorded attrs (older draft), skip —
            // can't reason about drift without a baseline.
            if let recordedMtime = draft.metadata?.sourceMtime,
               let recordedSize = draft.metadata?.sourceSize,
               let liveAttrs = attrs,
               liveAttrs.mtime != recordedMtime || liveAttrs.size != recordedSize {
                bus.editing.sourceStaleCheck = .changedOnAdopt(
                    tabID: tab.id,
                    displayName: resolved.url.lastPathComponent
                )
            }
            return
        }
        tab.state.savedBaselineText = ""
        tab.kind = .editor
    }

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

    /// Stable across tab switches. Earlier this keyed off the
    /// active tab's id, but that made every Cmd-T / + tap fire a
    /// matched-geometry-effect interpolation between the old and
    /// new tab's frames — visually it looked like the new tab was
    /// zooming in from the previous one. The switcher morph still
    /// works because the active card in `TabSwitcherView` reads
    /// this same constant string for the currently-selected tab.
    private var switcherMatchID: String { "tab-morph-active" }

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

    /// Latches the one-shot "first scene" bit so later scenes know
    /// the cold-launch pass already ran. Kept after the launcher
    /// rewrite because state-restore + URL-routing both still read
    /// it via `AppStateBus.shared.scenes.hasAppliedLaunchBehavior`.
    private func markColdLaunchHandled() {
        AppStateBus.shared.scenes.hasAppliedLaunchBehavior = true
        // Sweep orphaned scene sessions (the "N hidden windows"
        // iPadOS retains after a Stage Manager / App Switcher
        // close). Drafts from those windows are already on disk
        // and reachable from the launcher's Drafts section, so the
        // shadow sessions are pure clutter.
        SessionsStore.shared.purgeHiddenSessions()
    }

    /// One-shot per scene. The first scene to call this seeds the
    /// `SessionsStore` pending-restore queue from the previous
    /// launch's records and spawns extra `WindowGroup` scenes for
    /// any beyond this one — SwiftUI only restores one scene on its
    /// own. Every scene then pops the next pending record (if any)
    /// and applies it. Fresh scenes (no record popped) ask the
    /// system for a prominent placement so a brand-new window
    /// doesn't slam flat on top of its siblings.
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
        // debounce. commitDraft: this runs when the scene is being
        // torn down (window close), so we want the synced folder
        // updated for cross-device / next-launch recovery.
        for tab in session.tabs where tab.document.isDirty {
            if let live = tab.state.textView?.text {
                tab.document.text = live
            }
            tab.document.autoSave(commitDraft: true)
        }
        // A window has nothing worth restoring when every tab is
        // empty (no fileURL, no draftURL). Persisting these would
        // pollute the next launch with phantom "Untitled" windows
        // the user never meant to keep. Drafts handle the data-
        // safety side — anything dirty would have written a draft
        // in the loop above and now has a non-nil draftURL.
        let hasRestorableTab = session.tabs.contains { tab in
            tab.document.fileURL != nil || tab.document.draftURL != nil
        }
        guard hasRestorableTab else {
            SessionsStore.shared.remove(forScene: sceneUUID)
            return
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
                session.newTab(kind: .editor)
                openURL(url)
            }
        }
    }

    private func openURL(_ url: URL) {
        // Any "load a URL into this tab" path lands here; flipping
        // kind up front means file-open from the launcher (or from a
        // pending newWindow handoff) transitions the surface to the
        // editor synchronously, before the load finishes.
        if session.activeTab.kind != .editor {
            session.activeTab.kind = .editor
        }
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
