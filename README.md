# ayyyy

iPad-native plain-text/code editor with multi-window tabs, a launcher-style entry point on every new tab/window, and a Mac-style autosave model that keeps a recoverable draft of every dirty buffer in iCloud Drive.

## Status

iOS 26 simulator clean build verified.

## What's in the box

### Launcher

Every new tab/window opens onto a launcher surface — never a blank buffer. The launcher has four entry points:

- **Open File…** — embeds `UIDocumentBrowserViewController` in-tab; picking a file flips the tab to editor mode in place. A Back chip returns to the launcher without closing the tab.
- **From Clipboard** — seeds a fresh Untitled buffer with `UIPasteboard.general.string`.
- **Templates** — grid of files from `Documents/Templates/` (seeded with Blank.txt, Notes.md, Data.csv on first launch). User-added templates surface automatically; default seeds are re-installed if missing (so app updates can ship new defaults) but never overwrite a user file.
- **Unsaved Drafts** — list of `DraftRecord`s from the launcher's union of iCloud + local roots. Tapping a draft adopts its bytes into the active tab; the file is deleted from the synced folder (the "checkout"), so the same draft can't be open simultaneously on two devices. On close, the buffer is re-committed.

The launcher renders inside the editor's text region, leaving the toolbar, status bar, and keyboard accessory intact. Switching tabs and coming back preserves it.

### Editor

- Tree-sitter syntax highlighting for **Bash, C, C++, CSS, Go, HTML, Java, JavaScript, LaTeX, Markdown, Python, Ruby, Rust, Swift, TypeScript, Typst** (16 languages). Grammars pulled via SwiftPM; highlight queries vendored from CotEditor's `SyntaxParsers` set plus locally-added equivalents.
- Configurable line numbers, line wrap, invisibles (tabs / spaces / line breaks / NBSP), page guide, configurable overscroll.
- Themes registered from a `PortedThemes` catalog (Default / Light / Dark + CotEditor's full set).
- Font picker (system mono + system proportional families); adjustable size.
- Tabs vs. spaces, configurable indent width.
- Automatic character-pair insertion.
- Find / Find Next / Find Previous via `UIFindInteraction`; multi-file search across open editors / file browsers / chosen folders.
- Go to Line, Go to Matching Bracket, position back/forward history.
- Code folding (fold at cursor, fold all, unfold all, fold selection block).
- Bookmarks per line, jump-to-bookmark.
- Outline sidebar (iPad) driven by tree-sitter language queries.
- Per-line change-history gutter (green/yellow/red bars vs. last saved baseline).
- Live match highlighting (current selection occurrences tinted everywhere).
- Live spell check + walk-through Check Spelling sheet (Change / Ignore / Ignore All / Learn).
- Sticky modifier keys + caret-jump utilities in the keyboard accessory (iPhone) / QuickType bar (iPad), plus the standard set when a hardware keyboard is attached.
- Split view (horizontal / vertical) over the same document.

### Document, drafts, sessions

- **Custom `PlainTextDocument`** (`@Observable`, not `FileDocument`) — works around an iOS 26.5 simulator FileProvider bug; loads via `URLSession.data(from:)` so cancellation actually aborts a hung pull.
- BOM-aware encoding detection with declaration scanning; full system encoding picker (Convert vs. Re-interpret).
- Line-ending detection (LF / CR / CRLF / NEL / LS / PS); conversion on apply or save.
- Stale-source safeguard: per-document mtime + size baseline. Before ⌘S we re-read disk; on draft adoption we compare against the draft's recorded baseline. Three alert flavors: source missing, changed since draft was captured, changed since load.
- Mac-style autosave to scratch + recoverable draft. Per-keystroke (800 ms debounced): scratch only. On close / app-background: also commits a draft to the synced Drafts folder. `commitDraft: Bool` on `autoSave` is the gate.
- "Save as Draft" close-confirmation action and title-context-menu entry. Batch close (Other / To-the-Right / All) routes through one prompt when any tab is dirty.

### Tabs and windows

- Custom tab pills (iPad chrome) + tab switcher sheet (iPhone + iPad, expose-style with cards).
- Tab pill long-press: pin, move to new window (iPad only), close.
- Overview button long-press: open new tab, close this / others / right / all. Same `TabOverviewContextMenu` on iPhone status bar and iPad chrome.
- Pinned tabs survive batch closes.
- Closed-tab pool: ⇧⌘T reopens.
- "Untitled" docs get a monotonic per-launch number ("Untitled", "Untitled 2", …).
- Closing the last tab spawns a fresh launcher in its place; Cancel on a single-tab launcher closes the window (iPad) or is hidden (iPhone).
- Session restoration applies only to involuntary kills (OOM, reboot). User-swiped sessions go away forever; the cold-launch filter in `AppDelegateBridge.configurationForConnecting` destroys iPadOS-level ghosts that don't have a backing `SessionRecord`.

### iCloud sync

`UbiquityContainer` resolves the app's iCloud Drive container (`iCloud.com.palefire.ayyyy`). With `NSUbiquitousContainerIsDocumentScopePublic = YES` in Info.plist, Drafts and Templates show up as "Ayyyy" in Files.app and sync across devices. The PreferencesView "iCloud" section gates this with a `Toggle("Sync via iCloud Drive")`; reads always union iCloud + local roots so flipping the toggle is non-destructive.

### Text utilities

- Sort Lines (case / numeric / locale / descending / keep-first-line via `EditorKit.LineSort`).
- Unique Lines, Reverse Lines.
- Trim Trailing Whitespace.
- Case conversion (UPPER / lower / Capitalized).
- Process Lines (per-line regex pipeline).
- Canonize (pair-based substitutions).
- Prefix / Suffix Lines, Select Lines Containing.
- Zap Gremlins (clean non-printing characters).
- Reflow paragraphs, organize footnotes.
- Markdown wrappers (bold / italic / code / quote / etc.) + heading levels + table builder + structural inserts.
- Character Inspector — Unicode glyph view with scalar table (`EditorKit.CharacterInfo`).
- Insert Date / Time / File Path / Filename / Lorem Ipsum / File Contents / Folder Listing.
- 10-slot Snippets (⌥⌘1–9, ⌥⌘0). Slots persist across launches; "Save Selection as Snippet" writes into the first empty slot.
- 10-slot JavaScript Transforms (⌃⌥1–9, ⌃⌥0) — each slot runs a JS snippet against document or selection.
- Clipboard history (⇧⌘V) with persistent ring buffer.

### Markdown preview

`MarkdownPreviewScene` is its own `WindowGroup`. Pipes the focused editor's text through `marked.js` in a WKWebView; toolbar Share / Print → Save as PDF.

### Menu bar + command palette

Every command is registered in `CommandRegistry` with id, title, category, optional shortcut hint, synonyms, and `isEnabled` predicate. `CommandPaletteSheet` (⌘;) searches across them. The iPadOS menu bar is built from `EditorCommands` (a SwiftUI `Commands` builder) and mirrors the same set into native menus + keyboard shortcuts.

### Preferences

Opens as its own `WindowGroup` (separate window on iPad). Multi-tab Form:

- **Appearance** — theme, font face, font size, line height, ligatures.
- **Editor** — line numbers, wrap, current-line highlight, bracket matching, page guide, status-bar items, change-history gutter, overscroll.
- **Invisibles** — master toggle + per-kind glyphs (space / tab / newline / NBSP).
- **Indentation** — tabs vs. spaces, indent width.
- **Typing** — auto-correct, auto-capitalize, smart quotes, live spell check, auto-continue lists.
- **Snippets** — manage the 10-slot pool.
- **JS Transforms** — manage the 10-slot pool.
- **Save** — trailing newline, trim trailing whitespace, save UTF-8 BOM.
- **Defaults for new documents** — encoding, line ending, syntax language.
- **Large files** — syntax-applies-up-to threshold (above which the document opens in plain-text mode).
- **iCloud** — Sync via iCloud Drive toggle.
- **Toolbar** — slot editor for the per-window in-app toolbar (symbol + command id per slot).
- **System Text Replacement** — link to iOS Settings.

All preferences persisted via `@AppStorage`. New `EditorState`s seed from them at construction; `EditorPrefSync` mirrors live changes onto open documents.

### Status bar

Bottom of every editor (compact / wide variants by horizontal size class). Left: `Ln, Col · char count, line count`. Right: Encoding / Line Endings / Language pills that open their pickers. Live match count appears when match highlighting fires.

## Build & run

Prerequisites: Xcode 26 or later, iOS 26 Simulator runtime.

```
open Ayyyy.xcodeproj
```

Then build & run the `Ayyyy` scheme against an iPad simulator.

Clean build from CLI (no code signing):

```
xcodebuild -project Ayyyy.xcodeproj -scheme Ayyyy \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug -skipPackagePluginValidation \
    build CODE_SIGNING_ALLOWED=NO
```

## Layout

```
ayyyy/
├── Ayyyy.xcodeproj/        # iOS 26 app target; two local SPM dependencies
├── App/
│   ├── Sources/
│   │   ├── App/            # @main, scene wiring (WindowGroup + Preferences)
│   │   ├── Documents/      # PlainTextDocument: @Observable doc w/ encoding round-trip + retained Data
│   │   ├── Editor/         # EditorState, EditorTextView (Runestone wrapper), EditorView, EditorScene, drafts/session stores
│   │   ├── Menu/           # EditorCommands: the iPadOS menu bar
│   │   ├── Features/       # Pickers / inspectors / sheets / launcher
│   │   ├── Preferences/    # AppPreferences (keys/defaults), PreferencesView (multi-tab Form)
│   │   └── Support/        # AppTheme, LanguageRegistry, DeviceIdiom, Timing, UbiquityContainer
│   └── Resources/          # Info.plist, entitlements, Assets.xcassets
├── Packages/
│   ├── EditorKit/          # consolidated package — vendored modules + new code:
│   │                       #   EditorEngine     (vendored from simonbs/Runestone, MIT)
│   │                       #   FileEncoding, LineEnding, LineSort, CharacterInfo,
│   │                       #     StringUtils, ValueRange (vendored from coteditor/CotEditor, Apache 2.0)
│   │                       #   AyyyySyntax      (tree-sitter grammar bridging)
│   └── TreeSitterTypst/    # local Typst grammar vendor (MIT)
├── project.yml             # XcodeGen spec (fallback)
├── NOTICE.md
└── README.md
```

## Architecture notes

### EditorActions protocol — module name collision workaround

`EditorEngine` (the Runestone fork) and `EditorKit.LineEnding` both export a type named `LineEnding`. Swift can't disambiguate `LineEnding.LineEnding` when both modules are in scope. To avoid the conflict, menu code (`EditorCommands`) imports only `LineEnding` (the CotEditor module), the `EditorEngine` wrapper imports only `EditorEngine`, and they communicate via a Foundation-only `EditorActions` protocol that uses raw `Character` values for line endings.

### Tree-sitter bridging

Each tree-sitter grammar SPM package forward-declares its own `typedef struct TSLanguage TSLanguage`. Swift sees each as a distinct type even though the underlying C struct is identical. `AyyyySyntax.SyntaxRegistry` bridges with `unsafeBitCast` to `TreeSitter.TSLanguage` (the canonical type from the upstream `tree-sitter` SPM package that `EditorEngine` also depends on). The build emits warnings for this — expected and intentional.

### Concurrency

`Coordinator` (UIViewRepresentable coordinator) is `@MainActor` with a `@preconcurrency` conformance to `EditorEngine.TextViewDelegate`. The engine calls back on the main thread; the annotation tells Swift 6 to trust that.

### SwiftLint stripped from vendored CotEditor modules

CotEditor's upstream `EditorCore/Package.swift` attaches `SwiftLintBuildToolPlugin`. SwiftLint's binary fails inside `xcodebuild`'s plugin sandbox on some setups, so the plugin attachment was removed when those modules were folded into `EditorKit`.

## Known limitations

- No custom theme editor; themes are code-defined (catalog in `PortedThemes`).
- No localization beyond what the CotEditor-derived modules already ship.
- No tests in the app target (packages have their own).
- iCloud cross-device conflict UI not yet built (`NSFileVersion`-based resolution sheet is on the list). Simultaneous edits on two devices fall back to iCloud's default last-writer-wins.
- App can intercept window-close to write drafts but not to present a dialog — iPadOS has no `windowShouldClose` equivalent. Drafts are flushed automatically on `.background` / `.onDisappear`; the launcher's Drafts list is the next-launch recovery surface.

## Recovery if `Ayyyy.xcodeproj` fails to open

The project file was hand-written. If Xcode rejects it, the cleanest reset is via XcodeGen:

```
brew install xcodegen
rm -rf Ayyyy.xcodeproj
xcodegen generate
```

Or in Xcode: File → New → Project → iOS → App, delete its default sources, drag in `App/Sources/`, add `Packages/EditorKit` and `Packages/TreeSitterTypst` as local Swift Package dependencies, and link products `FileEncoding`, `LineEnding`, `LineSort`, `CharacterInfo`, `EditorEngine`, `AyyyySyntax`.

## Upstream

- CotEditor: https://github.com/coteditor/CotEditor (Apache 2.0) — modules `FileEncoding`, `LineEnding`, `LineSort`, `CharacterInfo`, `StringUtils`, `ValueRange` inside `EditorKit`.
- Runestone: https://github.com/simonbs/Runestone (MIT) — vendored into `EditorKit` as `EditorEngine`.
- tree-sitter and language grammars: https://github.com/tree-sitter (MIT) — pulled remotely via SwiftPM by `EditorKit`, plus a local Typst grammar at `Packages/TreeSitterTypst/`.

See `NOTICE.md` for full attribution.
