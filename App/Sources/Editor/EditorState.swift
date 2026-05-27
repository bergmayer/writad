import SwiftUI
import Combine
import FileEncoding
import LineEnding

/// Per-document state shared by SwiftUI views and the menu bar
/// (via FocusedValues). Initial values seed from `AppPreferences`.
@MainActor
@Observable
final class EditorState {

    // Document
    var text: String = ""
    var fileEncoding: FileEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var fileURL: URL?
    /// Diff baseline for the change-history gutter — reset on every
    /// load / save / revert.
    var savedBaselineText: String = ""
    var sidebarOpen: Bool = false
    /// On state (not @State on the view) so menu and the status-bar
    /// ⓘ share one source of truth.
    var inspectorOpen: Bool = false
    /// Two views over the SAME document — per-pane cursor/scroll, but
    /// writes flow back to the shared `PlainTextDocument`.
    var splitOpen: Bool = false
    var splitOrientation: SplitOrientation = .horizontal
    var splitFraction: CGFloat = 0.5
    /// Set when split opens — lets a coordinator reach across to the
    /// sibling pane's text view and propagate edits directly without
    /// a shared observable. Weak to break the would-be retain cycle.
    weak var siblingState: EditorState?
    var languageIdentifier: LanguageIdentifier
    /// Exceeded `SyntaxLimit` — opened in plain-text mode, skipping
    /// tree-sitter, fold discovery, and the markdown decorator.
    var isLargeFile: Bool = false

    // View settings
    var showLineNumbers: Bool
    var wrapLines: Bool
    var highlightCurrentLine: Bool
    var highlightMatchingBrackets: Bool
    var showPageGuide: Bool
    var pageGuideColumn: Int
    /// Off by default — the per-line diff is cheap but caretRect
    /// lookups grow with line count, and `Timing
    /// .changeHistoryGutterByteLimit` short-circuits past the ceiling.
    var showChangeHistoryGutter: Bool
    /// Adds a 10-line scrollable cushion below the last line so it
    /// isn't pinned to the window's bottom edge.
    var overscroll: Bool
    var themeName: AppThemeName
    /// Non-nil → per-window theme picked via the info inspector,
    /// wins over Settings. Lives in memory only; cleared with the tab.
    var themeOverride: AppThemeName?
    var fontOverride: EditorFont?
    var fontSizeOverride: Double?

    // Invisibles — master toggle plus per-kind selection
    var showInvisibles: Bool
    var showInvisibleSpace: Bool
    var showInvisibleTab: Bool
    var showInvisibleNewline: Bool
    var showInvisibleNonBreakingSpace: Bool

    // Status-bar items
    var statusShowsLineCol: Bool
    var statusShowsCharCount: Bool
    var statusShowsLineCount: Bool

    // Indentation
    var usesTabs: Bool
    var indentWidth: Int

    // Typing behavior
    var insertCharacterPairs: Bool
    var autoCorrect: Bool
    var autoCapitalize: Bool
    var smartQuotes: Bool
    var spellCheck: Bool
    var autoLinkDetection: Bool

    // UI
    var showStatusBar: Bool
    var showToolbar: Bool
    var liveMatchHighlight: Bool
    /// Selection-occurrence count for the status bar; 0 when nothing's
    /// highlighted.
    var liveMatchCount: Int = 0
    /// Accessory keyboard's sticky modifiers. Armed by a tap on the
    /// accessory bar; the engine's `shouldChangeTextIn` consumes them
    /// on the next text insertion to fire the matching modified
    /// command instead of typing the literal character. Shift is
    /// derived from the case of the incoming character (iOS shift
    /// arms the uppercase form natively), not tracked here.
    var armedAccessoryControl: Bool = false
    var armedAccessoryCommand: Bool = false
    var armedAccessoryOption: Bool = false
    var font: EditorFont
    var fontSize: Double
    var lineHeight: Double
    var ligatures: Bool

    // Selection / cursor (mirrored from editor engine)
    var selectedRange: NSRange = NSRange(location: 0, length: 0)

    // Bookmarks: digit (0–9) → cursor location in the document.
    var bookmarks: [Int: Int] = [:]
    /// Fold Selection ranges (the body lines that collapse). Language
    /// fold discovery doesn't know about these — the engine draws an
    /// indicator at the header line above each. In-memory only.
    var userFoldedBodyRanges: Set<ClosedRange<Int>> = []

    /// Cursor jumps from gotos / find / bookmarks — Back/Forward
    /// navigate the history.
    var positionHistory = PositionHistory()

    weak var textView: (any EditorActions)?

    /// The loading-overlay Cancel button cancels this; the Task
    /// clears it in its `defer`.
    var loadTask: Task<Void, Never>?

    /// Reset every keystroke so the disk write only fires after the
    /// user pauses.
    var autoSaveTask: Task<Void, Never>?

    /// Debounced re-highlight for live spell check. The engine is a
    /// UIScrollView + custom UITextInput, so it doesn't draw native
    /// squiggles — we paint red misspelling highlights ourselves
    /// after typing stops.
    var liveSpellTask: Task<Void, Never>?

    /// **Important:** EditorView must assign these with weak captures
    /// — closures stored on `self` that capture `self` strongly are
    /// a classic ARC cycle.
    var setText: ((String) -> Void)?
    var reinterpretWithEncoding: ((FileEncoding) -> Void)?

    init() {
        let d = UserDefaults.standard
        self.languageIdentifier            = d.string(forKey: AppPreferenceKey.defaultLanguage)
                                                .flatMap(LanguageIdentifier.init(rawValue:)) ?? .plain
        self.themeName                     = AppThemeName(stored: d.string(forKey: AppPreferenceKey.themeName))

        self.showLineNumbers               = d.bool(forKey: AppPreferenceKey.showLineNumbers)
        self.wrapLines                     = d.bool(forKey: AppPreferenceKey.wrapLines)
        self.highlightCurrentLine          = d.bool(forKey: AppPreferenceKey.highlightCurrentLine)
        self.highlightMatchingBrackets     = d.bool(forKey: AppPreferenceKey.highlightMatchingBrackets)
        self.showPageGuide                 = d.bool(forKey: AppPreferenceKey.showPageGuide)
        self.pageGuideColumn               = d.integer(forKey: AppPreferenceKey.pageGuideColumn)
        self.showChangeHistoryGutter       = d.bool(forKey: AppPreferenceKey.showChangeHistoryGutter)
        self.overscroll                    = d.bool(forKey: AppPreferenceKey.overscroll)
        self.showStatusBar                 = d.bool(forKey: AppPreferenceKey.showStatusBar)
        self.showToolbar                   = d.bool(forKey: AppPreferenceKey.showToolbar)
        self.liveMatchHighlight            = d.bool(forKey: AppPreferenceKey.liveMatchHighlight)

        self.showInvisibles                = d.bool(forKey: AppPreferenceKey.showInvisibles)
        self.showInvisibleSpace            = d.bool(forKey: AppPreferenceKey.showInvisibleSpace)
        self.showInvisibleTab              = d.bool(forKey: AppPreferenceKey.showInvisibleTab)
        self.showInvisibleNewline          = d.bool(forKey: AppPreferenceKey.showInvisibleNewline)
        self.showInvisibleNonBreakingSpace = d.bool(forKey: AppPreferenceKey.showInvisibleNonBreakingSpace)

        self.statusShowsLineCol            = d.bool(forKey: AppPreferenceKey.statusShowsLineCol)
        self.statusShowsCharCount          = d.bool(forKey: AppPreferenceKey.statusShowsCharCount)
        self.statusShowsLineCount          = d.bool(forKey: AppPreferenceKey.statusShowsLineCount)

        self.usesTabs                      = d.bool(forKey: AppPreferenceKey.usesTabs)
        self.indentWidth                   = d.integer(forKey: AppPreferenceKey.indentWidth)

        self.insertCharacterPairs          = d.bool(forKey: AppPreferenceKey.insertCharacterPairs)
        self.autoCorrect                   = d.bool(forKey: AppPreferenceKey.autoCorrect)
        self.autoCapitalize                = d.bool(forKey: AppPreferenceKey.autoCapitalize)
        self.smartQuotes                   = d.bool(forKey: AppPreferenceKey.smartQuotes)
        self.spellCheck                    = d.bool(forKey: AppPreferenceKey.spellCheck)
        self.autoLinkDetection             = d.bool(forKey: AppPreferenceKey.autoLinkDetection)

        self.font                          = EditorFont(stored: d.string(forKey: AppPreferenceKey.fontName))
        let storedFontSize                 = d.double(forKey: AppPreferenceKey.fontSize)
        self.fontSize                      = storedFontSize > 0 ? storedFontSize : 14
        let storedLineHeight               = d.double(forKey: AppPreferenceKey.lineHeight)
        self.lineHeight                    = storedLineHeight > 0 ? storedLineHeight : 1.2
        self.ligatures                     = d.bool(forKey: AppPreferenceKey.ligatures)

        // Seed-only — Settings changes propagate via EditorView's
        // `@AppStorage` + `.onChange`. A NotificationCenter observer
        // here would fire once per open tab on every UserDefaults
        // write; inactive tabs catch up on their next body eval.
    }
}

enum SplitOrientation {
    case horizontal
    case vertical
}
