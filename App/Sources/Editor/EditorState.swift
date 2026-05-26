import SwiftUI
import Combine
import FileEncoding
import LineEnding

/// Observable per-document editor state. Backs both the SwiftUI host
/// (EditorView) and the menu bar (via FocusedValues).
///
/// New documents seed their values from `AppPreferences` (UserDefaults).
@MainActor
@Observable
final class EditorState {

    // Document
    var text: String = ""
    var fileEncoding: FileEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var fileURL: URL?
    /// Snapshot of the buffer at last load/save. Drives the change-
    /// history gutter — per-line comparison against this baseline
    /// renders green (added), yellow (modified) and red (deleted)
    /// bars in the gutter. Reset on every load/save/explicit revert.
    var savedBaselineText: String = ""
    /// Per-window: is the leading navigation sidebar open? Triggered
    /// by the sidebar button in the WindowToolbar's leading area.
    /// Sidebar shows the document outline (markdown headings + fold-
    /// detected symbols) for quick navigation.
    var sidebarOpen: Bool = false
    /// Per-window: is the trailing file-information inspector open?
    /// Lives on state (rather than @State on EditorView) so menu bar
    /// commands and the status-bar ⓘ toggle both write to the same
    /// source of truth.
    var inspectorOpen: Bool = false
    /// Per-tab split view: when true, the editor pane shows two
    /// text views over the SAME document text. Each pane has its
    /// own cursor / scroll / selection but writes flow back to the
    /// shared `PlainTextDocument` so edits stay in lockstep.
    var splitOpen: Bool = false
    /// Horizontal = panes are left/right (HStack); vertical = panes
    /// are top/bottom (VStack). The user toggles this via
    /// View ▸ Split ▸ Orientation; the divider drag axis swaps
    /// accordingly.
    var splitOrientation: SplitOrientation = .horizontal
    /// Fraction of the editor pane given to the leading (left or
    /// top) pane (0...1). 0.5 == 50/50.
    var splitFraction: CGFloat = 0.5
    /// Back-reference to the OTHER split pane's state, set when
    /// split view opens. Lets a pane's text-view coordinator find
    /// its sibling's text view and propagate per-keystroke edits
    /// directly across the pair (without going through a shared
    /// observable). Cleared on split-view close and on tab close.
    /// Weak to avoid the two states from retaining each other.
    weak var siblingState: EditorState?
    var languageIdentifier: LanguageIdentifier
    /// `true` when the open file exceeded the user's "rich editing" size
    /// limit (`SyntaxLimit`) and the editor opened it in plain-text mode
    /// to keep typing responsive. Skips tree-sitter, fold discovery, and
    /// the markdown inline decorator. Untitled and small files stay
    /// `false`.
    var isLargeFile: Bool = false

    // View settings
    var showLineNumbers: Bool
    var wrapLines: Bool
    var highlightCurrentLine: Bool
    var highlightMatchingBrackets: Bool
    var showPageGuide: Bool
    var pageGuideColumn: Int
    /// Per-window flag for the gutter's change-history bars (added /
    /// modified / deleted vs. the baseline snapshot). Off by default —
    /// the per-line diff is cheap on small files but the overlay's
    /// `caretRect` lookups + bar layout grow with line count, so the
    /// runtime gate also short-circuits past
    /// `Timing.changeHistoryGutterByteLimit`.
    var showChangeHistoryGutter: Bool
    var themeName: AppThemeName
    /// When non-nil, this scene/tab has its own theme that wins over
    /// the global Settings theme — set via the (i) info inspector's
    /// "Window Theme" picker. Nil means "inherit global"; updating
    /// global Settings then propagates to `themeName` automatically
    /// (see the UserDefaults observer wired in `init`). Per-state,
    /// not persisted across app launches — survives only as long as
    /// the tab does.
    var themeOverride: AppThemeName?
    /// Per-window font face override. nil → inherit global Settings
    /// font; set → the picked face wins for this tab even when
    /// Settings ▸ Editor ▸ Font changes globally.
    var fontOverride: EditorFont?
    /// Per-window font size override. nil → inherit global; set →
    /// wins for this tab.
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
    var autoIndent: Bool

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
    /// Number of times the current selection appears in the document
    /// (when live match highlight is on). 0 when nothing's highlighted.
    var liveMatchCount: Int = 0
    var font: EditorFont
    var fontSize: Double
    var lineHeight: Double
    var ligatures: Bool

    // Selection / cursor (mirrored from editor engine)
    var selectedRange: NSRange = NSRange(location: 0, length: 0)

    // Bookmarks: digit (0–9) → cursor location in the document.
    var bookmarks: [Int: Int] = [:]
    /// Ad-hoc fold ranges declared by **Fold Selection** that aren't
    /// part of the language's tree-sitter / Markdown header discovery.
    /// Stored as body ranges (the lines that collapse); the engine
    /// draws an indicator at the line immediately above each, in the
    /// gutter, themed the same as language folds. Persists for the
    /// document's session — closing the tab clears it, same as cursor
    /// position and bookmarks.
    var userFoldedBodyRanges: Set<ClosedRange<Int>> = []

    // Position history — see PositionHistory. Records cursor jumps from
    // manual gotos, find results, bookmark jumps. Back/Forward navigate it.
    var positionHistory = PositionHistory()

    // Editor handle. Set by the UIViewRepresentable so menu actions can target it.
    weak var textView: (any EditorActions)?

    /// Active file-load `Task`. Held so the loading overlay's Cancel
    /// button can interrupt a slow read from a File Provider. Cleared
    /// in the task's own `defer` when it exits.
    var loadTask: Task<Void, Never>?

    /// Pending debounced auto-save. Cancelled and rescheduled on every
    /// keystroke so we only commit to disk after the user pauses.
    var autoSaveTask: Task<Void, Never>?

    /// Writes back to the document so menu actions that replace the whole
    /// text (sort, trim, etc.) persist their changes.
    ///
    /// **Important:** EditorView must assign this with `[weak self]` (or
    /// equivalent) capture — closures stored on `self` that capture `self`
    /// strongly are a classic ARC retain cycle.
    var setText: ((String) -> Void)?

    /// Re-decodes the original file data with a new encoding. Set by
    /// EditorView when the document has the raw bytes available. Same
    /// capture-weakly rule as `setText`.
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
        self.autoIndent                    = d.bool(forKey: AppPreferenceKey.autoIndent)

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

        // Initial seed is enough — Settings ▸ Appearance + Font
        // changes propagate via `EditorView.onChange(of: themeNamePref
        // / fontSizePref / fontNamePref)` at the view layer, gated on
        // the per-window override flags. Adding a per-state
        // NotificationCenter observer here would fire N times for
        // every UserDefaults write (one per open tab), and SwiftUI's
        // @AppStorage + .onChange does the same work natively for
        // the visible tab. Inactive tabs pick up the latest values
        // when their body next evaluates on activation.
    }
}

/// Layout axis for the per-tab split editor. Horizontal = left/right
/// (HStack); vertical = top/bottom (VStack). Toggled via
/// View ▸ Toggle Split Orientation when the split is open.
enum SplitOrientation {
    case horizontal
    case vertical
}
