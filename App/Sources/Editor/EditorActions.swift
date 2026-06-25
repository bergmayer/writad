import Foundation

/// Editor capability protocols.
///
/// Split by responsibility so callers can depend on the slice they need
/// instead of an everything-bag — and so a future stub for tests has a
/// smaller surface to fake. The composite `EditorActions` re-exports them
/// for the cases (mainly the engine adapter) that actually conform to
/// everything.

// MARK: - Core read/write

@MainActor
protocol TextAccess: AnyObject {
    var text: String { get set }
    var selectedRange: NSRange { get }
    func text(in range: NSRange) -> String?
    func replace(_ range: NSRange, withText text: String)
}

// MARK: - Focus

@MainActor
protocol EditorFocusing: AnyObject {
    func focusForEditing()
}

// MARK: - Selection / scrolling

@MainActor
protocol Selecting: AnyObject {
    func selectAll()
    func selectCurrentWord()
    func selectCurrentLine()
    func setSelection(_ range: NSRange)
    func scrollSelectionToVisible()
}

// MARK: - Find

@MainActor
protocol Finding: AnyObject {
    func presentFindNavigator()
    func presentFindAndReplaceNavigator()
    func findNext()
    func findPrevious()
    func findNextOccurrenceOfSelection()
    func findPreviousOccurrenceOfSelection()
    func useSelectionForFind()
}

// MARK: - Line ops

@MainActor
protocol LineOps: AnyObject {
    func shiftSelectionLeft()
    func shiftSelectionRight()
    func moveSelectedLinesUp()
    func moveSelectedLinesDown()
    func goToLine(_ line: Int)
    func duplicateCurrentLine()
    func deleteCurrentLines()
}

// MARK: - Cursor / character ops

@MainActor
protocol CursorEdits: AnyObject {
    func smartMoveToLineStart()
    func transposeCharacters()
    func deleteToEndOfLine()
    func deleteWordBackward()
    func deleteWordForward()
    func joinLines()
}

// MARK: - Spell check

@MainActor
protocol SpellCheck: AnyObject {
    /// Run UITextChecker across the buffer and jump the cursor to the
    /// next misspelled word after the current selection. No effect if
    /// nothing's misspelled.
    func jumpToNextMisspelling()
    /// Add the word at the current selection (or surrounding word, if
    /// the selection is empty) to UITextChecker's learned dictionary
    /// for the lifetime of the app.
    func learnSelectedWord()
    /// Mark the selected/surrounding word as ignored for this document
    /// — UITextChecker won't flag it again in this session.
    func ignoreSelectedWord()
    /// One-shot pass: walk the whole buffer with UITextChecker (en_US)
    /// and paint a red highlight over every misspelled word. Works
    /// regardless of the per-tab spell-check preference, so the user
    /// can audit a document even with the live checker turned off.
    /// Subsequent calls replace the previous highlights — no need to
    /// clear first.
    func highlightAllMisspellings()
    /// Drop every highlight painted by `highlightAllMisspellings()`.
    /// Leaves other highlights (bracket match, live-match, find
    /// results) intact.
    func clearMisspellingHighlights()
    /// Find the next misspelling at or after `location`, wrapping
    /// once. Drives the walk-through spell-check sheet — returns the
    /// flagged word, its range, and ranked suggestions. `nil` when
    /// the buffer has nothing to flag.
    func nextMisspelling(from location: Int) -> (range: NSRange, word: String, suggestions: [String])?
    /// Learn a word by string (the walk-through sheet shows the word
    /// directly; cursor selection isn't necessarily on it).
    func learnWord(_ word: String)
    /// Ignore a word by string for the rest of the session.
    func ignoreWord(_ word: String)
    /// Returns the range of a currently-painted misspelling highlight
    /// containing `location`, if any. Drives tap-to-suggest — when
    /// the cursor lands inside one of these (via tap), the editor
    /// opens the walk-through sheet seeded at the start of the word.
    func misspellingRange(at location: Int) -> NSRange?
}

// MARK: - Folding

@MainActor
protocol FoldingSupport: AnyObject {
    /// Toggle the visibility of `range`. The app layer is responsible for
    /// computing the range via `FoldDiscovery` against the current
    /// language. The engine just hides / shows the lines.
    func setLinesFolded(_ folded: Bool, range: ClosedRange<Int>)
    /// Unfold every currently-folded range.
    func unfoldAll()
    /// 0-based indices of every currently-hidden line.
    var foldedLineIndices: [Int] { get }
    /// Apply a list of foldable ranges (used to restore persisted state on
    /// document open).
    func applyFoldRanges(_ ranges: [ClosedRange<Int>])
}

/// Read-only window over the engine's fold state so the app layer can
/// query without importing EditorEngine.
typealias EngineFoldStateReadable = FoldingSupport

// MARK: - Brackets

@MainActor
protocol BracketSupport: AnyObject {
    func goToMatchingBracket()
    /// Compute and apply a single-pair bracket-match highlight based on
    /// the current cursor position. Called by the coordinator on every
    /// selection change.
    func refreshBracketMatchHighlight()
    /// Remove any active bracket-match highlight without recomputing.
    func clearBracketMatchHighlight()
}

// MARK: - Line-ending application

@MainActor
protocol LineEndingApplying: AnyObject {
    /// Apply a line-ending style. Raw value is the line-ending character
    /// (`\n`, `\r`, or `\r\n`). Unknown values fall through to `\n`.
    func applyLineEndingRawValue(_ rawValue: Character)
}

// MARK: - Composite

@MainActor
protocol EditorActions: TextAccess,
                       EditorFocusing,
                       Selecting,
                       Finding,
                       LineOps,
                       CursorEdits,
                       SpellCheck,
                       FoldingSupport,
                       BracketSupport,
                       LineEndingApplying {}
