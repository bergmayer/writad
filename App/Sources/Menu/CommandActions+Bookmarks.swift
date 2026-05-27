import Foundation
import UIKit

extension CommandActions {

    // MARK: - Bookmark line ops

    /// Cut the text of every bookmarked line out of the document and
    /// place it (joined with line endings) on the clipboard.
    static func cutBookmarkedLines() {
        let collected = collectBookmarkedLines()
        UIPasteboard.general.string = collected.text
        removeLines(at: collected.ranges)
    }

    /// Copy bookmarked-line text to the clipboard without altering
    /// the document.
    static func copyBookmarkedLines() {
        UIPasteboard.general.string = collectBookmarkedLines().text
    }

    /// Drop every line that is NOT bookmarked. Lines with bookmarks
    /// move into "filter" mode — the result is an extract.
    static func keepBookmarkedLinesOnly() {
        guard let textView = actions, let state else { return }
        let bookmarkedSet = Set(state.bookmarks.values)
        let nsText = textView.text as NSString
        let nl = state.lineEnding.string
        var output: [String] = []
        var scan = 0
        while scan < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: scan, length: 0))
            if bookmarkedSet.contains(line.location) {
                var content = nsText.substring(with: line)
                if content.hasSuffix(nl) { content.removeLast(nl.count) }
                output.append(content)
            }
            scan = line.location + line.length
        }
        textView.text = output.joined(separator: nl)
        state.bookmarks.removeAll()
        commitTextChange()
    }

    /// Delete every bookmarked line.
    static func removeBookmarkedLines() {
        let collected = collectBookmarkedLines()
        removeLines(at: collected.ranges)
        state?.bookmarks.removeAll()
    }

    /// Flip bookmarks: every line currently bookmarked loses its
    /// flag; every other line whose start matches a freshly-assigned
    /// slot becomes bookmarked (limited to 10 slots).
    static func invertBookmarks() {
        guard let textView = actions, let state else { return }
        let oldStarts = Set(state.bookmarks.values)
        let nsText = textView.text as NSString
        var freshStarts: [Int] = []
        var scan = 0
        while scan < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: scan, length: 0))
            if !oldStarts.contains(line.location) {
                freshStarts.append(line.location)
            }
            scan = line.location + line.length
        }
        state.bookmarks.removeAll()
        for (slot, loc) in freshStarts.prefix(10).enumerated() {
            state.bookmarks[slot] = loc
        }
    }

    private struct BookmarkedLines {
        let text: String
        let ranges: [NSRange]
    }

    private static func collectBookmarkedLines() -> BookmarkedLines {
        guard let textView = actions, let state else { return BookmarkedLines(text: "", ranges: []) }
        let nsText = textView.text as NSString
        let nl = state.lineEnding.string
        let starts = state.bookmarks.values.sorted()
        var bodies: [String] = []
        var ranges: [NSRange] = []
        for start in starts where start >= 0 && start < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: start, length: 0))
            var body = nsText.substring(with: line)
            if body.hasSuffix(nl) { body.removeLast(nl.count) }
            bodies.append(body)
            ranges.append(line)
        }
        return BookmarkedLines(text: bodies.joined(separator: nl), ranges: ranges)
    }

    /// Delete a set of line ranges bottom-up so earlier offsets stay
    /// valid.
    private static func removeLines(at ranges: [NSRange]) {
        guard let textView = actions, !ranges.isEmpty else { return }
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            textView.replace(range, withText: "")
        }
        commitTextChange()
    }

    // MARK: - Bookmark slots (numbered 0–9)

    static func setBookmark(_ slot: Int) {
        guard let textView = actions, let state = state else { return }
        state.bookmarks[slot] = textView.selectedRange.location
    }

    static func jumpToBookmark(_ slot: Int) {
        guard let textView = actions, let state = state, let location = state.bookmarks[slot] else { return }
        let length = (textView.text as NSString).length
        textView.setSelection(NSRange(location: min(location, length), length: 0))
        textView.scrollSelectionToVisible()
        recordPositionIfJumped()
    }

    static func clearBookmark(_ slot: Int) {
        state?.bookmarks[slot] = nil
    }
}
