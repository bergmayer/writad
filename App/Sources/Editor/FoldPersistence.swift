import Foundation

/// Persists folded-line ranges per document URL across app launches.
///
/// Storage shape in `UserDefaults`:
///
/// ```
/// foldedRanges = {
///     "file:///…/foo.swift": [[5, 12], [40, 55]],
///     "file:///…/bar.md":    [[3, 9]]
/// }
/// ```
///
/// Each inner array is `[lowerBound, upperBound]` of a contiguous folded
/// run. We don't try to track folds for scratch buffers (URL nil); they
/// reset on relaunch.
@MainActor
enum FoldPersistence {

    private static let defaultsKey = "foldedRanges"

    static func ranges(for url: URL?) -> [ClosedRange<Int>] {
        guard let url else { return [] }
        let all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [[Int]]] ?? [:]
        guard let pairs = all[url.absoluteString] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, pair[0] <= pair[1] else { return nil }
            return pair[0]...pair[1]
        }
    }

    static func save(_ lineIndices: [Int], for url: URL?) {
        guard let url else { return }
        let ranges = contiguousRanges(from: lineIndices)
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [[Int]]] ?? [:]
        if ranges.isEmpty {
            all.removeValue(forKey: url.absoluteString)
        } else {
            all[url.absoluteString] = ranges.map { [$0.lowerBound, $0.upperBound] }
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// Collapse a list of sorted line indices into contiguous ranges.
    private static func contiguousRanges(from indices: [Int]) -> [ClosedRange<Int>] {
        guard !indices.isEmpty else { return [] }
        let sorted = indices.sorted()
        var ranges: [ClosedRange<Int>] = []
        var lower = sorted[0]
        var upper = sorted[0]
        for value in sorted.dropFirst() {
            if value == upper + 1 {
                upper = value
            } else {
                ranges.append(lower...upper)
                lower = value
                upper = value
            }
        }
        ranges.append(lower...upper)
        return ranges
    }
}
