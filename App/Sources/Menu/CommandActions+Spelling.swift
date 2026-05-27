import Foundation

extension CommandActions {

    // MARK: - Spell check

    static func jumpToNextMisspelling() {
        actions?.jumpToNextMisspelling()
    }
    static func learnSelectedWord() {
        actions?.learnSelectedWord()
    }
    static func ignoreSelectedWord() {
        actions?.ignoreSelectedWord()
    }
    static func toggleSpellCheckLive() {
        guard let state = Self.state else { return }
        state.spellCheck.toggle()
        UserDefaults.standard.set(state.spellCheck, forKey: AppPreferenceKey.spellCheck)
    }
    /// One-shot spell-check pass that paints red highlights over
    /// every misspelled word. Works regardless of the per-tab
    /// `spellCheck` preference, so the user can audit a document
    /// even when the live checker is off.
    static func highlightAllMisspellings() {
        actions?.highlightAllMisspellings()
    }
    /// Drop the red marks added by `highlightAllMisspellings`.
    static func clearMisspellingHighlights() {
        actions?.clearMisspellingHighlights()
    }
    /// Walk-through spell check (Word-style). Always available — the
    /// sheet uses UITextChecker directly, no dependency on the
    /// per-tab live-spell-check toggle.
    static func presentSpellCheckSheet() {
        presentSheet(.spellCheck)
    }
}
