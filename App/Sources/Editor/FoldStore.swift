import Foundation

/// Per-document fold state.
///
/// Implementation: folded ranges are physically substituted with a single
/// placeholder line whose marker prefix uniquely identifies the fold.
/// Original text lives here, keyed by fold ID. Saves expand all folds
/// first; restoring on load re-applies them by line index.
///
/// Rationale: the editor engine's layout pipeline doesn't expose a way to
/// set zero-height lines without a deep fork. Text substitution achieves
/// the same user-visible result (lines collapse to one summary row,
/// pressing Toggle re-expands them) while keeping undo/redo, find,
/// syntax highlighting, and selection all working with no engine changes.
@MainActor
@Observable
final class FoldStore {

    /// Marker pair we wrap the fold-id in. Picked from the Private Use
    /// Area so they can never collide with user content.
    static let markerOpen  = "\u{E020}"
    static let markerClose = "\u{E021}"

    struct Fold: Identifiable, Equatable {
        let id: UUID
        /// Original (expanded) text including the trailing newline.
        let originalText: String
        /// Number of lines collapsed by this fold (≥ 2; folding 1 line is
        /// a no-op and rejected at creation).
        let lineCount: Int
        /// First-line summary used in the placeholder.
        let headerSummary: String
    }

    private(set) var folds: [UUID: Fold] = [:]

    /// True when the buffer has at least one active fold.
    var hasActiveFolds: Bool { !folds.isEmpty }

    /// Builds the user-visible placeholder line for a fold.
    func placeholder(for fold: Fold) -> String {
        "▶ \(fold.headerSummary)  · · · \(fold.lineCount) lines folded · · ·"
            + Self.markerOpen + fold.id.uuidString + Self.markerClose
    }

    /// Returns the fold UUID embedded in the supplied line, if any.
    func foldID(in line: String) -> UUID? {
        guard let openIdx = line.range(of: Self.markerOpen),
              let closeIdx = line.range(of: Self.markerClose),
              openIdx.upperBound <= closeIdx.lowerBound
        else { return nil }
        let raw = String(line[openIdx.upperBound..<closeIdx.lowerBound])
        return UUID(uuidString: raw)
    }

    func register(originalText: String, headerSummary: String, lineCount: Int) -> Fold {
        let f = Fold(
            id: UUID(),
            originalText: originalText,
            lineCount: lineCount,
            headerSummary: headerSummary
        )
        folds[f.id] = f
        return f
    }

    func remove(_ id: UUID) -> Fold? {
        folds.removeValue(forKey: id)
    }

    /// Drops every recorded fold. The caller is responsible for replacing
    /// placeholder lines in the buffer first.
    func clear() {
        folds.removeAll()
    }
}
