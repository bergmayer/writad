import SwiftUI

/// Mirrors UserDefaults values into the live `EditorState`.
/// `EditorState` seeds these once at init, so without this bridge a
/// Settings toggle wouldn't reach a long-lived tab until the tab was
/// closed and reopened — the bug that kept live spell-check
/// highlights invisible after toggling the pref on.
///
/// Split across four modifiers — typing helpers, appearance,
/// invisibles, and indentation — to keep each `.onChange` chain
/// short enough for the SwiftUI type checker to type in reasonable
/// time. `EditorPrefSync` is the umbrella the body applies; it
/// chains the others inside its own body so the outer view's
/// modifier list stays small.
struct EditorPrefSync: ViewModifier {
    let state: EditorState

    func body(content: Content) -> some View {
        content
            .modifier(TypingPrefSync(state: state))
            .modifier(AppearancePrefSync(state: state))
            .modifier(InvisiblesPrefSync(state: state))
            .modifier(IndentationPrefSync(state: state))
    }
}

private struct TypingPrefSync: ViewModifier {
    let state: EditorState
    @AppStorage(AppPreferenceKey.spellCheck) private var spellCheckPref: Bool = false
    @AppStorage(AppPreferenceKey.autoCorrect) private var autoCorrectPref: Bool = false
    @AppStorage(AppPreferenceKey.autoCapitalize) private var autoCapitalizePref: Bool = false
    @AppStorage(AppPreferenceKey.smartQuotes) private var smartQuotesPref: Bool = false
    @AppStorage(AppPreferenceKey.autoLinkDetection) private var autoLinkDetectionPref: Bool = false
    @AppStorage(AppPreferenceKey.overscroll) private var overscrollPref: Bool = true

    func body(content: Content) -> some View {
        content
            .onChange(of: spellCheckPref) { _, v in state.spellCheck = v }
            .onChange(of: autoCorrectPref) { _, v in state.autoCorrect = v }
            .onChange(of: autoCapitalizePref) { _, v in state.autoCapitalize = v }
            .onChange(of: smartQuotesPref) { _, v in state.smartQuotes = v }
            .onChange(of: autoLinkDetectionPref) { _, v in state.autoLinkDetection = v }
            .onChange(of: overscrollPref) { _, v in state.overscroll = v }
            // Seed on appear too — the @AppStorage value beats the
            // state's init-time snapshot if Settings changed before
            // this tab had a chance to mount.
            .onAppear {
                state.spellCheck = spellCheckPref
                state.autoCorrect = autoCorrectPref
                state.autoCapitalize = autoCapitalizePref
                state.smartQuotes = smartQuotesPref
                state.autoLinkDetection = autoLinkDetectionPref
                state.overscroll = overscrollPref
            }
    }
}

/// Visual chrome prefs — line numbers, wrap, page guide, line height,
/// ligatures, highlight rules, change-history gutter, status bar.
/// Toggling any of these in Settings used to require closing and
/// reopening every tab.
private struct AppearancePrefSync: ViewModifier {
    let state: EditorState
    @AppStorage(AppPreferenceKey.showLineNumbers) private var showLineNumbersPref: Bool = true
    @AppStorage(AppPreferenceKey.wrapLines) private var wrapLinesPref: Bool = true
    @AppStorage(AppPreferenceKey.highlightCurrentLine) private var highlightCurrentLinePref: Bool = true
    @AppStorage(AppPreferenceKey.highlightMatchingBrackets) private var highlightMatchingBracketsPref: Bool = true
    @AppStorage(AppPreferenceKey.showPageGuide) private var showPageGuidePref: Bool = false
    @AppStorage(AppPreferenceKey.pageGuideColumn) private var pageGuideColumnPref: Int = 80
    @AppStorage(AppPreferenceKey.lineHeight) private var lineHeightPref: Double = 1.2
    @AppStorage(AppPreferenceKey.ligatures) private var ligaturesPref: Bool = false
    @AppStorage(AppPreferenceKey.showChangeHistoryGutter) private var showChangeHistoryGutterPref: Bool = false
    @AppStorage(AppPreferenceKey.showStatusBar) private var showStatusBarPref: Bool = true
    @AppStorage(AppPreferenceKey.liveMatchHighlight) private var liveMatchHighlightPref: Bool = true

    func body(content: Content) -> some View {
        content
            .onChange(of: showLineNumbersPref) { _, v in state.showLineNumbers = v }
            .onChange(of: wrapLinesPref) { _, v in state.wrapLines = v }
            .onChange(of: highlightCurrentLinePref) { _, v in state.highlightCurrentLine = v }
            .onChange(of: highlightMatchingBracketsPref) { _, v in state.highlightMatchingBrackets = v }
            .onChange(of: showPageGuidePref) { _, v in state.showPageGuide = v }
            .onChange(of: pageGuideColumnPref) { _, v in state.pageGuideColumn = v }
            .onChange(of: lineHeightPref) { _, v in state.lineHeight = v }
            .onChange(of: ligaturesPref) { _, v in state.ligatures = v }
            .onChange(of: showChangeHistoryGutterPref) { _, v in state.showChangeHistoryGutter = v }
            .onChange(of: showStatusBarPref) { _, v in state.showStatusBar = v }
            .onChange(of: liveMatchHighlightPref) { _, v in state.liveMatchHighlight = v }
    }
}

/// Invisibles + the per-kind toggles + the status-bar field
/// selection. Grouped together because users typically flip the
/// master `showInvisibles` toggle and the per-kind options as one
/// audit pass.
private struct InvisiblesPrefSync: ViewModifier {
    let state: EditorState
    @AppStorage(AppPreferenceKey.showInvisibles) private var showInvisiblesPref: Bool = false
    @AppStorage(AppPreferenceKey.showInvisibleSpace) private var showInvisibleSpacePref: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleTab) private var showInvisibleTabPref: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleNewline) private var showInvisibleNewlinePref: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleNonBreakingSpace) private var showInvisibleNBSPPref: Bool = true
    @AppStorage(AppPreferenceKey.statusShowsLineCol) private var statusShowsLineColPref: Bool = true
    @AppStorage(AppPreferenceKey.statusShowsCharCount) private var statusShowsCharCountPref: Bool = true
    @AppStorage(AppPreferenceKey.statusShowsLineCount) private var statusShowsLineCountPref: Bool = true

    func body(content: Content) -> some View {
        content
            .onChange(of: showInvisiblesPref) { _, v in state.showInvisibles = v }
            .onChange(of: showInvisibleSpacePref) { _, v in state.showInvisibleSpace = v }
            .onChange(of: showInvisibleTabPref) { _, v in state.showInvisibleTab = v }
            .onChange(of: showInvisibleNewlinePref) { _, v in state.showInvisibleNewline = v }
            .onChange(of: showInvisibleNBSPPref) { _, v in state.showInvisibleNonBreakingSpace = v }
            .onChange(of: statusShowsLineColPref) { _, v in state.statusShowsLineCol = v }
            .onChange(of: statusShowsCharCountPref) { _, v in state.statusShowsCharCount = v }
            .onChange(of: statusShowsLineCountPref) { _, v in state.statusShowsLineCount = v }
    }
}

/// Indentation and character-pair behaviour. Affects every keystroke
/// after the user toggles it, so syncing matters for in-session
/// changes.
private struct IndentationPrefSync: ViewModifier {
    let state: EditorState
    @AppStorage(AppPreferenceKey.usesTabs) private var usesTabsPref: Bool = false
    @AppStorage(AppPreferenceKey.indentWidth) private var indentWidthPref: Int = 4
    @AppStorage(AppPreferenceKey.insertCharacterPairs) private var insertCharacterPairsPref: Bool = true

    func body(content: Content) -> some View {
        content
            .onChange(of: usesTabsPref) { _, v in state.usesTabs = v }
            .onChange(of: indentWidthPref) { _, v in state.indentWidth = v }
            .onChange(of: insertCharacterPairsPref) { _, v in state.insertCharacterPairs = v }
    }
}
