import SwiftUI
import UIKit
import EditorEngine
import AyyyySyntax

/// SwiftUI wrapper around `EditorEngine.TextView`.
///
/// Architecture note — do not regress: the engine's `TextView` IS
/// the buffer's source of truth. Per-keystroke text never flows back
/// into SwiftUI's observation graph. The previous `Binding<String>`
/// design copied the full buffer through `document.text` →
/// `state.text` on every keystroke and froze editing on multi-MB
/// files. The coordinator instead bumps a tiny
/// `document.bufferRevision` counter; status bar / markdown preview
/// pull a debounced snapshot. `isDirty` is set up-front via
/// `shouldChangeTextIn` so the flag is range-aware.
struct EditorTextView: UIViewRepresentable {

    let document: PlainTextDocument
    let state: EditorState
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    func makeUIView(context: Context) -> EditorEngine.TextView {
        let textView = EditorEngine.TextView()
        textView.editorDelegate = context.coordinator
        let initialThemeKey = Coordinator.ThemeCacheKey(
            name: state.themeName,
            font: state.font,
            fontSize: currentFontSize(),
            style: resolvedStyle == .dark ? .dark : .light
        )
        let initialTheme = AppTheme.current(
            initialThemeKey.name,
            font: initialThemeKey.font,
            fontSize: initialThemeKey.fontSize,
            userInterfaceStyle: initialThemeKey.style
        )
        textView.theme = initialTheme
        // EditorEngine.TextView hardcodes white as its scroll-view
        // background, so DarkTheme (textColor = .white) painted
        // white-on-white — blank by design. Shipping themes
        // conform to `EditorBackgroundProviding` for their own surface.
        textView.backgroundColor = (initialTheme as? EditorBackgroundProviding)?
            .editorBackgroundColor ?? .systemBackground
        context.coordinator.themeCacheKey = initialThemeKey
        textView.text = document.text
        context.coordinator.lastPushedDocumentText = document.text
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .always
        // Use the keyboard's own shortcut bar instead of an
        // inputAccessoryView — the latter sticks to the text view's
        // bottom and overlaps our status bar in Stage Manager / Slide
        // Over.
        KeyboardAccessoryBar.install(on: textView)
        textView.onFoldToggle = { [weak textView] body in
            guard let textView else { return }
            let isFolded = body.contains { textView.foldedLineIndices.contains($0) }
            textView.setLinesFolded(!isFolded, range: body)
        }
        // No-op on large files — the decorator walks every line per
        // render and would lag a multi-MB document. Weak capture
        // avoids a state → textView → closure → state cycle.
        MarkdownInlineHighlighter.install(on: textView) { [weak state] in
            guard let state, !state.isLargeFile else { return .plain }
            return state.languageIdentifier
        }

        applyTypingPreferences(to: textView)
        applyViewSettings(to: textView)
        applyOverscroll(to: textView)
        applyLanguage(to: textView, identifier: state.languageIdentifier, coordinator: context.coordinator)
        applyIndentStrategy(to: textView)
        applyCharacterPairs(to: textView)

        // Subviews of the engine's scroll view so they scroll with
        // content. Each rebuilds in its own `layoutSubviews`; the
        // coordinator pushes fresh data through `updateUIView`.
        let bookmarks = BookmarkGutterOverlay(host: textView)
        textView.addSubview(bookmarks)
        context.coordinator.bookmarkOverlay = bookmarks

        let matchMarks = MatchScrollMarksOverlay(host: textView)
        textView.addSubview(matchMarks)
        context.coordinator.matchScrollOverlay = matchMarks

        // Green / yellow / red bars where the buffer diverges from
        // the last saved (or loaded) snapshot.
        let history = ChangeHistoryGutterOverlay(host: textView)
        textView.addSubview(history)
        context.coordinator.changeHistoryOverlay = history

        // Fold Selection markers used to live in a sibling overlay,
        // but the engine's `bringSubviewToFront(gutterContainerView)`
        // covered them. Workaround: synthesize a `FoldableRegion` for
        // each `userFoldedBodyRanges` entry in `refreshFoldableRegions`
        // — the engine then paints its native, theme-aware chevron
        // inside the gutter.

        state.textView = textView
        return textView
    }

    func updateUIView(_ textView: EditorEngine.TextView, context: Context) {
        // Only push `document.text` into the text view when an
        // EXTERNAL writer changed it (load / Revert / restore /
        // Save-As re-decode). `lastPushedDocumentText` is the cache
        // that lets us skip the O(n) `!=` compare on every render —
        // that compare was the typing freeze on big files.
        if context.coordinator.lastPushedDocumentText != document.text {
            context.coordinator.lastPushedDocumentText = document.text
            if textView.text != document.text {
                textView.text = document.text
            }
        }
        applyTypingPreferences(to: textView)
        applyViewSettings(to: textView)
        applyOverscroll(to: textView)
        let themeKey = Coordinator.ThemeCacheKey(
            name: state.themeName,
            font: state.font,
            fontSize: currentFontSize(),
            style: resolvedStyle == .dark ? .dark : .light
        )
        if context.coordinator.themeCacheKey != themeKey {
            let resolved = AppTheme.current(
                themeKey.name,
                font: themeKey.font,
                fontSize: themeKey.fontSize,
                userInterfaceStyle: themeKey.style
            )
            textView.theme = resolved
            textView.backgroundColor = (resolved as? EditorBackgroundProviding)?
                .editorBackgroundColor ?? .systemBackground
            context.coordinator.themeCacheKey = themeKey
        }
        applyIndentStrategy(to: textView)
        applyCharacterPairs(to: textView)
        if context.coordinator.currentLanguageIdentifier != state.languageIdentifier {
            applyLanguage(to: textView, identifier: state.languageIdentifier, coordinator: context.coordinator)
        }
        context.coordinator.refreshFoldableRegions(textView)
        context.coordinator.bookmarkOverlay?.bookmarks = state.bookmarks
        // Change-history gutter is gated three ways:
        //  - user preference (off by default)
        //  - byte ceiling (`changeHistoryGutterByteLimit`) — per-line
        //    diff + caretRect lookups become perceptible after big
        //    deletes on 100kB+ files
        //  - cache short-circuit to skip re-splitting when sources
        //    didn't change between renders
        let coord = context.coordinator
        let prefOn = state.showChangeHistoryGutter
        let withinSize = textView.text.utf16.count <= Timing.changeHistoryGutterByteLimit
        let shouldRender = prefOn && !state.isLargeFile && withinSize
        if let overlay = coord.changeHistoryOverlay {
            if !shouldRender {
                // Drop stale bars from before the pref flipped off
                // or a paste pushed the file past the ceiling. Reset
                // caches so re-enabling renders fresh.
                coord.overlayRefreshTask?.cancel()
                if !overlay.baseline.isEmpty || !overlay.current.isEmpty {
                    overlay.baseline = []
                    overlay.current = []
                    coord.changeHistoryBaselineCache = nil
                    coord.changeHistoryCurrentCache = nil
                }
            } else {
                let baselineText = state.savedBaselineText
                let currentText = textView.text
                if coord.changeHistoryBaselineCache != baselineText ||
                   coord.changeHistoryCurrentCache != currentText {
                    coord.overlayRefreshTask?.cancel()
                    coord.overlayRefreshTask = Task { @MainActor [weak coord, weak overlay] in
                        try? await Task.sleep(for: Timing.changeHistoryOverlayDebounce)
                        if Task.isCancelled { return }
                        guard let coord, let overlay else { return }
                        if coord.changeHistoryBaselineCache != baselineText {
                            coord.changeHistoryBaselineCache = baselineText
                            overlay.baseline = baselineText.components(separatedBy: "\n")
                        }
                        if coord.changeHistoryCurrentCache != currentText {
                            coord.changeHistoryCurrentCache = currentText
                            overlay.current = currentText.components(separatedBy: "\n")
                        }
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, state: state)
    }

    // MARK: - Settings

    private func applyTypingPreferences(to textView: EditorEngine.TextView) {
        textView.autocorrectionType = state.autoCorrect ? .yes : .no
        textView.autocapitalizationType = state.autoCapitalize ? .sentences : .none
        textView.smartQuotesType = state.smartQuotes ? .yes : .no
        textView.smartDashesType = state.smartQuotes ? .yes : .no
        textView.spellCheckingType = state.spellCheck ? .yes : .no
        // `autoLinkDetection` is stored but not wired —
        // EditorEngine.TextView doesn't expose dataDetectorTypes.
        textView.keyboardType = .asciiCapable
    }

    private func applyViewSettings(to textView: EditorEngine.TextView) {
        textView.showLineNumbers = state.showLineNumbers
        textView.isLineWrappingEnabled = state.wrapLines

        // Invisibles — master toggle gates the per-kind choices.
        let inv = state.showInvisibles
        textView.showTabs              = inv && state.showInvisibleTab
        textView.showSpaces            = inv && state.showInvisibleSpace
        textView.showLineBreaks        = inv && state.showInvisibleNewline
        textView.showSoftLineBreaks    = inv && state.showInvisibleNewline
        textView.showNonBreakingSpaces = inv && state.showInvisibleNonBreakingSpace

        textView.showPageGuide   = state.showPageGuide
        textView.pageGuideColumn = state.pageGuideColumn

        textView.lineHeightMultiplier  = CGFloat(state.lineHeight)
        textView.lineSelectionDisplayType = state.highlightCurrentLine ? .line : .disabled

        // Cap soft-wrap at the page-guide column by pushing the
        // text container's right inset to `width − (column ×
        // char-advance)`. No-op when wrapping is off or the window is
        // already narrower than the column.
        applyPageGuideWrap(to: textView)
    }

    private func applyPageGuideWrap(to textView: EditorEngine.TextView) {
        guard state.wrapLines, state.pageGuideColumn > 0 else {
            if textView.textContainerInset.right != 0 {
                var inset = textView.textContainerInset
                inset.right = 0
                textView.textContainerInset = inset
            }
            return
        }
        let font = state.font.uiFont(size: CGFloat(state.fontSize))
        // Width of a space probes the monospaced advance; `UIFont
        // .advance(of:)` would require attributing a string.
        let probe = " " as NSString
        let charWidth = probe.size(withAttributes: [.font: font]).width
        guard charWidth > 0 else { return }
        let desiredColumnWidth = CGFloat(state.pageGuideColumn) * charWidth
        // Available width = scroll width − gutter − left inset.
        // Keep `textContainerInset.left` (the gutter-to-body gap)
        // intact and only push the right inset.
        let scrollWidth = textView.frame.width
        let gutterWidth = textView.gutterWidth
        let leftInset = textView.textContainerInset.left
        let available = scrollWidth - gutterWidth - leftInset
        let neededRightInset = max(0, available - desiredColumnWidth)
        if abs(textView.textContainerInset.right - neededRightInset) > 0.5 {
            var inset = textView.textContainerInset
            inset.right = neededRightInset
            textView.textContainerInset = inset
        }
    }

    /// Ten-line scrollable cushion below the last line so the
    /// final line isn't pinned to the bottom of the window. Uses
    /// the current font's line height × multiplier — matches what
    /// the engine actually lays out, not a fixed point value. Set
    /// on `contentInset.bottom` (UIScrollView's standard hook); the
    /// existing keyboard-avoidance code only touches the iOS-managed
    /// `additionalSafeAreaInsets`, so the two don't fight.
    private func applyOverscroll(to textView: EditorEngine.TextView) {
        let font = state.font.uiFont(size: CGFloat(state.fontSize))
        let perLine = font.lineHeight * CGFloat(state.lineHeight)
        let target: CGFloat = state.overscroll ? perLine * 10 : 0
        if abs(textView.contentInset.bottom - target) > 0.5 {
            textView.contentInset.bottom = target
        }
    }

    private func applyIndentStrategy(to textView: EditorEngine.TextView) {
        textView.indentStrategy = state.usesTabs
            ? .tab(length: state.indentWidth)
            : .space(length: state.indentWidth)
    }

    private func applyCharacterPairs(to textView: EditorEngine.TextView) {
        textView.characterPairs = state.insertCharacterPairs ? Self.commonPairs : []
    }

    private func applyLanguage(
        to textView: EditorEngine.TextView,
        identifier: LanguageIdentifier,
        coordinator: Coordinator
    ) {
        coordinator.currentLanguageIdentifier = identifier
        // Large files bypass tree-sitter — the initial parse is O(N)
        // on the engine's pipeline. Plain-text keeps typing snappy.
        if state.isLargeFile {
            textView.setLanguageMode(PlainTextLanguageMode())
            return
        }
        if let language = SyntaxRegistry.language(for: identifier.rawValue) {
            textView.setLanguageMode(TreeSitterLanguageMode(language: language))
        } else {
            textView.setLanguageMode(PlainTextLanguageMode())
        }
    }

    private func currentFontSize() -> CGFloat {
        CGFloat(state.fontSize)
    }

    private static let commonPairs: [BasicCharacterPair] = [
        BasicCharacterPair(leading: "(", trailing: ")"),
        BasicCharacterPair(leading: "[", trailing: "]"),
        BasicCharacterPair(leading: "{", trailing: "}"),
        BasicCharacterPair(leading: "\"", trailing: "\""),
        BasicCharacterPair(leading: "'", trailing: "'"),
        BasicCharacterPair(leading: "`", trailing: "`")
    ]

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency EditorEngine.TextViewDelegate {
        let document: PlainTextDocument
        let state: EditorState
        var currentLanguageIdentifier: LanguageIdentifier?
        /// Last EXTERNAL push of `document.text` (load / revert /
        /// restore). Lets `updateUIView` skip the O(n) `!=` compare
        /// when the engine has already kept the buffer up to date.
        var lastPushedDocumentText: String?
        /// True while applying a sync from the sibling split pane —
        /// short-circuits delegate callbacks so the same edit
        /// doesn't bounce back across the pair.
        var isApplyingSiblingSync: Bool = false
        /// Debounced snapshot back into `state.text` / `document.text`
        /// for eventual-consistency consumers (status counts,
        /// markdown preview).
        var bufferSnapshotTask: Task<Void, Never>?
        /// Cache key for fold discovery; skips the O(N) walk when
        /// nothing relevant has changed. SwiftUI re-evaluates body
        /// on every `@Observable` mutation, so updateUIView fires
        /// constantly even when the buffer hasn't budged.
        private var foldCacheKey: (length: Int, language: LanguageIdentifier, userFolds: String)?
        weak var bookmarkOverlay: BookmarkGutterOverlay?
        weak var changeHistoryOverlay: ChangeHistoryGutterOverlay?
        /// Cached source strings; the debounced refresh skips the
        /// `components(separatedBy:)` split when text hasn't changed.
        var changeHistoryBaselineCache: String?
        var changeHistoryCurrentCache: String?
        /// `updateUIView` fires per body re-eval — i.e. every
        /// keystroke on a big file. Splitting both baseline + buffer
        /// by "\n" on each call is ~22k allocs on Moby Dick. The
        /// debounce coalesces them into one re-split after the user
        /// pauses; diff bars update a beat late, typing stays snappy.
        var overlayRefreshTask: Task<Void, Never>?
        /// `AppTheme.current(...)` returns a fresh reference each
        /// call; the engine's `theme.didSet` uses `!==`. Reassigning
        /// an equivalent theme per render invalidates every line
        /// controller and re-lays the view — visible on large files
        /// as the viewport drifting down a line per update.
        var themeCacheKey: ThemeCacheKey?

        struct ThemeCacheKey: Equatable {
            let name: AppThemeName
            let font: EditorFont
            let fontSize: CGFloat
            let style: UIUserInterfaceStyle
        }

        init(document: PlainTextDocument, state: EditorState) {
            self.document = document
            self.state = state
        }

        func textViewDidChange(_ textView: EditorEngine.TextView) {
            if isApplyingSiblingSync { return }
            // No full buffer flows through — observers react to the
            // counter; ones that need the actual text pull it from
            // the engine on demand.
            document.bufferRevision &+= 1
            scheduleBufferSnapshot(from: textView)
            foldCacheKey = nil
            refreshFoldableRegions(textView)
        }

        /// Eventual-consistency surfaces (status counts, markdown
        /// preview, sheets reading `document.text` on open). Window
        /// matches the change-history overlay so both refresh in
        /// the same render pass.
        private func scheduleBufferSnapshot(from textView: EditorEngine.TextView) {
            bufferSnapshotTask?.cancel()
            bufferSnapshotTask = Task { @MainActor [weak document, weak state, weak self] in
                try? await Task.sleep(for: Timing.changeHistoryOverlayDebounce)
                if Task.isCancelled { return }
                guard let document, let state, let self else { return }
                let snapshot = textView.text
                if document.text != snapshot {
                    document.text = snapshot
                    // Match `lastPushedDocumentText` so the next
                    // updateUIView doesn't bounce this snapshot back.
                    self.lastPushedDocumentText = snapshot
                }
                if state.text != snapshot {
                    state.text = snapshot
                }
            }
        }

        func refreshFoldableRegions(_ textView: EditorEngine.TextView) {
            guard !state.isLargeFile else {
                textView.foldableRegions = []
                return
            }
            let length = (textView.text as NSString).length
            // Includes user-fold fingerprint so a newly-folded
            // selection invalidates the cache — otherwise the ad-hoc
            // fold's chevron only paints after the next edit.
            let userFingerprint = state.userFoldedBodyRanges
                .map { "\($0.lowerBound)-\($0.upperBound)" }
                .sorted()
                .joined(separator: ",")
            let key = (length: length, language: state.languageIdentifier, userFolds: userFingerprint)
            if let cached = foldCacheKey,
               cached.length == key.length,
               cached.language == key.language,
               cached.userFolds == key.userFolds {
                return
            }
            var regions = FoldDiscovery.allFoldableHeaders(
                in: textView.text as NSString,
                language: state.languageIdentifier
            )
            // Fold Selection isn't in language discovery — synthesize
            // a FoldableRegion so the engine paints its native chevron
            // at the header line just above the body.
            for body in state.userFoldedBodyRanges {
                let header = max(0, body.lowerBound - 1)
                // De-dupe in case language discovery already covers
                // the same header (user selected an existing fold's
                // body exactly).
                if regions.contains(where: { $0.headerRow == header }) { continue }
                regions.append(EditorEngine.TextView.FoldableRegion(
                    headerRow: header,
                    bodyRange: body
                ))
            }
            textView.foldableRegions = regions
            foldCacheKey = key
        }

        func textViewDidChangeSelection(_ textView: EditorEngine.TextView) {
            state.selectedRange = textView.selectedRange
            if state.highlightMatchingBrackets {
                textView.refreshBracketMatchHighlight()
            } else {
                textView.clearBracketMatchHighlight()
            }
            refreshLiveMatches(textView)
        }

        /// Namespace so refresh only replaces our highlights, not
        /// bracket-match / find / etc.
        private static let liveMatchIDPrefix = "live-match-"

        /// No-op when pref off, selection empty / single-char, or
        /// the needle crosses a newline.
        func refreshLiveMatches(_ textView: EditorEngine.TextView) {
            let selRange = textView.selectedRange
            let ns = textView.text as NSString
            let cleared = textView.highlightedRanges.filter { !$0.id.hasPrefix(Self.liveMatchIDPrefix) }

            guard state.liveMatchHighlight,
                  selRange.length >= 2,
                  selRange.length < 200,
                  selRange.location + selRange.length <= ns.length else {
                textView.highlightedRanges = cleared
                state.liveMatchCount = 0
                matchScrollOverlay?.matchRanges = []
                return
            }
            let needle = ns.substring(with: selRange)
            // Single-line only — naive multi-line would be slow and
            // confusing.
            if needle.contains("\n") || needle.contains("\r") {
                textView.highlightedRanges = cleared
                state.liveMatchCount = 0
                matchScrollOverlay?.matchRanges = []
                return
            }
            // Non-overlapping matches outside the user's selection.
            var hits: [NSRange] = []
            var searchStart = 0
            while searchStart < ns.length {
                let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
                let r = ns.range(of: needle, options: [], range: searchRange)
                guard r.location != NSNotFound else { break }
                if r.location != selRange.location {
                    hits.append(r)
                }
                searchStart = r.location + max(r.length, 1)
                if hits.count > 2000 { break }  // sanity cap on huge files
            }
            let tint = UIColor.systemYellow.withAlphaComponent(0.35)
            let highlights = hits.enumerated().map { idx, range in
                HighlightedRange(
                    id: "\(Self.liveMatchIDPrefix)\(idx)",
                    range: range,
                    color: tint,
                    cornerRadius: 2
                )
            }
            textView.highlightedRanges = cleared + highlights
            state.liveMatchCount = hits.count
            matchScrollOverlay?.matchRanges = hits
        }

        /// Populated by `refreshLiveMatches`.
        weak var matchScrollOverlay: MatchScrollMarksOverlay?

        /// One delegate, three jobs in order so the engine sees a
        /// consistent answer per edit:
        ///   1. Range-aware dirty flag (cheap; no buffer compare).
        ///   2. Sibling-pane sync — propagate the same
        ///      `(range, replacement)` so both panes stay in step
        ///      without a shared observable. Guarded by
        ///      `isApplyingSiblingSync` against bouncing back.
        ///   3. List-continuation interceptor on Enter. When the
        ///      helper handles the newline we return `false` so the
        ///      engine doesn't also insert a bare `\n` — but jobs
        ///      1 + 2 already fired above.
        func textView(
            _ textView: EditorEngine.TextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if isApplyingSiblingSync { return true }

            // 0. Armed accessory modifier — Control / Command /
            // Option from the accessory bar wins over the literal
            // keystroke. Single-letter ASCII insertions fire the
            // matching command. Shift is read from the case of the
            // incoming letter. The armed flag intentionally stays
            // set after consumption — the user toggles it off by
            // tapping the modifier again (or hits Esc to clear
            // them all), matching the sticky-key behaviour they
            // expect.
            if state.armedAccessoryControl
                || state.armedAccessoryCommand
                || state.armedAccessoryOption,
               text.count == 1,
               let ascii = text.unicodeScalars.first,
               ascii.isASCII {
                if AccessoryKeyboard.handleArmedKey(text, state: state) {
                    return false
                }
            }

            // 1. Dirty flag up front — entry point for "first edit
            // on this doc", no after-the-fact buffer compare needed.
            if !document.isDirty { document.isDirty = true }

            // 2. Sibling sync. Cast the abstract `EditorActions` to
            // the concrete engine view so we can reach the sibling
            // coordinator and arm its recursion guard.
            if state.splitOpen,
               let siblingActions = state.siblingState?.textView,
               let sibling = siblingActions as? EditorEngine.TextView,
               let siblingCoord = sibling.editorDelegate as? Coordinator {
                siblingCoord.isApplyingSiblingSync = true
                sibling.replace(range, withText: text)
                siblingCoord.isApplyingSiblingSync = false
            }

            // 3. List continuation interceptor.
            guard text == "\n",
                  UserDefaults.standard.bool(forKey: AppPreferenceKey.autoContinueLists)
            else { return true }
            switch MarkdownListContinuation.handle(in: textView, replacing: range) {
            case .intercepted: return false
            case .passThrough: return true
            }
        }
    }
}

private struct BasicCharacterPair: EditorEngine.CharacterPair {
    let leading: String
    let trailing: String
}

// MARK: - EditorActions conformance

extension EditorEngine.TextView: EditorActions {

    func presentFindNavigator() {
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func presentFindAndReplaceNavigator() {
        findInteraction?.presentFindNavigator(showingReplace: true)
    }

    func findNext() {
        findInteraction?.findNext()
    }

    func findPrevious() {
        findInteraction?.findPrevious()
    }

    func shiftSelectionLeft() {
        shiftLeft()
    }

    func shiftSelectionRight() {
        shiftRight()
    }

    func selectAll() {
        let length = (text as NSString).length
        selectedRange = NSRange(location: 0, length: length)
    }

    func selectCurrentWord() {
        let nsText = text as NSString
        let location = selectedRange.location
        let length = nsText.length
        guard length > 0 else { return }

        let alnum = CharacterSet.alphanumerics
        var start = min(location, length - 1)
        var end = start

        while start > 0,
              let scalar = nsText.substring(with: NSRange(location: start - 1, length: 1)).unicodeScalars.first,
              alnum.contains(scalar) || scalar == "_" {
            start -= 1
        }
        while end < length,
              let scalar = nsText.substring(with: NSRange(location: end, length: 1)).unicodeScalars.first,
              alnum.contains(scalar) || scalar == "_" {
            end += 1
        }
        if end > start {
            selectedRange = NSRange(location: start, length: end - start)
        }
    }

    func selectCurrentLine() {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        selectedRange = lineRange
    }

    func setSelection(_ range: NSRange) {
        let length = (text as NSString).length
        let clamped = NSRange(
            location: max(0, min(range.location, length)),
            length: max(0, min(range.length, length - max(0, min(range.location, length))))
        )
        selectedRange = clamped
    }

    func useSelectionForFind() {
        guard selectedRange.length > 0 else { return }
        let nsText = text as NSString
        let selected = nsText.substring(with: selectedRange)
        findInteraction?.searchText = selected
    }

    func scrollSelectionToVisible() {
        scrollRangeToVisible(selectedRange)
    }

    func goToLine(_ line: Int) {
        _ = goToLine(line - 1, select: .beginning)
    }

    func duplicateCurrentLine() {
        let range = selectedRange
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: range)
        let lineContent = nsText.substring(with: lineRange)
        let endOfLines = lineRange.location + lineRange.length
        let needsLeadingNewline = (endOfLines == nsText.length) && !lineContent.hasSuffix("\n") && !lineContent.hasSuffix("\r")
        let insertion = needsLeadingNewline ? ("\n" + lineContent) : lineContent
        replace(NSRange(location: endOfLines, length: 0), withText: insertion)
    }

    func deleteCurrentLines() {
        let range = selectedRange
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: range)
        replace(lineRange, withText: "")
    }

    // MARK: - Selection of selection

    func findNextOccurrenceOfSelection() {
        findOccurrenceOfSelection(forward: true)
    }

    func findPreviousOccurrenceOfSelection() {
        findOccurrenceOfSelection(forward: false)
    }

    private func findOccurrenceOfSelection(forward: Bool) {
        guard selectedRange.length > 0 else { return }
        let nsText = text as NSString
        let needle = nsText.substring(with: selectedRange)
        guard !needle.isEmpty else { return }
        let length = nsText.length
        let searchRange: NSRange
        if forward {
            let start = NSMaxRange(selectedRange)
            searchRange = NSRange(location: start, length: max(0, length - start))
        } else {
            searchRange = NSRange(location: 0, length: selectedRange.location)
        }
        var found = nsText.range(of: needle, options: forward ? [] : .backwards, range: searchRange)
        if found.location == NSNotFound {
            // Wrap.
            found = nsText.range(of: needle, options: forward ? [] : .backwards)
        }
        guard found.location != NSNotFound else { return }
        selectedRange = found
        scrollRangeToVisible(found)
    }

    // MARK: - Smart Home

    func smartMoveToLineStart() {
        let nsText = text as NSString
        let cursor = selectedRange.location
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let lineStart = lineRange.location
        // Find first non-whitespace.
        var firstNonWS = lineStart
        let lineEnd = lineRange.location + lineRange.length
        while firstNonWS < lineEnd {
            let ch = nsText.character(at: firstNonWS)
            if ch != UInt16(0x20) && ch != UInt16(0x09) { break }
            firstNonWS += 1
        }
        // If we're at the first non-whitespace already, snap to column 0;
        // otherwise jump to the first non-whitespace.
        let target = (cursor == firstNonWS) ? lineStart : firstNonWS
        selectedRange = NSRange(location: target, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    // MARK: - Transpose, deletion

    func transposeCharacters() {
        let nsText = text as NSString
        let length = nsText.length
        var cursor = selectedRange.location
        guard length >= 2 else { return }
        if cursor == 0 { cursor = 1 }
        if cursor >= length { cursor = length - 1 }
        let leftRange = NSRange(location: cursor - 1, length: 1)
        let rightRange = NSRange(location: cursor, length: 1)
        let left = nsText.substring(with: leftRange)
        let right = nsText.substring(with: rightRange)
        replace(NSRange(location: cursor - 1, length: 2), withText: right + left)
        selectedRange = NSRange(location: cursor + 1, length: 0)
    }

    func deleteToEndOfLine() {
        let nsText = text as NSString
        let cursor = selectedRange.location
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        var end = lineRange.location + lineRange.length
        // Keep the trailing newline (Mac convention). `lineRange`
        // already covers CRLF, so we step back over either byte.
        while end > cursor {
            let last = nsText.character(at: end - 1)
            guard last == 0x0A || last == 0x0D else { break }
            end -= 1
        }
        if end > cursor {
            replace(NSRange(location: cursor, length: end - cursor), withText: "")
        }
    }

    func deleteWordBackward() {
        let cursor = selectedRange.location
        guard cursor > 0 else { return }
        let nsText = text as NSString
        var idx = cursor
        // Skip whitespace immediately behind cursor.
        while idx > 0 && Self.isWhitespaceByte(nsText.character(at: idx - 1)) {
            idx -= 1
        }
        // Then consume the word characters.
        while idx > 0 && !Self.isWhitespaceByte(nsText.character(at: idx - 1)) {
            idx -= 1
        }
        let range = NSRange(location: idx, length: cursor - idx)
        if range.length > 0 { replace(range, withText: "") }
    }

    func deleteWordForward() {
        let cursor = selectedRange.location
        let nsText = text as NSString
        let length = nsText.length
        guard cursor < length else { return }
        var idx = cursor
        while idx < length && Self.isWhitespaceByte(nsText.character(at: idx)) {
            idx += 1
        }
        while idx < length && !Self.isWhitespaceByte(nsText.character(at: idx)) {
            idx += 1
        }
        let range = NSRange(location: cursor, length: idx - cursor)
        if range.length > 0 { replace(range, withText: "") }
    }

    private static func isWhitespaceByte(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    // MARK: - Join lines

    func joinLines() {
        let nsText = text as NSString
        let length = nsText.length
        let cursor = selectedRange.location
        // Find the end of the current line.
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let endOfLine = lineRange.location + lineRange.length
        guard endOfLine < length else { return }
        // Determine the line terminator length (1 for LF/CR, 2 for CRLF).
        let terminatorLen: Int
        let last = nsText.character(at: endOfLine - 1)
        if last == 0x0A,
           endOfLine - 2 >= 0,
           nsText.character(at: endOfLine - 2) == 0x0D {
            terminatorLen = 2
        } else if last == 0x0A || last == 0x0D {
            terminatorLen = 1
        } else {
            return
        }
        let terminatorStart = endOfLine - terminatorLen
        // Skip leading whitespace on the next line, then replace the
        // terminator (and that whitespace) with a single space.
        var trimmed = endOfLine
        while trimmed < length {
            let c = nsText.character(at: trimmed)
            if c == 0x20 || c == 0x09 { trimmed += 1 } else { break }
        }
        replace(NSRange(location: terminatorStart, length: trimmed - terminatorStart), withText: " ")
        selectedRange = NSRange(location: terminatorStart + 1, length: 0)
    }

    // MARK: - Spell check

    /// One instance per process; retains learned words for the app's
    /// lifetime.
    private static let textChecker = UITextChecker()

    /// Remembers ignored words so the highlighter doesn't immediately
    /// re-flag them — UITextChecker's ignoreWord is per-checker but
    /// doesn't filter the highlight pass.
    private static var ignoredWords: Set<String> = []

    func jumpToNextMisspelling() {
        let nsText = text as NSString
        let start = selectedRange.location
        var range = Self.textChecker.rangeOfMisspelledWord(
            in: nsText as String,
            range: NSRange(location: 0, length: nsText.length),
            startingAt: start,
            wrap: true,
            language: "en_US"
        )
        // Skip ranges whose word we've been told to ignore.
        while range.location != NSNotFound {
            let word = nsText.substring(with: range)
            if !Self.ignoredWords.contains(word) {
                selectedRange = range
                scrollRangeToVisible(range)
                return
            }
            range = Self.textChecker.rangeOfMisspelledWord(
                in: nsText as String,
                range: NSRange(location: 0, length: nsText.length),
                startingAt: NSMaxRange(range),
                wrap: true,
                language: "en_US"
            )
        }
    }

    func learnSelectedWord() {
        guard let word = wordAtSelection(), !word.isEmpty else { return }
        learnWord(word)
    }

    func ignoreSelectedWord() {
        guard let word = wordAtSelection(), !word.isEmpty else { return }
        ignoreWord(word)
    }

    func learnWord(_ word: String) {
        // `learnWord` is a static — it writes to the system-wide
        // learned-words dictionary. `ignoreWord` is an instance
        // method scoped per checker.
        UITextChecker.learnWord(word)
        Self.ignoredWords.remove(word)
    }

    func ignoreWord(_ word: String) {
        Self.textChecker.ignoreWord(word)
        Self.ignoredWords.insert(word)
    }

    /// Walk-through driver: skips over session-ignored words and
    /// returns the first flagged hit at or after `location`, wrapping
    /// once. `suggestions` is ranked best-first by UITextChecker.
    func nextMisspelling(from location: Int) -> (range: NSRange, word: String, suggestions: [String])? {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var range = Self.textChecker.rangeOfMisspelledWord(
            in: nsText as String,
            range: full,
            startingAt: max(0, min(location, nsText.length)),
            wrap: true,
            language: "en_US"
        )
        while range.location != NSNotFound {
            let word = nsText.substring(with: range)
            if !Self.ignoredWords.contains(word) {
                let guesses = Self.textChecker.guesses(
                    forWordRange: range,
                    in: nsText as String,
                    language: "en_US"
                ) ?? []
                return (range, word, guesses)
            }
            range = Self.textChecker.rangeOfMisspelledWord(
                in: nsText as String,
                range: full,
                startingAt: NSMaxRange(range),
                wrap: true,
                language: "en_US"
            )
        }
        return nil
    }

    /// Namespace so we replace only misspelling marks, not live-match
    /// / bracket-match / find-bar highlights.
    private static let misspellingHighlightID = "ayyyy.misspelling-"

    func highlightAllMisspellings() {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var hits: [NSRange] = []
        var cursor = 0
        while cursor < nsText.length {
            let r = Self.textChecker.rangeOfMisspelledWord(
                in: nsText as String,
                range: full,
                startingAt: cursor,
                wrap: false,
                language: "en_US"
            )
            guard r.location != NSNotFound else { break }
            // Skip words the user has flagged as ignored this session.
            let word = nsText.substring(with: r)
            if !Self.ignoredWords.contains(word) {
                hits.append(r)
            }
            cursor = r.location + max(r.length, 1)
            // Safety cap so an unexpectedly large doc can't lock the
            // main thread on the menu action.
            if hits.count > 5_000 { break }
        }
        // Replace any previous misspelling marks; leave other
        // highlights (live match, bracket match, find) untouched.
        let surviving = highlightedRanges.filter { !$0.id.hasPrefix(Self.misspellingHighlightID) }
        let tint = UIColor.systemRed.withAlphaComponent(0.22)
        let fresh = hits.enumerated().map { idx, range in
            HighlightedRange(
                id: "\(Self.misspellingHighlightID)\(idx)",
                range: range,
                color: tint,
                cornerRadius: 2
            )
        }
        highlightedRanges = surviving + fresh
    }

    func clearMisspellingHighlights() {
        highlightedRanges = highlightedRanges.filter {
            !$0.id.hasPrefix(Self.misspellingHighlightID)
        }
    }

    /// Scans the current misspelling highlights and returns the one
    /// containing `location` — inclusive of the trailing edge so a
    /// cursor parked right after the last letter still counts as
    /// "inside the word".
    func misspellingRange(at location: Int) -> NSRange? {
        for hr in highlightedRanges where hr.id.hasPrefix(Self.misspellingHighlightID) {
            if NSLocationInRange(location, hr.range) || location == NSMaxRange(hr.range) {
                return hr.range
            }
        }
        return nil
    }

    /// Word at the cursor; nil if the cursor sits in whitespace.
    private func wordAtSelection() -> String? {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return nil }
        var start = min(selectedRange.location, length)
        var end = start
        let isWordChar: (unichar) -> Bool = { ch in
            CharacterSet.letters.contains(Unicode.Scalar(ch)!) || (ch >= 0x30 && ch <= 0x39) || ch == 0x27
        }
        while start > 0 {
            let ch = nsText.character(at: start - 1)
            if !isWordChar(ch) { break }
            start -= 1
        }
        while end < length {
            let ch = nsText.character(at: end)
            if !isWordChar(ch) { break }
            end += 1
        }
        guard end > start else { return nil }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - Bracket match

    private static let bracketHighlightID = "ayyyy.bracketMatch"

    func goToMatchingBracket() {
        guard let match = BracketMatcher.matchingLocation(in: text as NSString, cursor: selectedRange.location) else { return }
        selectedRange = NSRange(location: match, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    func clearBracketMatchHighlight() {
        highlightedRanges = highlightedRanges.filter {
            $0.id != Self.bracketHighlightID && $0.id != Self.bracketHighlightID + ".pair"
        }
    }

    func refreshBracketMatchHighlight() {
        let nsText = text as NSString
        let cursor = selectedRange.location
        let length = nsText.length
        // Strip any prior bracket highlight.
        var others = highlightedRanges.filter { $0.id != Self.bracketHighlightID && $0.id != Self.bracketHighlightID + ".pair" }
        defer { highlightedRanges = others }
        guard selectedRange.length == 0, length > 0 else { return }
        // Look at char before or at cursor.
        var bracketIndex: Int?
        if cursor < length, BracketMatcher.isBracket(nsText.character(at: cursor)) {
            bracketIndex = cursor
        } else if cursor > 0, BracketMatcher.isBracket(nsText.character(at: cursor - 1)) {
            bracketIndex = cursor - 1
        }
        guard let bracket = bracketIndex,
              let mate = BracketMatcher.matchingLocation(in: nsText, atBracketAt: bracket) else {
            return
        }
        let color = UIColor.systemBlue.withAlphaComponent(0.25)
        others.append(HighlightedRange(id: Self.bracketHighlightID, range: NSRange(location: bracket, length: 1), color: color, cornerRadius: 2))
        others.append(HighlightedRange(id: Self.bracketHighlightID + ".pair", range: NSRange(location: mate, length: 1), color: color, cornerRadius: 2))
    }

    // MARK: - Folding (indent-based v1)

    func unfoldAll() {
        unfoldAllLines()
    }

    func applyFoldRanges(_ ranges: [ClosedRange<Int>]) {
        // Idempotent — unfold everything first so we don't get duplicates,
        // then fold the persisted ranges.
        unfoldAllLines()
        for range in ranges {
            setLinesFolded(true, range: range)
        }
    }

    func applyLineEndingRawValue(_ rawValue: Character) {
        let mapped: EditorEngine.LineEnding
        switch rawValue {
        case "\n":   mapped = .lf
        case "\r":   mapped = .cr
        case "\r\n": mapped = .crlf
        default:     mapped = .lf
        }
        self.lineEndings = mapped
    }
}


