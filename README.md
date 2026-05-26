# ayyyy

iPad-native plain-text/code editor. Built on **Runestone** for the editor surface, with **CotEditor** document-level features layered on top, and **most commands lifted into the iPadOS menu bar**.

## Status

iOS 26 Simulator clean build verified. Ready to run from Xcode.

## What's in the box

### Editor

- Tree-sitter syntax highlighting via Runestone for **Bash, C, CSS, Go, HTML, JavaScript, Python, Ruby, Rust, Swift** (10 languages). Highlight queries vendored from CotEditor's `SyntaxParsers` package.
- Configurable line numbers, line wrap, invisibles (tabs / spaces / line breaks / NBSP / soft line breaks), page guide.
- Themes: Default (Runestone built-in), Light, Dark.
- Adjustable font size (9–32 pt).
- Tabs vs. spaces, configurable indent width (2/3/4/6/8 or any via Preferences).
- Automatic character pair insertion (`()` `[]` `{}` `""` `''` `` `` ``).
- Find / Find Next / Find Previous via Runestone's `UIFindInteraction` (system-presented).
- Go to Line (⌘L) with bounds-checked input.

### Document layer (from CotEditor `EditorCore`)

- BOM-aware encoding detection on open, with declaration scanning.
- Full encoding picker (every encoding the system knows) + Convert vs. **Re-interpret bytes** (original `Data` is retained, so re-decoding doesn't lose information).
- Line-ending detection (LF / CR / CRLF / NEL / LS / PS), conversion on apply or save.
- Sort Lines (case / numeric / locale / descending / keep-first-line via `EditorCore.LineSort`).
- Unique Lines, Reverse Lines.
- Trim Trailing Whitespace.
- Case conversion (UPPER / lower / Capitalized).
- Character Inspector — Unicode glyph view with scalar table (`EditorCore.CharacterInfo`).
- Insert Date & Time / File Path / Filename.

### iPadOS menu bar

Everything above is reachable from the menu bar. Layout:

```
Ayyyy
  Preferences…                   ⌘,

File
  New, Open, Save, Save As       (DocumentGroup)
  Text Encoding ▸                (10 common + "More Encodings…")
  Line Endings ▸                 (LF/CR/CRLF/NEL/LS/PS)

Edit
  Undo, Redo, Cut, Copy, Paste, Select All
  Find…                          ⌘F
  Find Next                      ⌘G
  Find Previous                  ⇧⌘G
  Go to Line…                    ⌘L

View
  Show Line Numbers              ⇧⌘L
  Wrap Lines                     ⌥⌘W
  Show Invisibles                ⇧⌘I
  Show Page Guide
  Theme ▸                        (Default / Light / Dark)
  Syntax Language ▸              (24 entries)
  Indentation ▸                  (Tabs/Spaces + width 2/3/4/6/8)

Text
  Sort Lines…
  Reverse Lines
  Unique Lines
  Trim Trailing Whitespace
  Convert Case ▸                 (UPPER / lower / Capitalized)
  Insert ▸                       (Date & Time / File Path / Filename)
  Character Inspector…           ⌃⌘I
  Auto-insert Character Pairs    (toggle)
```

### Preferences (separate window)

Invoked via `⌘,` (or Ayyyy → Preferences…). Opens as its own scene via `WindowGroup(id: "preferences")` — on iPadOS this becomes a separate window in Stage Manager / Split View.

Tabs:

- **General** — Theme, Font Size.
- **Editor** — Line Numbers, Wrap Lines, Invisibles, Page Guide column, Tabs vs. Spaces, Indent Width, Character Pairs.
- **Format** — Default encoding, line endings, syntax language for new documents.
- **Typing** — Auto-correct, Auto-capitalize, Smart Quotes & Dashes, Spelling check (all off by default — these change the bytes you type).

All preferences persisted via `@AppStorage` and seeded into new `EditorState`s on document open.

### Status bar

Bottom of every editor: `Ln, Col · char count, line count` on the left; tappable Encoding / Line Endings / Language pills on the right that open their respective pickers.

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
├── Ayyyy.xcodeproj/        # iOS 26 app target, three local SPM dependencies
├── App/
│   ├── Sources/
│   │   ├── App/            # @main, DocumentGroup + Preferences scenes
│   │   ├── Documents/      # PlainTextDocument: FileDocument w/ encoding round-trip + retained Data
│   │   ├── Editor/         # EditorState, RunestoneTextView, EditorView, EditorActions
│   │   ├── Menu/           # EditorCommands: the iPadOS menu bar
│   │   ├── Features/       # Picker / inspector / sort / go-to-line sheets
│   │   ├── Preferences/    # AppPreferences (keys/defaults), PreferencesView (4-tab Form)
│   │   └── Support/        # AppTheme (Runestone Theme), LanguageRegistry (ext → identifier)
│   └── Resources/          # Info.plist, entitlements, Assets.xcassets
├── Packages/
│   ├── EditorCore/         # vendored from coteditor/CotEditor (Apache 2.0)
│   ├── Runestone/          # vendored from simonbs/Runestone (MIT)
│   └── AyyyySyntax/        # new: 10 tree-sitter grammars + highlights queries
├── project.yml             # XcodeGen spec (fallback)
├── NOTICE.md
└── README.md
```

## Architecture notes

### EditorActions protocol — module name collision workaround

Both Runestone and `EditorCore.LineEnding` export a type named `LineEnding`. Swift can't disambiguate `LineEnding.LineEnding` when both modules are in scope. To avoid the conflict, menu code (`EditorCommands`) imports only `LineEnding` (EditorCore), the Runestone wrapper imports only `Runestone`, and they communicate via a Foundation-only `EditorActions` protocol that uses raw `Character` values for line endings.

### Tree-sitter bridging

Each tree-sitter grammar SPM package forward-declares its own `typedef struct TSLanguage TSLanguage`. Swift sees each as a distinct type even though the underlying C struct is identical. `AyyyySyntax.SyntaxRegistry` bridges with `unsafeBitCast` to `TreeSitter.TSLanguage` (Runestone's canonical type). The build emits two warnings for this — expected and intentional.

### Concurrency

`Coordinator` (UIViewRepresentable coordinator) is `@MainActor` with a `@preconcurrency` conformance to `Runestone.TextViewDelegate`. Runestone calls back on the main thread; the annotation tells Swift 6 to trust that.

### SwiftLint stripped from vendored EditorCore

CotEditor's upstream `EditorCore/Package.swift` attaches `SwiftLintBuildToolPlugin`. SwiftLint's binary fails inside `xcodebuild`'s plugin sandbox on some setups, so the plugin attachment was removed from our fork.

## Known limitations

- No outline view yet (Runestone doesn't render outlines directly; would need a sidebar driven by tree-sitter `outline.scm` queries).
- No preferences-driven font *family* selection — only size. Monospaced system font is hard-coded.
- No custom theme editor; themes are code-defined.
- No Markdown / TypeScript / JSON syntax (Markdown's tree-sitter has no highlights query in CotEditor's set; TypeScript / JSON could be added by following the pattern in `Packages/AyyyySyntax/SyntaxRegistry.swift`).
- No localization beyond what `EditorCore` already ships.
- No tests in the app target (packages have their own).

## Recovery if `Ayyyy.xcodeproj` fails to open

The project file was hand-written. If Xcode rejects it, the cleanest reset is via XcodeGen:

```
brew install xcodegen
rm -rf Ayyyy.xcodeproj
xcodegen generate
```

Or in Xcode: File → New → Project → iOS → Document App, delete its default sources, drag in `App/Sources/`, add `Packages/EditorCore`, `Packages/Runestone`, `Packages/AyyyySyntax` as local Swift Package dependencies, and link products `FileEncoding`, `LineEnding`, `LineSort`, `CharacterInfo`, `Runestone`, `AyyyySyntax`.

## Upstream

- CotEditor: https://github.com/coteditor/CotEditor (Apache 2.0)
- Runestone: https://github.com/simonbs/Runestone (MIT)

See `NOTICE.md` for full attribution.
