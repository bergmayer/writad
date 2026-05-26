import SwiftUI
import UIKit
import EditorEngine
import AyyyySyntax

/// SwiftUI wrapper around `EditorEngine.TextView`.
///
/// Architecture note (do not regress): the engine's `TextView` IS
/// the source of truth for the buffer. Per-keystroke text never
/// flows back into SwiftUI's observation graph — the previous
/// `Binding<String>` design copied the full buffer through
/// `document.text` → `state.text` on every keystroke, which froze
/// editing on multi-MB files. Instead the coordinator bumps a tiny
/// `document.bufferRevision` counter and (for status-bar /
/// markdown-preview consumers that need eventual consistency)
/// debounces a snapshot back into `document.text` / `state.text`.
/// `isDirty` is set up-front via the engine's `shouldChangeTextIn`
/// delegate so the dirty flag is range-aware, not buffer-flow-aware.
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
        // background, so DarkTheme (textColor = .white) painted white
        // text on a white view — blank by design. Every shipping theme
        // (Light, Dark, the textamp ports) conforms to
        // `EditorBackgroundProviding` and supplies its own surface
        // colour — Dracula gives Dracula bg, Norton gives DOS-blue, etc.
        textView.backgroundColor = (initialTheme as? EditorBackgroundProviding)?
            .editorBackgroundColor ?? .systemBackground
        context.coordinator.themeCacheKey = initialThemeKey
        textView.text = document.text
        context.coordinator.lastPushedDocumentText = document.text
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .always
        // Attach navigation buttons to the keyboard's own shortcut
        // bar (system-managed, follows the keyboard around) instead
        // of an inputAccessoryView (which sticks to the text view's
        // bottom edge and overlaps our status bar in Stage Manager /
        // Slide Over windows).
        KeyboardAccessoryBar.install(on: textView)
        textView.onFoldToggle = { [weak textView] body in
            guard let textView else { return }
            let isFolded = body.contains { textView.foldedLineIndices.contains($0) }
            textView.setLinesFolded(!isFolded, range: body)
        }
        // Markdown inline patterns (`*foo*`, `**foo**`, `` `foo` ``,
        // `[label](url)`, headings, lists, quotes) get foreground colours
        // and font traits via the engine's per-line post-highlight
        // decorator. Captured weakly to avoid `state` → `textView` →
        // closure → `state` cycle.
        // Decorator is a no-op for files marked large — it walks every
        // line on every render and would lag a multi-MB document.
        MarkdownInlineHighlighter.install(on: textView) { [weak state] in
            guard let state, !state.isLargeFile else { return .plain }
            return state.languageIdentifier
        }

        applyTypingPreferences(to: textView)
        applyViewSettings(to: textView)
        applyLanguage(to: textView, identifier: state.languageIdentifier, coordinator: context.coordinator)
        applyIndentStrategy(to: textView)
        applyCharacterPairs(to: textView)

        // Bookmark gutter — a content-space subview of the engine's
        // scroll view. Stays in sync with bookmark locations via
        // `updateUIView`; rerenders on scroll/contentSize change via
        // its own `layoutSubviews`.
        let bookmarks = BookmarkGutterOverlay(host: textView)
        textView.addSubview(bookmarks)
        context.coordinator.bookmarkOverlay = bookmarks

        // Scrollbar-edge tick marks for live match hits — paints one
        // small line at each match's y position on the right side of
        // the scrollview so the user can see how matches cluster.
        let matchMarks = MatchScrollMarksOverlay(host: textView)
        textView.addSubview(matchMarks)
        context.coordinator.matchScrollOverlay = matchMarks

        // VS Code–style change indicators inside the line-number
        // gutter — green/yellow/red bars where the current buffer
        // diverges from the last saved (or loaded) snapshot.
        let history = ChangeHistoryGutterOverlay(host: textView)
        textView.addSubview(history)
        context.coordinator.changeHistoryOverlay = history

        // Note: arbitrary fold markers (Fold Selection) used to live
        // in a sibling overlay here, but the engine's own
        // `bringSubviewToFront(gutterContainerView)` covered it and
        // pushing it outside the gutter looked off-theme. Solution:
        // synthesize a `FoldableRegion` for each entry in
        // `state.userFoldedBodyRanges` from `refreshFoldableRegions`
        // — the engine then paints its native gutter chevron
        // (theme-aware, inside the gutter, and tap-toggles via the
        // existing `onFoldToggle` hook).

        state.textView = textView
        return textView
    }

    func updateUIView(_ textView: EditorEngine.TextView, context: Context) {
        // The engine owns the live buffer. We only push `document.text`
        // into the text view when an EXTERNAL writer changed it — a
        // load, a Revert, a Revisions-sheet restore, a Save-As pulled
        // a different decode. Tracked via `lastPushedDocumentText` so
        // we don't compare-and-assign the buffer on every render
        // (which was the O(n) cost that froze typing on big files).
        if context.coordinator.lastPushedDocumentText != document.text {
            context.coordinator.lastPushedDocumentText = document.text
            if textView.text != document.text {
                textView.text = document.text
            }
        }
        applyTypingPreferences(to: textView)
        applyViewSettings(to: textView)
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
        // Feed the change-history gutter the latest baseline + body.
        // The change-history overlay is gated three ways. The user
        // preference (`showChangeHistoryGutter`, off by default) is
        // the explicit opt-in. The byte ceiling
        // (`changeHistoryGutterByteLimit`) is the perf gate: even
        // when the preference is on, we refuse to render past the
        // ceiling because the per-line diff + `caretRect` lookups
        // + bar layout become perceptible after a delete on
        // hundred-KB-plus files. The cache short-circuit avoids
        // re-splitting when the source strings didn't change between
        // renders.
        let coord = context.coordinator
        let prefOn = state.showChangeHistoryGutter
        let withinSize = textView.text.utf16.count <= Timing.changeHistoryGutterByteLimit
        let shouldRender = prefOn && !state.isLargeFile && withinSize
        if let overlay = coord.changeHistoryOverlay {
            if !shouldRender {
                // Drop any bars we may have rendered before the
                // preference flipped off or the file grew past the
                // ceiling (paste, undo of a big delete, etc.). Reset
                // the cache too so re-enabling re-renders fresh.
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
        // dataDetectorTypes isn't exposed by the editor engine's TextView;
        // the `autoLinkDetection` preference is stored but not yet wired.
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

        // Cap the soft-wrap width at the page-guide column. The
        // engine wraps at the text-container's right edge; with a
        // monospaced font we can compute the desired width as
        // `column × char-advance` and push the right inset to make
        // the wrap line up exactly with the page-guide bar. Wrap is
        // a no-op when wrapping is off, and a no-op when the
        // window is already narrower than the column requires.
        applyPageGuideWrap(to: textView)
    }

    private func applyPageGuideWrap(to textView: EditorEngine.TextView) {
        guard state.wrapLines, state.pageGuideColumn > 0 else {
            // Wrap disabled or no column set — return to default
            // right inset so any prior cap is cleared.
            if textView.textContainerInset.right != 0 {
                var inset = textView.textContainerInset
                inset.right = 0
                textView.textContainerInset = inset
            }
            return
        }
        let font = state.font.uiFont(size: CGFloat(state.fontSize))
        // Monospaced advance — `" "` width is the canonical glyph
        // advance for the engine's monospaced rendering path. Using
        // `UIFont.advance(of:)` would require attributing a string,
        // and "size(withAttributes:)" suffices.
        let probe = " " as NSString
        let charWidth = probe.size(withAttributes: [.font: font]).width
        guard charWidth > 0 else { return }
        let desiredColumnWidth = CGFloat(state.pageGuideColumn) * charWidth
        // The available content width is the scrollview width minus
        // the gutter (line numbers) minus the existing left inset.
        // `textContainerInset.left` is the body-text inset to the
        // right of the gutter; we keep it intact and only push the
        // right inset.
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
        // Files marked large bypass tree-sitter regardless of the
        // identifier — the initial parse is O(file size) and runs on
        // the engine's pipeline. Plain text mode keeps typing snappy.
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
        /// Snapshot of `document.text` from the last EXTERNAL push
        /// (load / revert / restore). Lets `updateUIView` skip the
        /// O(n) `textView.text != document.text` compare when
        /// `document.text` hasn't changed since the last push — the
        /// engine itself is keeping the buffer up to date for user
        /// edits, so we don't need to re-sync.
        var lastPushedDocumentText: String?
        /// `true` while we're programmatically applying a sync from
        /// the sibling split pane — short-circuits delegate callbacks
        /// so we don't bounce the same edit back across the pair.
        var isApplyingSiblingSync: Bool = false
        /// Debounced snapshot back into `state.text` / `document.text`
        /// for consumers that need eventual consistency (status-bar
        /// counts, markdown preview). Rescheduled on every keystroke;
        /// runs once after typing pauses.
        var bufferSnapshotTask: Task<Void, Never>?
        /// Cache key for fold discovery — string length + language. Skips
        /// the O(N) walk on every SwiftUI re-render when the buffer
        /// hasn't actually changed (SwiftUI re-evaluates body on every
        /// `@Observable` change and updateUIView fires every time).
        private var foldCacheKey: (length: Int, language: LanguageIdentifier, userFolds: String)?
        /// Overlay drawn inside the engine's scroll view to render
        /// bookmark slot numbers in the gutter. Owned by the engine view
        /// (as a subview) — this reference just lets `updateUIView`
        /// push fresh data without re-walking the view hierarchy.
        weak var bookmarkOverlay: BookmarkGutterOverlay?
        weak var changeHistoryOverlay: ChangeHistoryGutterOverlay?
        /// Cached source strings for the change-history overlay so the
        /// debounced refresh skips the expensive `components(separatedBy:)`
        /// split when the underlying text hasn't actually changed
        /// between renders. Pairs with `overlayRefreshTask` (debounce)
        /// and the `isLargeFile` gate (skip-entirely) below to keep
        /// per-keystroke main-thread cost flat regardless of file size.
        var changeHistoryBaselineCache: String?
        var changeHistoryCurrentCache: String?
        /// Debounce window for the change-history overlay refresh.
        /// `updateUIView` fires on every SwiftUI body re-evaluation —
        /// which on a large file is every keystroke — and the
        /// overlay refresh splits both buffer + baseline by `\n`
        /// (allocates one Array<String> per text per call). For
        /// Moby Dick that's ~22k allocations per call; running it
        /// 30+ times per second of typing freezes the main thread.
        /// Debouncing means we only re-split after the user pauses,
        /// so typing stays snappy and the diff bars update a beat
        /// later — an acceptable trade for snappy editing.
        var overlayRefreshTask: Task<Void, Never>?
        /// Cached theme inputs. `AppTheme.current(...)` returns a fresh
        /// reference each call, and the engine's `theme.didSet` uses `!==`,
        /// so reassigning the equivalent theme on every SwiftUI re-render
        /// invalidates every line controller and re-lays the whole view —
        /// which on a large file shows up as the viewport drifting
        /// down a line per update. Skip when nothing actually changed.
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
            // Tiny payload — no full buffer flows through. Observers
            // that care about "the buffer changed" (autosave
            // scheduler, change-history overlay debouncer) react to
            // this counter; observers that need the actual text
            // pull it from the engine on demand.
            document.bufferRevision &+= 1
            scheduleBufferSnapshot(from: textView)
            // Invalidate the fold cache when the text actually changes.
            foldCacheKey = nil
            refreshFoldableRegions(textView)
        }

        /// Debounce a snapshot of the live buffer back into
        /// `document.text` / `state.text`. These are the eventual-
        /// consistency surfaces — status-bar line/char counts,
        /// markdown preview, sheets that read `document.text` on
        /// open. They don't need to update on every keystroke, just
        /// shortly after the user pauses. The debounce window
        /// matches the change-history overlay so both refresh
        /// together for a single re-render pass.
        private func scheduleBufferSnapshot(from textView: EditorEngine.TextView) {
            bufferSnapshotTask?.cancel()
            bufferSnapshotTask = Task { @MainActor [weak document, weak state, weak self] in
                try? await Task.sleep(for: Timing.changeHistoryOverlayDebounce)
                if Task.isCancelled { return }
                guard let document, let state, let self else { return }
                let snapshot = textView.text
                if document.text != snapshot {
                    document.text = snapshot
                    // Avoid bouncing the snapshot back through
                    // `updateUIView`'s `lastPushedDocumentText`
                    // check — we already match.
                    self.lastPushedDocumentText = snapshot
                }
                if state.text != snapshot {
                    state.text = snapshot
                }
            }
        }

        func refreshFoldableRegions(_ textView: EditorEngine.TextView) {
            // Skip on large files.
            guard !state.isLargeFile else {
                textView.foldableRegions = []
                return
            }
            let length = (textView.text as NSString).length
            // Cache key includes the user-fold-set fingerprint so a
            // newly-folded selection invalidates the language-discovery
            // cache and emits an updated `foldableRegions` list. Without
            // that the ad-hoc fold's gutter indicator would only paint
            // after the next unrelated edit.
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
            // User folds from `Fold Selection` aren't part of any
            // language discovery — synthesize a FoldableRegion for
            // each so the engine paints its native, theme-aware
            // gutter chevron at the header line. The "header" is
            // the visible line immediately above the body; the body
            // is the collapsed range itself.
            for body in state.userFoldedBodyRanges {
                let header = max(0, body.lowerBound - 1)
                // De-dupe if language discovery already declared a
                // foldable region with the same header (unlikely but
                // possible — e.g. user selected exactly the body of
                // an existing fold).
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

        /// Static id namespace used so we can replace just our own
        /// highlights on each refresh without disturbing other
        /// decorations (bracket match, find hits, etc.).
        private static let liveMatchIDPrefix = "live-match-"

        /// Recompute "every other occurrence of the current selection"
        /// highlights + the matching gutter ticks. No-op when the
        /// preference is off, the selection is empty, single-character,
        /// or spans a newline.
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
            // Single-line selections only — multi-line matching with
            // this naive scanner would be confusing and expensive.
            if needle.contains("\n") || needle.contains("\r") {
                textView.highlightedRanges = cleared
                state.liveMatchCount = 0
                matchScrollOverlay?.matchRanges = []
                return
            }
            // Walk the whole buffer with NSString.range(of:options:range:)
            // and collect non-overlapping matches outside the user's
            // current selection.
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

        /// Gutter-edge overlay drawing one tick per match. Mirrors
        /// `BookmarkGutterOverlay`; populated by `refreshLiveMatches`.
        weak var matchScrollOverlay: MatchScrollMarksOverlay?

        /// Single `shouldChangeTextIn` for the coordinator. Handles
        /// three jobs in order so the engine sees one consistent
        /// answer per edit:
        ///   1. Range-aware dirty-flag set — the cheap way to know
        ///      "user is about to mutate the buffer" without
        ///      comparing the post-edit text against a baseline.
        ///   2. Split-pane sibling sync — propagate the same
        ///      `(range, replacement)` to the other pane's text
        ///      view so both stay character-for-character in step
        ///      without going through any shared observable.
        ///   3. Auto-continue lists on Enter (the original behavior
        ///      this delegate was added for). Gated on the
        ///      `autoContinueLists` pref. When the helper
        ///      intercepts the newline we return `false` so the
        ///      engine doesn't ALSO insert the bare `\n` — but the
        ///      dirty flag / sibling sync already fired above.
        ///
        /// Sibling-sync re-entrancy is guarded by
        /// `isApplyingSiblingSync` so the programmatic
        /// `sibling.replace(range:withText:)` doesn't bounce back
        /// across the pair.
        func textView(
            _ textView: EditorEngine.TextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if isApplyingSiblingSync { return true }

            // 1. Flip dirty up front. This is the entry point for
            // "first edit on this document" — no need to compare
            // buffers afterwards.
            if !document.isDirty { document.isDirty = true }

            // 2. Sibling-pane sync. The engine handles the edit
            // incrementally on both sides — no full-buffer copy.
            // `state.textView` is the abstract `EditorActions`
            // protocol; cast to the concrete engine view so we can
            // reach its delegate (the sibling pane's coordinator)
            // and arm the recursion guard.
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
        // Insert another copy of the line(s) immediately after.
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
        // Don't consume the trailing newline — Mac convention. `lineRange`
        // already includes any CRLF pair, so a single decrement here lands on
        // `\r`, which we also want to keep.
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

    /// Shared UITextChecker — one instance per process is enough; it
    /// retains learned words for the lifetime of the app.
    private static let textChecker = UITextChecker()

    /// Range we currently consider "ignored" within this textView —
    /// UITextChecker ignores per-checker, but we also remember the
    /// word so we don't re-flag immediately. Plain Set is fine; this
    /// list is short-lived.
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
        // UITextChecker exposes learnWord/unlearnWord/hasLearnedWord as
        // static members (they consult the system-wide learned-words
        // dictionary). The same goes for `ignoreWord` — that's an
        // instance method, scoped per checker.
        UITextChecker.learnWord(word)
        Self.ignoredWords.remove(word)
    }

    func ignoreSelectedWord() {
        guard let word = wordAtSelection(), !word.isEmpty else { return }
        Self.textChecker.ignoreWord(word)
        Self.ignoredWords.insert(word)
    }

    /// Static id prefix used by `highlightAllMisspellings` so we can
    /// remove only our own marks without disturbing live-match,
    /// bracket-match, or find-bar highlights.
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

    /// Substring of the buffer covering the word the cursor sits inside.
    /// Returns nil if the cursor is in whitespace and there's no
    /// surrounding word.
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

// MARK: - Bookmark gutter overlay

/// A `UIView` parked as a subview of the engine's scroll view so its
/// children scroll with the content. Renders a small numbered badge in
/// the gutter next to each bookmarked line (slot 0–9). Repaints in
/// `layoutSubviews` whenever the host's bounds or content size change,
/// and explicitly when `bookmarks` is assigned via SwiftUI's
/// `updateUIView` pass.
final class BookmarkGutterOverlay: UIView {

    weak var host: EditorEngine.TextView?

    var bookmarks: [Int: Int] = [:] {
        didSet { if bookmarks != oldValue { setNeedsLayout() } }
    }

    init(host: EditorEngine.TextView) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host else { return }
        // Cover the entire scroll content area so children positioned at
        // content-coordinates scroll naturally with the engine.
        let cs = host.contentSize
        let width = max(host.gutterWidth, 16)
        frame = CGRect(x: 0, y: 0, width: width, height: cs.height)
        rebuildBadges()
    }

    private func rebuildBadges() {
        guard let host else { return }
        // Cheap to recreate every layout: there are at most 10 badges.
        // Avoids leaking views when bookmarks reshuffle.
        subviews.forEach { $0.removeFromSuperview() }

        let textLength = (host.text as NSString).length
        let order = bookmarks.keys.sorted()
        for slot in order {
            guard let location = bookmarks[slot] else { continue }
            // Drop stale bookmarks past EOF — these can happen if the
            // file was edited externally and reloaded shorter.
            let clamped = max(0, min(location, textLength))
            let rect = host.caretRect(atCharacterIndex: clamped)
            guard rect.height > 0, rect.height.isFinite, rect.minY.isFinite else { continue }
            let badge = makeBadge(slot: slot)
            let size = CGSize(width: 16, height: 16)
            // Right-aligned inside the gutter so it sits between the
            // line numbers and the text — visible without nudging the
            // numbers out of place.
            let x = max(0, bounds.width - size.width - 2)
            let y = rect.minY + max(0, (rect.height - size.height) / 2)
            badge.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            addSubview(badge)
        }
    }

    private func makeBadge(slot: Int) -> UIView {
        let label = UILabel()
        label.text = "\(slot)"
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = .tintColor
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        return label
    }
}

// MARK: - Match scrollbar marks overlay

/// Right-edge overlay that paints a tick at the y position of every
/// live-match hit. Like `BookmarkGutterOverlay`, it lives as a subview
/// of the engine's scroll view so it auto-scrolls with the content.
/// The view occupies a thin strip on the trailing edge of the content
/// area; ticks span its full width so they're visible against any
/// background.
final class MatchScrollMarksOverlay: UIView {

    weak var host: EditorEngine.TextView?

    var matchRanges: [NSRange] = [] {
        didSet { if matchRanges != oldValue { setNeedsLayout() } }
    }

    private static let stripWidth: CGFloat = 4

    init(host: EditorEngine.TextView) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host else { return }
        let cs = host.contentSize
        let x = max(0, cs.width - Self.stripWidth)
        frame = CGRect(x: x, y: 0, width: Self.stripWidth, height: cs.height)
        rebuildTicks()
    }

    private func rebuildTicks() {
        guard let host else { return }
        subviews.forEach { $0.removeFromSuperview() }
        let textLength = (host.text as NSString).length
        for range in matchRanges {
            let clamped = max(0, min(range.location, textLength))
            let rect = host.caretRect(atCharacterIndex: clamped)
            guard rect.height > 0, rect.minY.isFinite else { continue }
            let tick = UIView(frame: CGRect(
                x: 0,
                y: rect.minY + rect.height / 2 - 1,
                width: bounds.width,
                height: 2
            ))
            tick.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.7)
            tick.layer.cornerRadius = 1
            addSubview(tick)
        }
    }
}

// MARK: - Change history gutter

/// VS Code–style change indicator on the inside edge of the line
/// number gutter. Compares the current buffer against the last
/// saved (or initially loaded) snapshot line-by-line:
///
/// * **green** — line is new since the baseline
/// * **yellow** — line content differs from the baseline
/// * **red triangle** — original line at this position was deleted
///
/// Cheap line-by-line diff: snapshot the baseline as `[String]` once,
/// then on each layout walk both lists in parallel. For documents
/// over a few thousand lines this could move to a CollectionDifference
/// based pass, but for the typical markdown / source range it's fine.
final class ChangeHistoryGutterOverlay: UIView {

    weak var host: EditorEngine.TextView?

    var baseline: [String] = [] {
        didSet { if baseline != oldValue { setNeedsLayout() } }
    }
    var current: [String] = [] {
        didSet { if current != oldValue { setNeedsLayout() } }
    }

    private static let stripWidth: CGFloat = 4

    init(host: EditorEngine.TextView) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host else { return }
        let cs = host.contentSize
        // Sit just outside the gutter, in the padding between the
        // line-number column and the text body. We can't render the
        // bars *inside* the gutter — the engine's
        // `bringSubviewToFront(gutterContainerView)` in its own
        // `layoutSubviews` covers any sibling view that overlaps the
        // gutter area. Placing the strip at `x == gutterWidth` puts
        // it in the `textContainerInset.left` margin, which has no
        // line-number drawing on top of it, so the bars are visible.
        frame = CGRect(x: host.gutterWidth, y: 0, width: Self.stripWidth, height: cs.height)
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let host else { return }
        guard !baseline.isEmpty || !current.isEmpty else { return }

        // Cheap "what's different" pass: for each line of the current
        // buffer, classify against the matching baseline index.
        //   - within-baseline range + same text → unchanged (no bar)
        //   - within-baseline range + different text → modified (yellow)
        //   - past baseline range → added (green)
        let maxIdx = current.count
        var i = 0
        let bCount = baseline.count
        while i < maxIdx {
            let baselineLine: String? = i < bCount ? baseline[i] : nil
            let kind: BarKind?
            if let baselineLine {
                kind = baselineLine == current[i] ? nil : .modified
            } else {
                kind = .added
            }
            if let kind {
                addBar(forLine: i, kind: kind, host: host)
            }
            i += 1
        }
        // Deleted lines beyond the current end — draw a small red
        // wedge at the very last current line (or top-of-doc if the
        // buffer is empty), since there's no row to anchor to.
        if bCount > current.count {
            let anchorLine = max(0, current.count - 1)
            addBar(forLine: anchorLine, kind: .deleted, host: host)
        }
    }

    private enum BarKind {
        case added, modified, deleted
        var color: UIColor {
            switch self {
            case .added:    return UIColor.systemGreen.withAlphaComponent(0.7)
            case .modified: return UIColor.systemYellow.withAlphaComponent(0.75)
            case .deleted:  return UIColor.systemRed.withAlphaComponent(0.7)
            }
        }
    }

    private func addBar(forLine line: Int, kind: BarKind, host: EditorEngine.TextView) {
        // Convert 0-based line index → character offset of line start
        // by scanning the buffer. Cached scan would be faster but
        // contentSize-driven layout is already throttled by the
        // engine, so cost stays bounded.
        let nsText = host.text as NSString
        var scan = 0
        var current = 0
        var lineStart = 0
        while scan < nsText.length {
            let lr = nsText.lineRange(for: NSRange(location: scan, length: 0))
            if current == line {
                lineStart = lr.location
                break
            }
            scan = lr.location + lr.length
            current += 1
        }
        let rect = host.caretRect(atCharacterIndex: lineStart)
        guard rect.height > 0, rect.height.isFinite, rect.minY.isFinite else { return }
        let bar = UIView(frame: CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height))
        bar.backgroundColor = kind.color
        bar.layer.cornerRadius = bounds.width / 2
        addSubview(bar)
    }
}

