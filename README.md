# ayyyy

```
    \\       //
     \\     //
      \\   //
       \\ //
        \V/
        /-\
       /   \
      /=====\
```

The logo is the Proto-Sinaitic *ʾalp* — an ox-head pictogram from ~1850 BCE that, through ~3,000 years of rotation and stylization, became the Latin **A**. See [History of A](https://en.wikipedia.org/wiki/A#History).

---

iPad-native plain-text/code editor with multi-window tabs, a launcher entry point on every new tab/window, and a Mac-style autosave model that keeps recoverable drafts of every dirty buffer in iCloud Drive.

## Status

iOS 26 simulator clean build verified.

## What's in the box

**Launcher.** Every new tab opens onto a launcher — never a blank buffer. Four entry points: Open File (in-tab `UIDocumentBrowserViewController`), From Clipboard, Templates (seeded from `Documents/Templates/`), Unsaved Drafts (union of iCloud + local roots).

**Editor.** Tree-sitter syntax highlighting for 16 languages (Bash, C, C++, CSS, Go, HTML, Java, JavaScript, LaTeX, Markdown, Python, Ruby, Rust, Swift, TypeScript, Typst). Configurable line numbers / wrap / invisibles / page guide / overscroll. Themes (Default / Light / Dark + CotEditor's catalog). Font picker. Tabs vs. spaces. Auto pair insertion. Find / Find Next / Find Previous via `UIFindInteraction`; multi-file search across open editors / browsers / folders. Go to Line, Go to Matching Bracket, position history. Code folding. Bookmarks. Outline sidebar (iPad). Per-line change-history gutter. Live match highlighting. Live spell check. Sticky modifiers in QuickType bar / keyboard accessory. Split view (horizontal / vertical).

**Documents.** Custom `@Observable` `PlainTextDocument` (works around an iOS 26.5 simulator FileProvider bug). BOM-aware encoding detection with declaration scanning. Line-ending detection (LF / CR / CRLF / NEL / LS / PS) with conversion on apply or save. Stale-source safeguards (per-document mtime + size baseline). Mac-style autosave: scratch per keystroke (800 ms debounced), recoverable draft committed on close / background. Save as Draft close action; batch close routes through one prompt.

**Tabs & windows.** Custom tab pills (iPad) + expose-style switcher (iPhone + iPad). Long-press: pin, move to new window (iPad), close (this / others / right / all). Pinned tabs survive batch closes. ⇧⌘T reopens closed tabs. "Untitled" docs get a monotonic per-launch number. Closing the last tab spawns a fresh launcher. Session restoration only for involuntary kills.

**iCloud sync.** `UbiquityContainer` resolves `iCloud.com.palefire.ayyyy`. With `NSUbiquitousContainerIsDocumentScopePublic`, Drafts and Templates surface as "Ayyyy" in Files.app. Toggle in Preferences; reads always union iCloud + local, so flipping the toggle is non-destructive.

**Text utilities.** Sort / Unique / Reverse Lines, Trim Trailing Whitespace, Case conversion (UPPER / lower / Capitalized), Process Lines (per-line regex pipeline), Canonize, Prefix / Suffix Lines, Select Lines Containing, Zap Gremlins, Reflow paragraphs, organize footnotes, Markdown wrappers (bold / italic / code / quote / heading / table / structural inserts), Character Inspector, Insert Date / Time / Path / Filename / Lorem Ipsum / File Contents / Folder Listing, 10 Snippet slots (⌥⌘1–9, ⌥⌘0), 10 JS Transforms (⌃⌥1–9, ⌃⌥0), clipboard history (⇧⌘V).

**Markdown preview.** Separate `WindowGroup` piping focused-editor text through `marked.js` in a WKWebView; toolbar Share / Print → Save as PDF.

**Command palette + menu bar.** Every command lives in `CommandRegistry` (id, title, category, shortcut hint, synonyms, `isEnabled` predicate). `CommandPaletteSheet` (⌘;) searches across all of them. The iPadOS menu bar (built from `EditorCommands`) mirrors the same set into native menus + keyboard shortcuts.

**Preferences.** Separate `WindowGroup` with a multi-tab Form: Appearance, Editor, Invisibles, Indentation, Typing, Snippets, JS Transforms, Save, Defaults for new documents, Large files, iCloud, Toolbar, System Text Replacement. Persisted via `@AppStorage`; live changes mirror onto open docs via `EditorPrefSync`.

**Status bar.** `Ln, Col · char count, line count` on the left; Encoding / Line Endings / Language pills (each opens its picker) on the right; live match count when match highlighting fires.

## Build

Xcode 26+ with iOS 26 Simulator runtime.

```
open Ayyyy.xcodeproj
```

CLI clean build (no signing):

```
xcodebuild -project Ayyyy.xcodeproj -scheme Ayyyy \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug -skipPackagePluginValidation \
    build CODE_SIGNING_ALLOWED=NO
```

If `Ayyyy.xcodeproj` won't open: `brew install xcodegen && rm -rf Ayyyy.xcodeproj && xcodegen generate`.

## Layout

```
ayyyy/
├── Ayyyy.xcodeproj/
├── App/Sources/           # @main, PlainTextDocument, editor, menu, features, prefs
├── Packages/
│   ├── EditorKit/         # EditorEngine (Runestone) + FileEncoding, LineEnding,
│   │                      #   LineSort, CharacterInfo, StringUtils, ValueRange
│   │                      #   (CotEditor) + AyyyySyntax (tree-sitter bridging)
│   └── TreeSitterTypst/
├── project.yml
├── NOTICE.md
└── README.md
```

## Architecture notes

- **`EditorActions` protocol** — `EditorEngine` and `EditorKit.LineEnding` both export a `LineEnding` type. Menu code imports CotEditor's `LineEnding`; the engine wrapper imports `EditorEngine`; they communicate via a Foundation-only protocol that uses raw `Character` values.
- **Tree-sitter bridging** — each grammar SPM package forward-declares its own `TSLanguage`. `AyyyySyntax.SyntaxRegistry` bridges with `unsafeBitCast` to the canonical `TreeSitter.TSLanguage`. Expected build warnings.
- **Concurrency** — the `UIViewRepresentable` coordinator is `@MainActor` with a `@preconcurrency` conformance to `EditorEngine.TextViewDelegate`.
- **SwiftLint stripped from vendored CotEditor modules** — the upstream `SwiftLintBuildToolPlugin` was removed because its binary fails inside `xcodebuild`'s plugin sandbox on some setups.

## Known limitations

- No custom theme editor (themes are code-defined in `PortedThemes`).
- No localization beyond what CotEditor-derived modules already ship.
- No tests in the app target (packages have their own).
- iCloud cross-device conflict UI not yet built; falls back to iCloud's last-writer-wins.
- iPadOS has no `windowShouldClose` equivalent; drafts flush automatically on `.background` / `.onDisappear`, and the launcher's Drafts list is the recovery surface.

## Licensing

This project vendors source from two upstream editors and ships a logo based on an ancient script.

| Component | Source | License |
|---|---|---|
| `EditorEngine` | [simonbs/Runestone](https://github.com/simonbs/Runestone) — © 2021 Simon Støvring | MIT |
| `FileEncoding`, `LineEnding`, `LineSort`, `CharacterInfo`, `StringUtils`, `ValueRange` | [coteditor/CotEditor](https://github.com/coteditor/CotEditor) — © 2005–2009 nakamuxu, © 2011, 2014 usami-k, © 2013–2026 1024jp | Apache 2.0 |
| tree-sitter and language grammars | [tree-sitter](https://github.com/tree-sitter) | MIT |
| Logo glyph | Proto-Sinaitic *ʾalp* — see [History of A](https://en.wikipedia.org/wiki/A#History) | Public domain (script in use ~1850 BCE; predates all modern copyright by ~3,800 years) |

Full attribution and preserved upstream LICENSE text: see `NOTICE.md` and `Packages/EditorKit/LICENSE-EditorCore` / `LICENSE-Runestone`.
