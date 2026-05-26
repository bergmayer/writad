import SwiftUI
import UIKit
import FileEncoding
import LineEnding
import LineSort

/// iPadOS menu bar wiring.
///
/// Layout follows Mac/iPad conventions for a plain-text editor:
///
///   * **App** — Preferences, Command Palette
///   * **Edit** (system-augmented) — system Cut/Copy/Paste/Undo/Redo plus
///     Selection submenu and character-level edits (Transpose, delete-word,
///     delete-to-EOL)
///   * **Find** — find/replace, find next/prev, go-to, navigation history,
///     bookmarks
///   * **Format** — document-format submenus (encoding, line endings,
///     syntax, indent) plus indent / outdent / toggle-comment for the
///     selection
///   * **View** — font sizing and display toggles (added to the system View
///     menu, not a duplicate)
///   * **Text** — line operations and content transforms
///
/// All button actions route through `CommandActions` so the command palette
/// can share them.
struct EditorCommands: Commands {

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.openWindow) private var openWindow
    /// Drives the Snippets menu — reading the store as @State means
    /// the menu rebuilds when snippets are added/removed/edited from
    /// the Preferences pane.
    @State private var snippetsStore = SnippetsStore.shared
    /// Drives the JavaScript Transforms submenu. Same observation
    /// reason as `snippetsStore` — reading `.shared` inline from a
    /// menu ViewBuilder doesn't subscribe to changes, so the menu
    /// would render the cached slot list until something unrelated
    /// invalidated it.
    @State private var jsTransformStore = JSTransformStore.shared
    /// Drives the Open Recent submenu — observation lets new entries
    /// (and Clear Menu) reflect immediately without waiting for the
    /// next unrelated menu rebuild.
    @State private var recentFilesStore = RecentFilesStore.shared
    /// Pulled in via SwiftUI's @FocusedValue so menu actions that
    /// trigger sheets fire against the actually-focused window, not
    /// whichever scene happens to be in `AppStateBus.scenes.currentEditor`.
    @FocusedValue(\.presentEditorSheet) private var focusedPresenter: SheetPresenter?
    /// The foreground scene's `EditorSession`. Menu commands that
    /// act on tabs should use this instead of
    /// `AppStateBus.scenes.currentSession` — it never lags.
    @FocusedValue(\.focusedSession) private var focusedSession: EditorSession?

    private var editorState: EditorState? { bus.scenes.currentEditor }
    private var isEnabled: Bool { editorState != nil }

    /// Sync `AppStateBus.scenes.currentSession` / `currentEditor`
    /// to the focused scene. Called before any CommandAction that
    /// reads the bus so the action targets the foreground window.
    /// Cheap no-op when the bus already matches.
    private func claimFocus() {
        guard let session = focusedSession else { return }
        if AppStateBus.shared.scenes.currentSession !== session {
            AppStateBus.shared.scenes.currentSession = session
        }
        let activeState = session.activeTab.state
        if AppStateBus.shared.scenes.currentEditor !== activeState {
            AppStateBus.shared.scenes.currentEditor = activeState
        }
    }

    /// Route a sheet trigger through the focused scene's presenter
    /// if available; fall back to the bus directly when nothing has
    /// claimed focus yet (cold-launch race only). Always claims focus
    /// first so that any sheet content reading `bus.scenes.currentEditor`
    /// / `currentSession` sees the foreground window — fixes the
    /// "Clipboard History opens on the wrong window" class of bug for
    /// every menu sheet at once.
    private func presentSheet(_ sheet: EditorSheet) {
        claimFocus()
        if let focusedPresenter {
            focusedPresenter(sheet)
        } else {
            bus.editing.presentedSheet = sheet
        }
    }

    /// Run a CommandAction after claiming focus on the bus —
    /// EVERY menu Button in this file should route its action
    /// through here. Without it, the action reads
    /// `bus.scenes.currentEditor` / `currentSession`, which can lag
    /// behind real scene focus during iPad Stage Manager
    /// transitions, Split View, and multi-window flips. The bug
    /// surfaces as Markdown / Text / View commands targeting a
    /// background window instead of the one the user is looking at.
    ///
    /// Use as a Button's action: `Button("X", action: focused(CommandActions.x))`,
    /// or for closures with arguments / inline logic:
    /// `Button("X") { focused { CommandActions.x(arg) } }`.
    private func focused(_ action: @escaping @MainActor () -> Void) -> () -> Void {
        {
            claimFocus()
            action()
        }
    }

    /// Closure variant — runs `action` after claimFocus. Useful when
    /// the Button body has inline logic that can't be passed as a
    /// bare function reference.
    private func focused(_ action: () -> Void) {
        claimFocus()
        action()
    }

    var body: some Commands {

        // (Previously replaced .windowArrangement / .windowSize with
        // empty to suppress stale items — but we now add Tab items
        // via `CommandGroup(after: .windowArrangement)` further down,
        // and need the Window menu intact for them to attach to.)

        // Suppress the system text-formatting CommandGroup (Bold /
        // Italic / Underline) — those defaults claim ⌘B and ⌘I,
        // which collides with our Markdown menu's wrappers and
        // causes iPadOS to silently drop the Markdown menu via
        // `_UIMenuBuilderError`. The Markdown menu owns those
        // shortcuts in this app.
        CommandGroup(replacing: .textFormatting) { }

        // MARK: App — Preferences, Command Palette, and Tool Palette
        // live under the application (Ayyyy) menu

        // Two App-menu contributions wrapped together so they count
        // as a single CommandsBuilder slot (the body's at the 10-
        // child cap):
        //   1. Replace iOS 26's auto-injected "Settings…" so there's
        //      a single Preferences entry in the Ayyyy menu. The
        //      system item would otherwise sit next to our manual
        //      button and route to Settings.app (no Settings.bundle
        //      defined here, so it lands on a blank page).
        //   2. Add Command Palette… below the Preferences item.
        Group {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: SceneID.preferences.rawValue) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Command Palette…") { presentSheet(.commandPalette) }
                    .keyboardShortcut(";", modifiers: .command)
            }
        }

        // MARK: File — New (new scene) / Open / Save / Save As

        CommandGroup(replacing: .newItem) {
            // ⌘N → always a brand-new window. ⌘T → new tab in the
            // current window (these always override the "Open / New
            // documents in…" preference, per the user spec). iPhone
            // can't host multiple windows, so the item is hidden there.
            if DeviceIdiom.supportsMultipleWindows {
                Button("New Window") { openWindow(id: SceneID.editor.rawValue) }
                    .keyboardShortcut("n")
            }
            // No `.disabled(...)` here: SwiftUI evaluates the disable
            // expression at menu-build time, so a brief currentSession
            // = nil (between scene swaps) was leaving the item greyed
            // out indefinitely. Fall back to opening a new window when
            // no session is set instead.
            Button("New Tab") {
                // Prefer the focused-scene session (always
                // foreground) over the bus's currentSession (can
                // lag on iPad Stage Manager). Fall back to a fresh
                // window when no scene has focus yet.
                if let session = focusedSession ?? AppStateBus.shared.scenes.currentSession {
                    session.newTab()
                    CommandActions.offerDraftsIfAvailable()
                } else {
                    openWindow(id: SceneID.editor.rawValue)
                }
            }
            .keyboardShortcut("t")
            // Single "Open…" — always routes to a new window per
            // user spec. No `.keyboardShortcut("o")`:
            // `LSSupportsOpeningDocumentsInPlace = YES` makes
            // iPadOS auto-inject its own ⌘O Open command (which
            // also lands in our `.onOpenURL` and goes to a new
            // window via the destination preference). Binding our
            // button to ⌘O would duplicate the system's shortcut
            // and `_UIMenuBuilderError` would drop the entire
            // `.newItem` replacement. iPhone is single-window so
            // "new window" collapses to "new tab" behavioural-wise.
            Button(DeviceIdiom.supportsMultipleWindows ? "Open…" : "Open in New Tab…") {
                claimFocus()
                if DeviceIdiom.supportsMultipleWindows {
                    CommandActions.presentFileBrowserInNewWindow()
                } else {
                    CommandActions.presentFileBrowserInNewTab()
                }
            }
            // No `Menu("Open Recent")` here: iPadOS auto-injects
            // its own Open Recent submenu when
            // `LSSupportsOpeningDocumentsInPlace = YES` is set
            // (system-wide handler registration). Our previous
            // explicit Menu was rendering alongside, producing two
            // identical-titled "Open Recent" entries.
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { AppStateBus.shared.editing.saveCurrentDocument?() }
                .keyboardShortcut("s")
                .disabled(!isEnabled)
            Button("Save As…") { AppStateBus.shared.pickers.pending = .saveAs }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!isEnabled)
            Divider()
            Button("Revert to Saved") {
                AppStateBus.shared.editing.revertRequestCount += 1
            }
            .disabled(!isEnabled)
            Button("Show Revisions…") {
                presentSheet(.revisions)
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .disabled(!isEnabled)
            // Surfaces every unsaved draft from previous sessions
            // (untitled OR URL-backed). Drafts persist until the
            // user explicitly Discards or Saves; this entry is the
            // app-lifetime way to reach the recovery sheet, in
            // addition to the launch-time auto-popup.
            Button("Recover Unsaved Drafts…") {
                presentSheet(.draftsRecovery)
            }
            Divider()
            Button("Speak Selection", action: focused(CommandActions.speakSelection))
                .disabled(!isEnabled)
        }

        // MARK: Edit — selection submenu + character-level edits

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Clipboard History…") { presentSheet(.clipboardHistory) }
                .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Menu("Selection") {
                Button("Select Word", action: focused(CommandActions.selectCurrentWord))
                Button("Select Line", action: focused(CommandActions.selectCurrentLine))
                Button("Select Lines Containing…") { presentSheet(.selectLinesContaining) }
                Divider()
                Button("Smart Move to Line Start", action: focused(CommandActions.smartMoveToLineStart))
            }
            .disabled(!isEnabled)

            Divider()

            Button("Transpose Characters", action: focused(CommandActions.transposeCharacters))
                .keyboardShortcut("t", modifiers: .control)
                .disabled(!isEnabled)
            Button("Delete to End of Line", action: focused(CommandActions.deleteToEndOfLine))
                .keyboardShortcut("k", modifiers: .control)
                .disabled(!isEnabled)
            Button("Delete Word Backward", action: focused(CommandActions.deleteWordBackward))
                .keyboardShortcut(.delete, modifiers: .option)
                .disabled(!isEnabled)
            Button("Delete Word Forward", action: focused(CommandActions.deleteWordForward))
                .keyboardShortcut(.deleteForward, modifiers: .option)
                .disabled(!isEnabled)
            Button("Join Lines", action: focused(CommandActions.joinLines))
                .keyboardShortcut("j", modifiers: .control)
                .disabled(!isEnabled)
        }

        // (Tabs menu moved to bottom of the body — Safari-style
        // menu-bar order is View, Text, Markdown, Tabs.)

        // MARK: Search — top-level menu, restored per user request.
        // Items live in `findSubmenuContent` so the implementation
        // can move between an Edit submenu and the menu bar without
        // duplicating bodies.

        CommandMenu("Search") {
            findSubmenuContent
        }

        // (Markdown menu moved to AFTER View+Text — see below the
        // `} // end Group { View + Text }` marker. Menu-bar order
        // is: Ayyyy / File / Edit / View / Search / Text / Markdown
        // / Tabs / Window / Help.)

        // (Format menu folded into View ▸ Format — see
        // `formatSubmenuContent` below the body.)

        // MARK: View — populate iPadOS's auto-injected View menu.
        //
        // History on this slot is fraught:
        //   * `CommandGroup(replacing: .toolbar)` ended up burying
        //     our items inside a "Toolbar" submenu of View.
        //   * `CommandMenu("View")` collided with the system-
        //     injected View menu title and UIMenuBuilder silently
        //     dropped ours.
        //
        // `CommandGroup(after: .sidebar)` appends to the existing
        // View menu right after the Show Sidebar toggle — items
        // land at the View menu's top level, where the user looks
        // for Bigger Font, Show Outline, Show File Information,
        // etc. This is the documented placement for "add custom
        // items to View on iPad."
        //
        // ALSO replace the system-injected Show Sidebar with our
        // own toggle — iPadOS's default sidebar item drives the
        // platform's sidebar API, but our sidebar lives on
        // `state.sidebarOpen` (custom inline panel from
        // OutlineSidebar.swift), so the system toggle did nothing.
        CommandGroup(replacing: .sidebar) {
            // Replace the system-injected "Show Sidebar" with our
            // "Show Outline" toggle — same panel, single name. Older
            // builds had both items, which surfaced the same UI.
            Button("Show Outline", action: focused(CommandActions.showOutline))
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!isEnabled)
        }
        CommandGroup(after: .sidebar) {
            viewMenuFontItems
            Divider()
            viewMenuToggleItems
            Divider()
            viewMenuFoldItems
            Divider()
            viewMenuTailItems
        }

        // MARK: Text — line operations + content transforms

        CommandMenu("Text") {
            Group {
                // Surround Selection — common wraps as direct menu
                // items so the user picks the bracket / quote
                // family in one tap. A dialog felt heavy for what
                // amounts to "wrap selection in one of nine fixed
                // patterns" — every preset is one click.
                Menu("Surround Selection") {
                    // Bold / Italic at the top — most common wraps
                    // for prose editing.
                    Button("Bold **…**")       { focused { CommandActions.surroundSelection(prefix: "**", suffix: "**") } }
                    Button("Italic _…_")       { focused { CommandActions.surroundSelection(prefix: "_",  suffix: "_") } }
                    Divider()
                    Button("Parentheses ( )") { focused { CommandActions.surroundSelection(prefix: "(",  suffix: ")") } }
                    Button("Brackets [ ]")    { focused { CommandActions.surroundSelection(prefix: "[",  suffix: "]") } }
                    Button("Braces { }")      { focused { CommandActions.surroundSelection(prefix: "{",  suffix: "}") } }
                    Button("Angles < >")      { focused { CommandActions.surroundSelection(prefix: "<",  suffix: ">") } }
                    Divider()
                    Button("Double Quotes \"\"") { focused { CommandActions.surroundSelection(prefix: "\"", suffix: "\"") } }
                    Button("Single Quotes ''")   { focused { CommandActions.surroundSelection(prefix: "'",  suffix: "'") } }
                    Button("Backticks ``")       { focused { CommandActions.surroundSelection(prefix: "`",  suffix: "`") } }
                }

                Divider()

                // Everything line-oriented under one roof — single-
                // line ops (move/dup/delete) live at the top of the
                // submenu since they're the most-used; transforms
                // (sort/reverse/etc.) follow.
                Menu("Lines") {
                    Button("Move Line Up", action: focused(CommandActions.moveLineUp))
                        .keyboardShortcut(.upArrow, modifiers: .option)
                    Button("Move Line Down", action: focused(CommandActions.moveLineDown))
                        .keyboardShortcut(.downArrow, modifiers: .option)
                    Button("Duplicate Line", action: focused(CommandActions.duplicateLine))
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    Button("Delete Line", action: focused(CommandActions.deleteLine))
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                    Divider()
                    Button("Sort Lines…", action: focused(CommandActions.sortLines))
                    Button("Reverse Lines", action: focused(CommandActions.reverseLines))
                    Button("Unique Lines", action: focused(CommandActions.uniqueLines))
                    Button("Remove Blank Lines", action: focused(CommandActions.removeBlankLines))
                    Divider()
                    Button("Add Linebreaks", action: focused(CommandActions.addLinebreaks))
                    Button("Remove Linebreaks", action: focused(CommandActions.removeLinebreaks))
                    Divider()
                    Button("Add Line Numbers", action: focused(CommandActions.addLineNumbers))
                    Button("Remove Line Numbers", action: focused(CommandActions.removeLineNumbers))
                    Button("Prefix / Suffix Lines…", action: focused(CommandActions.presentPrefixSuffixLines))
                    Divider()
                    Button("Process Lines Containing…", action: focused(CommandActions.presentProcessLines))
                }

                // Selection transforms — case changes followed by
                // encoding transforms, with Reverse Selection at the
                // tail since it's the rare action of the bunch.
                Menu("Transform") {
                    Button("UPPERCASE", action: focused(CommandActions.uppercase))
                    Button("lowercase", action: focused(CommandActions.lowercase))
                    Button("Capitalized", action: focused(CommandActions.capitalize))
                    Button("Title Case", action: focused(CommandActions.titleCase))
                    Divider()
                    Button("snake_case", action: focused(CommandActions.snakeCase))
                    Button("kebab-case", action: focused(CommandActions.kebabCase))
                    Button("camelCase", action: focused(CommandActions.camelCase))
                    Button("PascalCase", action: focused(CommandActions.pascalCase))
                    Divider()
                    Menu("Normalize Unicode") {
                        Button("NFC — Canonical Composed", action: focused(CommandActions.normalizeNFC))
                        Button("NFD — Canonical Decomposed", action: focused(CommandActions.normalizeNFD))
                        Button("NFKC — Compatibility Composed", action: focused(CommandActions.normalizeNFKC))
                        Button("NFKD — Compatibility Decomposed", action: focused(CommandActions.normalizeNFKD))
                    }
                    Menu("Encode / Decode") {
                        Button("URL Encode", action: focused(CommandActions.urlEncode))
                        Button("URL Decode", action: focused(CommandActions.urlDecode))
                        Divider()
                        Button("Base64 Encode", action: focused(CommandActions.base64Encode))
                        Button("Base64 Decode", action: focused(CommandActions.base64Decode))
                    }
                    Divider()
                    Button("Reverse Selection", action: focused(CommandActions.reverseSelection))
                }

                // Character-level cleanups — whitespace, quotes,
                // gremlins. Trim Trailing Whitespace lives here now
                // (was duplicated under Lines); whitespace fixes
                // belong with the rest of the cleanup family.
                Menu("Cleanup") {
                    Menu("Whitespace") {
                        Button("Trim Trailing Whitespace", action: focused(CommandActions.trimTrailingWhitespace))
                        Divider()
                        Button("Normalize Spaces", action: focused(CommandActions.normalizeSpaces))
                        Button("Convert Tabs to Spaces", action: focused(CommandActions.tabsToSpaces))
                        Button("Convert Spaces to Tabs", action: focused(CommandActions.spacesToTabs))
                        Button("Normalize Line Endings", action: focused(CommandActions.normalizeLineEndingsToDocument))
                    }
                    Menu("Quotes & Escapes") {
                        Button("Educate Quotes", action: focused(CommandActions.educateQuotes))
                        Button("Straighten Quotes", action: focused(CommandActions.straightenQuotes))
                        Divider()
                        Button("Interpret Escape Sequences", action: focused(CommandActions.interpretEscapeSequences))
                        Button("Escape Special Characters", action: focused(CommandActions.escapeSpecialCharacters))
                    }
                    Divider()
                    Button("Zap Gremlins…", action: focused(CommandActions.presentZapGremlins))
                    Button("Strip Diacritics", action: focused(CommandActions.stripDiacritics))
                    Button("Convert to ASCII", action: focused(CommandActions.convertToASCII))
                    Divider()
                    Button("Canonize…", action: focused(CommandActions.presentCanonize))
                }

                Divider()

                Menu("Insert") {
                    Button("Date & Time", action: focused(CommandActions.insertDateTime))
                    Button("Date", action: focused(CommandActions.insertDate))
                    Button("Time", action: focused(CommandActions.insertTime))
                    Divider()
                    Button("Tab", action: focused(CommandActions.insertTab))
                    Button("Newline", action: focused(CommandActions.insertNewline))
                    Divider()
                    Button("File Contents…", action: focused(CommandActions.presentInsertFileContents))
                    Button("Folder Listing…", action: focused(CommandActions.presentInsertFolderListing))
                    Button("Lorem Ipsum…", action: focused(CommandActions.presentInsertLoremIpsum))
                }

                Menu("Snippets") {
                    Button("Insert Snippet…", action: focused(CommandActions.presentSnippetPicker))
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    if !snippetsStore.snippets.isEmpty {
                        Divider()
                        ForEach(snippetsStore.snippets) { snippet in
                            Button(snippet.name.isEmpty ? "(unnamed)" : snippet.name) {
                                focused { CommandActions.insertSnippet(snippet) }
                            }
                        }
                    }
                    Divider()
                    Button("Manage Snippets…", action: focused(CommandActions.presentSnippetsManager))
                }

                Menu("JavaScript Transforms") {
                    jsTransformItems
                }

                // Markdown moved under Text as a submenu — saves a
                // top-level menu bar slot without losing any commands.
                // Show Outline and Markdown Preview are also reachable
                // from the View menu since they're view-state.
                Menu("Markdown") { markdownSubmenuContent }
            }
            .disabled(!isEnabled)
        }

        // MARK: Tabs → Window menu. The Tabs top-level menu was
        // dropped; its actions now live under the system Window
        // menu via `CommandGroup(after: .windowList)`.

        CommandGroup(after: .windowArrangement) {
            Button("Show All Tabs", action: focused(CommandActions.showTabSwitcher))
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Close Tab", action: focused(CommandActions.closeActiveTab))
                .keyboardShortcut("w")
            Button("Reopen Last Closed Tab", action: focused(CommandActions.reopenLastClosedTab))
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab", action: focused(CommandActions.nextTab))
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab", action: focused(CommandActions.previousTab))
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Pin / Unpin Tab", action: focused(CommandActions.pinCurrentTab))
            Button("Close Other Tabs", action: focused(CommandActions.closeOtherTabs))
            Button("Close Tabs to the Right", action: focused(CommandActions.closeTabsToRight))
            Divider()
            Menu("Jump to Tab") {
                Button("Tab 1") { focused { CommandActions.selectTab(at: 1) } }.keyboardShortcut("1")
                Button("Tab 2") { focused { CommandActions.selectTab(at: 2) } }.keyboardShortcut("2")
                Button("Tab 3") { focused { CommandActions.selectTab(at: 3) } }.keyboardShortcut("3")
                Button("Tab 4") { focused { CommandActions.selectTab(at: 4) } }.keyboardShortcut("4")
                Button("Tab 5") { focused { CommandActions.selectTab(at: 5) } }.keyboardShortcut("5")
                Button("Tab 6") { focused { CommandActions.selectTab(at: 6) } }.keyboardShortcut("6")
                Button("Tab 7") { focused { CommandActions.selectTab(at: 7) } }.keyboardShortcut("7")
                Button("Tab 8") { focused { CommandActions.selectTab(at: 8) } }.keyboardShortcut("8")
                Button("Last Tab") { focused { CommandActions.selectTab(at: 9) } }.keyboardShortcut("9")
            }
        }
    }

    // MARK: - Markdown menu

    /// Items that used to live in the top-level Format menu. Now
    /// rendered inside View ▸ Format for the slim menu-bar spec.
    @ViewBuilder
    private var formatSubmenuContent: some View {
        Group {
            Menu("File Encoding")        { encodingMenuItems }
            Menu("Reopen with Encoding") { reopenWithEncodingMenuItems }
            Menu("Line Endings")         { lineEndingMenuItems }

            Divider()

            Menu("Syntax Style") { syntaxLanguageMenuItems }

            Divider()

            Menu("Indent") { indentMenuItems }
            Button("Indent Selection", action: focused(CommandActions.indentSelection))
                .keyboardShortcut("]")
            Button("Outdent Selection", action: focused(CommandActions.outdentSelection))
                .keyboardShortcut("[")
        }
        Divider()
        Group {
            Menu("Convert to List") {
                // Distinct titles from the Markdown ▸ List submenu —
                // UIKit derives UIAction identifiers from the title,
                // and duplicates make iPadOS drop the whole owning
                // menu via `_UIMenuBuilderError`.
                Button("Format as Dash List", action: focused(CommandActions.convertToBulletListDash))
                Button("Format as Asterisk List", action: focused(CommandActions.convertToBulletListStar))
                Button("Format as Numbered List", action: focused(CommandActions.convertToNumberedList))
            }

            Divider()

            Menu("Spelling") {
                Toggle("Check Spelling While Typing",
                       isOn: bindingFor(\.spellCheck, defaultsKey: AppPreferenceKey.spellCheck))
                Divider()
                // Manual one-shot check — works even with the live
                // toggle above turned off, so the user can audit a
                // document on demand without leaving the live
                // squiggles on for the rest of the session.
                // No keyboard shortcuts on the spell-check items:
                // ⌘; collides with Command Palette and ⇧⌘' collides
                // with Markdown ▸ Blockquote. iPadOS drops the
                // whole Spelling submenu via `_UIMenuBuilderError`
                // on any keyboard conflict, so these stay menu-only
                // / palette-only.
                Button("Check Document Spelling", action: focused(CommandActions.highlightAllMisspellings))
                Button("Clear Spelling Marks", action: focused(CommandActions.clearMisspellingHighlights))
                Divider()
                Button("Find Next Misspelling", action: focused(CommandActions.jumpToNextMisspelling))
                Button("Learn Spelling of Word", action: focused(CommandActions.learnSelectedWord))
                Button("Ignore Spelling for Word", action: focused(CommandActions.ignoreSelectedWord))
            }
        }
    }

    @ViewBuilder
    private var viewMenuFontItems: some View {
        Button("Bigger Font", action: focused(CommandActions.increaseFontSize))
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!isEnabled)
        Button("Smaller Font", action: focused(CommandActions.decreaseFontSize))
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!isEnabled)
        Button("Reset Font Size", action: focused(CommandActions.resetFontSize))
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuToggleItems: some View {
        Toggle("Show Line Numbers", isOn: bindingFor(\.showLineNumbers, defaultsKey: AppPreferenceKey.showLineNumbers))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!isEnabled)
        Toggle("Wrap Lines", isOn: bindingFor(\.wrapLines, defaultsKey: AppPreferenceKey.wrapLines))
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Toggle("Show Invisibles", isOn: bindingFor(\.showInvisibles, defaultsKey: AppPreferenceKey.showInvisibles))
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!isEnabled)
        Toggle("Show Page Guide", isOn: bindingFor(\.showPageGuide, defaultsKey: AppPreferenceKey.showPageGuide))
            .disabled(!isEnabled)
        Toggle("Show Status Bar", isOn: bindingFor(\.showStatusBar, defaultsKey: AppPreferenceKey.showStatusBar))
            .disabled(!isEnabled)
        Toggle("Show Toolbar", isOn: bindingFor(\.showToolbar, defaultsKey: AppPreferenceKey.showToolbar))
            .disabled(!isEnabled)
        Toggle("Highlight All Occurrences of Selection",
               isOn: bindingFor(\.liveMatchHighlight, defaultsKey: AppPreferenceKey.liveMatchHighlight))
            .disabled(!isEnabled)
        Toggle("Show Change History in Gutter",
               isOn: bindingFor(\.showChangeHistoryGutter, defaultsKey: AppPreferenceKey.showChangeHistoryGutter))
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuFoldItems: some View {
        // Fold at Cursor uses ⌃⌘F (matches Xcode's Code Folding
        // toggle convention; ⌥⌘F is Find and Replace).
        Button("Fold at Cursor", action: focused(CommandActions.toggleFoldAtCursor))
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(!isEnabled)
        Button("Fold Selection", action: focused(CommandActions.foldSelection))
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(!isEnabled)
        Button("Fold All", action: focused(CommandActions.foldAll))
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Button("Unfold All", action: focused(CommandActions.unfoldAll))
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Button("Clear Manual Fold Points", action: focused(CommandActions.clearManualFolds))
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuTailItems: some View {
        Button("Cycle Split View", action: focused(CommandActions.cycleSplitView))
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Divider()
        // Information panels — File Information surfaces document
        // metadata; it belongs with the View menu's other view-state
        // controls. (Show Outline lives at the top of the View menu
        // — `CommandGroup(replacing: .sidebar)` above — as the same
        // single item, since the sidebar IS the outline panel.)
        Button("Show File Information", action: focused(CommandActions.toggleInspector))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!isEnabled)
        // Character Inspector belongs with the other view-state /
        // inspector entries — it surfaces the Unicode breakdown of
        // the current selection. Previously buried in Format ▸
        // Text Transformations, which was the wrong home.
        Button("Character Inspector…", action: focused { presentSheet(.characterInspector) })
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(!isEnabled)
        Divider()
        // Bookmarks moved here from the Search menu — slots are a
        // view-state concern, and grouping the line-level actions
        // (copy/cut/keep/delete) with slot management gives the user
        // one place to look for everything bookmark-related.
        Menu("Bookmarks") { bookmarkMenuItems }
            .disabled(!isEnabled)
        Divider()
        // Format submenu — encoding, line endings, language, indent,
        // list-conversion, spelling. Pulled out of a separate
        // top-level Format menu to keep the nine-menu spec.
        Menu("Format") { formatSubmenuContent }
            .disabled(!isEnabled)
    }

    /// Markdown menu items, extracted so the Text ▸ Markdown
    /// submenu and any future palette / shortcut wiring share one
    /// source. Show Outline and Preview live in the View menu
    /// instead — they're view-state, not text-edit operations.
    @ViewBuilder
    private var markdownSubmenuContent: some View {
        Group {
            Button("Bold", action: focused(CommandActions.markdownBold))
                .keyboardShortcut("b")
            Button("Italic", action: focused(CommandActions.markdownItalic))
                .keyboardShortcut("i")
            Button("Inline Code", action: focused(CommandActions.markdownCode))
                .keyboardShortcut("`")
            Button("Strikethrough", action: focused(CommandActions.markdownStrike))
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Menu("Heading") {
                Button("Heading 1") { focused { CommandActions.markdownHeader(level: 1) } }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Heading 2") { focused { CommandActions.markdownHeader(level: 2) } }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Heading 3") { focused { CommandActions.markdownHeader(level: 3) } }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Button("Heading 4") { focused { CommandActions.markdownHeader(level: 4) } }
                    .keyboardShortcut("4", modifiers: [.command, .control])
                Button("Heading 5") { focused { CommandActions.markdownHeader(level: 5) } }
                    .keyboardShortcut("5", modifiers: [.command, .control])
                Button("Heading 6") { focused { CommandActions.markdownHeader(level: 6) } }
                    .keyboardShortcut("6", modifiers: [.command, .control])
            }
            Menu("List") {
                Button("Bullet List (- )", action: focused(CommandActions.convertToBulletListDash))
                Button("Bullet List (* )", action: focused(CommandActions.convertToBulletListStar))
                Button("Numbered List", action: focused(CommandActions.convertToNumberedList))
            }
        }
        Divider()
        Group {
            Button("Blockquote", action: focused(CommandActions.markdownBlockquote))
                .keyboardShortcut("'", modifiers: [.command, .shift])
            Button("Horizontal Rule", action: focused(CommandActions.markdownHorizontalRule))
                .keyboardShortcut("-", modifiers: [.command, .shift])
            Button("Link…", action: focused(CommandActions.markdownLink))
                .keyboardShortcut("k")
            Button("Image…", action: focused(CommandActions.markdownImage))
                .keyboardShortcut("k", modifiers: [.command, .option])
            // ⇧⌘0 collides with system "Default Zoom"; ⌃⌘F is taken
            // by Fold at Cursor; Footnote takes ⌥⌘N.
            Button("Footnote", action: focused(CommandActions.markdownFootnote))
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Organize Footnotes…") { presentSheet(.organizeFootnotes) }
            Button("Insert Table…", action: focused(CommandActions.presentMarkdownTable))
                .keyboardShortcut("t", modifiers: [.command, .control])
            Divider()
            Button("Preview…", action: focused(CommandActions.presentMarkdownPreview))
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }

    /// Items that used to live in the top-level Search menu. Now
    /// rendered inside Edit ▸ Find so the menu bar stays at the
    /// nine-menu spec (Ayyyy/File/Edit/View/Text/Markdown/Tabs/
    /// Window/Help).
    @ViewBuilder
    private var findSubmenuContent: some View {
        Group {
            Button("Find…") {
                // presentSheet already calls claimFocus; mirror that
                // here so the seed selection comes from the focused
                // editor too.
                focused {
                    CommandActions.seedFindFromSelection()
                    presentSheet(.findReplace)
                }
            }
            .keyboardShortcut("f")
            Button("Multi-File Search…", action: focused(CommandActions.presentMultiFileSearch))
                .keyboardShortcut("f", modifiers: [.command, .shift])
            // (Find Next / Previous / Find Incrementally / Find
            // First removed from this menu — they're controls in
            // the Find dialog itself now.)
        }

        Divider()

        Group {
            // (Jump to Selection / Reveal Selection Start / End all
            // removed — Reveal items duplicated Center Line for the
            // common case and were rarely used.)
            Button("Go to Line…") { presentSheet(.goToLine) }
                .keyboardShortcut("l")
            // ⇧⌘\ is taken by Show All Tabs (Safari convention).
            // Match-bracket gets ⌃⌘B (a common editor choice).
            Button("Go to Matching Bracket", action: focused(CommandActions.goToMatchingBracket))
                .keyboardShortcut("b", modifiers: [.command, .control])
            Button("Center Line", action: focused(CommandActions.centerLine))
        }

        Divider()

        Group {
            // (Tools submenu retired — Pattern Playground was its
            // last surviving item, and a single-item submenu hides
            // more than it organizes.)
            Divider()

            Button("Back", action: focused(CommandActions.positionBack))
                .keyboardShortcut(.leftArrow,  modifiers: [.command, .control])
            Button("Forward", action: focused(CommandActions.positionForward))
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])

            // (Bookmarks moved to the View menu — combines the
            // slot-level set/jump/clear with the line-level
            // copy/cut/keep/delete actions in one home.)
        }
    }

    // (Dead `markdownMenu` property removed — the actual Markdown
    // menu is inlined in `body` at line ~496 to avoid the
    // @CommandsBuilder-property render flakiness on iPadOS, and
    // because two CommandMenus with identical titles + items would
    // cause UIKit's MenuBuilder to drop one of them.)

    /// Lists every slot 1–10 with its shortcut (⌃⌥1…⌃⌥9, ⌃⌥0 = slot
    /// 10). Inactive (empty) slots are still visible — disabled — so
    /// the user can see which shortcuts are available to assign.
    /// Reads from `JSTransformStore.shared` directly each menu build
    /// (which is on demand, so it picks up edits live).
    @ViewBuilder
    private var jsTransformItems: some View {
        let slots = jsTransformStore.slots
        ForEach(slots) { slot in
            Button(slot.displayName) {
                focused { CommandActions.runJSTransform(slotID: slot.id) }
            }
            .keyboardShortcut(jsShortcutKey(for: slot.id), modifiers: [.control, .option])
            .disabled(!slot.isConfigured)
        }
        Divider()
        Button("Manage Transforms…", action: focused(CommandActions.presentPreferences))
    }

    private func jsShortcutKey(for id: Int) -> KeyEquivalent {
        // Slots 1–9 take ⌃⌥1 … ⌃⌥9. Slot 10 takes ⌃⌥0 (same scheme
        // the tab-jump shortcuts use).
        switch id {
        case 10: return "0"
        default: return KeyEquivalent(Character("\(id)"))
        }
    }

    // MARK: - Submenu builders

    @ViewBuilder
    private var encodingMenuItems: some View {
        ForEach(commonEncodings, id: \.self) { encoding in
            Button {
                focused { CommandActions.setEncoding(encoding) }
            } label: {
                if editorState?.fileEncoding == encoding {
                    Label(encoding.localizedName, systemImage: "checkmark")
                } else {
                    Text(encoding.localizedName)
                }
            }
        }
        Divider()
        Button("More Encodings…") { presentSheet(.encodingPicker) }
    }

    @ViewBuilder
    private var reopenWithEncodingMenuItems: some View {
        ForEach(commonEncodings, id: \.self) { encoding in
            Button(encoding.localizedName) {
                focused { CommandActions.reinterpretWithEncoding(encoding) }
            }
        }
    }

    @ViewBuilder
    private var lineEndingMenuItems: some View {
        ForEach(LineEnding.allCases, id: \.self) { lineEnding in
            Button {
                focused { CommandActions.applyLineEnding(lineEnding) }
            } label: {
                let title = "\(lineEnding.label) (\(lineEnding.description))"
                if editorState?.lineEnding == lineEnding {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    @ViewBuilder
    private var syntaxLanguageMenuItems: some View {
        ForEach(LanguageRegistry.all, id: \.identifier) { language in
            Button {
                focused { CommandActions.setLanguage(language.identifier) }
            } label: {
                if editorState?.languageIdentifier == language.identifier {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    @ViewBuilder
    private var openRecentMenuItems: some View {
        let recents = recentFilesStore.urls
        if recents.isEmpty {
            Text("No Recent Files").disabled(true)
        } else {
            ForEach(recents, id: \.self) { url in
                Button(url.lastPathComponent) {
                    // Route through the same window/tab pipeline as
                    // File → Open so a recent file lands in a new
                    // window (not in place of the current buffer).
                    if let route = AppStateBus.shared.scenes.routeOpenURL {
                        route(url)
                    } else {
                        AppStateBus.shared.pending.newWindow = url
                        AppStateBus.shared.scenes.openWindowAction?(.editor)
                    }
                }
            }
            Divider()
            Button("Clear Menu") { recentFilesStore.clear() }
        }
    }

    @ViewBuilder
    private var bookmarkMenuItems: some View {
        Menu("Set Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.setBookmark(slot) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: [.command, .shift])
            }
        }
        Menu("Jump to Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.jumpToBookmark(slot) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .option)
            }
        }
        Menu("Clear Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.clearBookmark(slot) }
                }
            }
        }
        Divider()
        // Line-level operations on bookmarked rows — moved here from
        // the old Text ▸ Lines ▸ Bookmarked Lines submenu so every
        // bookmark-related action lives in one place.
        Button("Copy Bookmarked Lines", action: focused(CommandActions.copyBookmarkedLines))
        Button("Cut Bookmarked Lines", action: focused(CommandActions.cutBookmarkedLines))
        Button("Keep Only Bookmarked Lines", action: focused(CommandActions.keepBookmarkedLinesOnly))
        Button("Delete Bookmarked Lines", action: focused(CommandActions.removeBookmarkedLines))
        Divider()
        Button("Invert Bookmarks", action: focused(CommandActions.invertBookmarks))
    }

    @ViewBuilder
    private var indentMenuItems: some View {
        Button {
            focused { CommandActions.setIndentUsesTabs(false) }
        } label: {
            if editorState?.usesTabs == false {
                Label("Use Spaces", systemImage: "checkmark")
            } else {
                Text("Use Spaces")
            }
        }
        Button {
            focused { CommandActions.setIndentUsesTabs(true) }
        } label: {
            if editorState?.usesTabs == true {
                Label("Use Tabs", systemImage: "checkmark")
            } else {
                Text("Use Tabs")
            }
        }
        Divider()
        ForEach([2, 3, 4, 6, 8], id: \.self) { width in
            Button {
                focused { CommandActions.setIndentWidth(width) }
            } label: {
                if editorState?.indentWidth == width {
                    Label("Width: \(width)", systemImage: "checkmark")
                } else {
                    Text("Width: \(width)")
                }
            }
        }
    }

    private var commonEncodings: [FileEncoding] {
        [
            FileEncoding(encoding: .utf8),
            FileEncoding(encoding: .utf8, withUTF8BOM: true),
            FileEncoding(encoding: .utf16),
            FileEncoding(encoding: .utf16LittleEndian),
            FileEncoding(encoding: .utf16BigEndian),
            FileEncoding(encoding: .windowsCP1252),
            FileEncoding(encoding: .isoLatin1),
            FileEncoding(encoding: .macOSRoman),
            FileEncoding(encoding: .shiftJIS),
            FileEncoding(encoding: .japaneseEUC)
        ]
    }

    /// Builds a binding for a Bool on the active editor state. If a
    /// `defaultsKey` is supplied, the new value also writes back to
    /// UserDefaults so the change survives relaunch. When no editor
    /// is currently focused (cold launch / window swap), the getter
    /// falls back to the persisted preference rather than `false` —
    /// otherwise the toggle would visually lie about whether the
    /// pref is on.
    private func bindingFor(
        _ keyPath: ReferenceWritableKeyPath<EditorState, Bool>,
        defaultsKey: String? = nil
    ) -> Binding<Bool> {
        Binding(
            get: {
                if let state = editorState { return state[keyPath: keyPath] }
                if let defaultsKey { return UserDefaults.standard.bool(forKey: defaultsKey) }
                return false
            },
            set: { newValue in
                editorState?[keyPath: keyPath] = newValue
                if let defaultsKey {
                    UserDefaults.standard.set(newValue, forKey: defaultsKey)
                }
            }
        )
    }
}
