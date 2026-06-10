import Foundation

extension CommandActions {

    // MARK: - Select / filter lines

    enum LineMatchError: LocalizedError {
        case invalidRegex(String)
        case noMatches

        var errorDescription: String? {
            switch self {
            case .invalidRegex(let pattern): return "Invalid regular expression: \(pattern)"
            case .noMatches:                 return "No lines matched."
            }
        }
    }

    static func selectLinesContaining(query: String, useRegex: Bool, caseSensitive: Bool) throws {
        guard let textView = actions else { return }
        let matcher = try LineMatcher(query: query, useRegex: useRegex, caseSensitive: caseSensitive)
        let nsText = textView.text as NSString
        var firstStart: Int?
        var lastEnd: Int?
        var location = 0
        while location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let lineString = nsText.substring(with: lineRange)
            let contentOnly = lineString.trimmingCharacters(in: .newlines)
            if matcher.matches(contentOnly) {
                if firstStart == nil { firstStart = lineRange.location }
                let trailingNewlines = (lineString as NSString).length - (contentOnly as NSString).length
                lastEnd = lineRange.location + lineRange.length - trailingNewlines
            }
            if lineRange.length == 0 { break }
            location = lineRange.location + lineRange.length
        }
        guard let start = firstStart, let end = lastEnd else { throw LineMatchError.noMatches }
        textView.setSelection(NSRange(location: start, length: end - start))
        textView.scrollSelectionToVisible()
    }

    static func keepLinesMatching(query: String, useRegex: Bool, caseSensitive: Bool) throws {
        try applyLineFilter(query: query, useRegex: useRegex, caseSensitive: caseSensitive, keepMatching: true)
    }

    static func removeLinesMatching(query: String, useRegex: Bool, caseSensitive: Bool) throws {
        try applyLineFilter(query: query, useRegex: useRegex, caseSensitive: caseSensitive, keepMatching: false)
    }

    private static func applyLineFilter(
        query: String,
        useRegex: Bool,
        caseSensitive: Bool,
        keepMatching: Bool
    ) throws {
        guard let textView = actions else { return }
        let matcher = try LineMatcher(query: query, useRegex: useRegex, caseSensitive: caseSensitive)
        let separator = state?.lineEnding.string ?? "\n"
        let trailing = textView.text.hasSuffix(separator)
        var lines = textView.text.components(separatedBy: separator)
        if trailing && lines.last == "" { lines.removeLast() }
        let filtered = lines.filter { keepMatching ? matcher.matches($0) : !matcher.matches($0) }
        var result = filtered.joined(separator: separator)
        if trailing { result += separator }
        replaceWholeText(with: result)
        state?.setText?(result)
    }

    private struct LineMatcher {
        private let regex: NSRegularExpression?
        private let needle: String
        private let caseSensitive: Bool
        private let useRegex: Bool

        init(query: String, useRegex: Bool, caseSensitive: Bool) throws {
            self.useRegex = useRegex
            self.caseSensitive = caseSensitive
            self.needle = query
            if useRegex {
                let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                do {
                    self.regex = try NSRegularExpression(pattern: query, options: options)
                } catch {
                    throw LineMatchError.invalidRegex(query)
                }
            } else {
                self.regex = nil
            }
        }

        func matches(_ line: String) -> Bool {
            if let regex {
                let range = NSRange(line.startIndex..., in: line)
                return regex.firstMatch(in: line, range: range) != nil
            }
            if caseSensitive { return line.contains(needle) }
            return line.range(of: needle, options: .caseInsensitive) != nil
        }
    }
}
