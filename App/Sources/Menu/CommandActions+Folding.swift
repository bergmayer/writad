import Foundation

@MainActor
extension CommandActions {

    // MARK: - Fold Selection

    /// Folds every line touched by the selection (or the current line
    /// when empty). Same engine call as language folding, driven by
    /// the user's selection instead of a tree-sitter marker.
    static func foldSelection() {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let selection = textView.selectedRange
        let block = nsText.lineRange(for: selection)
        // One pass for both endpoints — `lineNumber(forCharacterAt:)`
        // rescans from 0 each call, so two endpoints cost O(N²).
        let endChar = max(block.location, block.location + block.length - 1)
        let lines = lineNumbers(forCharactersAt: [block.location, endChar], in: nsText)
        guard lines.count == 2, lines[0] <= lines[1] else { return }
        let body = lines[0]...lines[1]
        textView.setLinesFolded(true, range: body)
        // Record so `refreshFoldableRegions` emits a FoldableRegion
        // at the header above — engine then paints its native,
        // theme-aware gutter chevron.
        state?.userFoldedBodyRanges.insert(body)
    }

    /// O(N + k log k) for k offsets; the prior per-offset helper
    /// rescanned from 0 each call.
    private static func lineNumbers(forCharactersAt offsets: [Int],
                                     in nsText: NSString) -> [Int] {
        let sorted = offsets.enumerated().sorted { $0.element < $1.element }
        var results = [Int](repeating: 0, count: offsets.count)
        var line = 0, scan = 0, cursor = 0
        while scan < nsText.length, cursor < sorted.count {
            let lr = nsText.lineRange(for: NSRange(location: scan, length: 0))
            while cursor < sorted.count, sorted[cursor].element < lr.location + lr.length {
                results[sorted[cursor].offset] = line
                cursor += 1
            }
            scan = lr.location + lr.length
            line += 1
        }
        // Any offset past the last newline lands on the final line.
        while cursor < sorted.count {
            results[sorted[cursor].offset] = line
            cursor += 1
        }
        return results
    }

    // MARK: - Folding

    static func toggleFoldAtCursor() {
        guard let state = state, let textView = actions else { return }
        let nsText = textView.text as NSString
        // 0-based line index for the cursor location.
        let row = currentLineIndex(in: nsText, atUtf16: textView.selectedRange.location)
        guard let body = FoldDiscovery.bodyRange(
            forHeaderRow: row,
            in: nsText,
            language: state.languageIdentifier
        ) else { return }
        let alreadyFolded = body.contains { textView.foldedLineIndices.contains($0) }
        textView.setLinesFolded(!alreadyFolded, range: body)
        persistFolds()
    }

    static func unfoldAll() {
        actions?.unfoldAll()
        persistFolds()
    }

    /// Clear every ad-hoc fold range declared by `Fold Selection`.
    /// Unfolds the lines and drops the gutter indicators — handy
    /// after experimenting with a bunch of manual folds. Language-
    /// derived folds (Markdown headers, code blocks) are
    /// untouched; only the `userFoldedBodyRanges` entries go away.
    static func clearManualFolds() {
        guard let state = Self.state else { return }
        let bodies = state.userFoldedBodyRanges
        guard !bodies.isEmpty else { return }
        for body in bodies {
            actions?.setLinesFolded(false, range: body)
        }
        state.userFoldedBodyRanges.removeAll()
    }

    static func foldAll() {
        guard let state = state, let textView = actions else { return }
        let nsText = textView.text as NSString
        let foldable = FoldDiscovery.allFoldableHeaders(in: nsText, language: state.languageIdentifier)
        for region in foldable {
            textView.setLinesFolded(true, range: region.bodyRange)
        }
        persistFolds()
    }

    private static func persistFolds() {
        guard let state = state, let textView = actions else { return }
        FoldPersistence.save(textView.foldedLineIndices, for: state.fileURL)
    }

    /// 0-based line index for a UTF-16 location into the supplied NSString.
    private static func currentLineIndex(in text: NSString, atUtf16 offset: Int) -> Int {
        let safe = max(0, min(offset, text.length))
        var line = 0
        var i = 0
        while i < safe {
            let c = text.character(at: i)
            if c == 0x0A {
                line += 1
                i += 1
            } else if c == 0x0D {
                line += 1
                i += 1
                if i < safe, text.character(at: i) == 0x0A { i += 1 }
            } else {
                i += 1
            }
        }
        return line
    }
}
