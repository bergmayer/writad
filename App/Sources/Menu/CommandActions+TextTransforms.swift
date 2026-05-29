import Foundation
import UIKit

extension CommandActions {

    // MARK: - Reflow paragraph (BBEdit hard-wrap)

    /// Hard-wrap the selected text (or current paragraph if no
    /// selection) at `column`. Preserves leading `>` quote prefixes
    /// per line so reflowing email/forum replies stays sane —
    /// strips them, wraps the body, re-applies them on output.
    static func reflowParagraph(column: Int = 80) {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let target: NSRange = {
            let sel = textView.selectedRange
            if sel.length > 0 { return nsText.lineRange(for: sel) }
            // Empty selection: expand to the current "paragraph" —
            // the run of non-blank lines around the cursor.
            return Self.paragraphRange(in: nsText, around: sel.location)
        }()
        guard target.length > 0, let block = textView.text(in: target) else { return }

        let reflowed = Self.reflow(block: block, column: max(20, column))
        textView.replace(target, withText: reflowed)
        commitTextChange()
    }

    /// Wrap `block` to `column` columns, preserving the leading
    /// `> ` quote prefix shared by its lines (or matched per-line
    /// when prefixes differ).
    private static func reflow(block: String, column: Int) -> String {
        let nl = state?.lineEnding.string ?? "\n"
        var lines = block.components(separatedBy: .newlines)
        // Drop trailing empty (from final separator).
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return block }

        // Quote prefix = leading sequence of `>` + space, captured
        // from the first line; if any line has a different prefix,
        // fall through to the no-prefix path.
        let firstPrefix = quotePrefix(of: lines[0])
        let samePrefix = lines.allSatisfy { quotePrefix(of: $0) == firstPrefix }
        let prefix = samePrefix ? firstPrefix : ""
        let bodyText = lines
            .map { samePrefix ? String($0.dropFirst(firstPrefix.count)) : $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let words = bodyText.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return block }

        var output: [String] = []
        var current = prefix
        let bodyBudget = max(1, column - prefix.count)
        for word in words {
            let wordStr = String(word)
            let needed = current == prefix
                ? wordStr.count
                : (current.count - prefix.count) + 1 + wordStr.count
            if needed > bodyBudget && current != prefix {
                output.append(current)
                current = prefix + wordStr
            } else if current == prefix {
                current += wordStr
            } else {
                current += " " + wordStr
            }
        }
        if !current.isEmpty { output.append(current) }
        return output.joined(separator: nl) + nl
    }

    /// `> ` or `>> ` etc. prefix at the start of a quoted line.
    /// Empty for unquoted lines.
    private static func quotePrefix(of line: String) -> String {
        var i = line.startIndex
        while i < line.endIndex, line[i] == ">" {
            i = line.index(after: i)
        }
        // Optional single trailing space after the run of `>`.
        if i < line.endIndex, line[i] == " " {
            i = line.index(after: i)
        }
        return String(line[..<i])
    }

    /// Expand a single-cursor location to the surrounding "paragraph"
    /// (non-blank run of lines). Returns the cursor's line if it
    /// sits on a blank line.
    private static func paragraphRange(in nsText: NSString, around location: Int) -> NSRange {
        let line = nsText.lineRange(for: NSRange(location: location, length: 0))
        var startLine = line
        while startLine.location > 0 {
            let prevLine = nsText.lineRange(for: NSRange(location: startLine.location - 1, length: 0))
            let body = nsText.substring(with: prevLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { break }
            startLine = prevLine
        }
        var endLine = line
        while endLine.location + endLine.length < nsText.length {
            let nextLine = nsText.lineRange(for: NSRange(location: endLine.location + endLine.length, length: 0))
            let body = nsText.substring(with: nextLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { break }
            endLine = nextLine
        }
        return NSRange(location: startLine.location,
                       length: endLine.location + endLine.length - startLine.location)
    }

    // MARK: - Sort by regex capture

    /// Sort the selected lines (or whole document) using a regex
    /// capture group as the sort key. `pattern` is matched against
    /// each line; `captureIndex` (1-based) names which capture
    /// group's value sorts. Lines that don't match sort to the end
    /// (or start, in descending order).
    static func sortLinesByCapture(_ pattern: String, captureIndex: Int = 1, ascending: Bool = true) {
        guard let textView = actions else { return }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            Self.context.presentation.openErrorMessage = "Bad sort pattern: \(pattern)"
            return
        }
        let nsText = textView.text as NSString
        let sel = textView.selectedRange
        let targetRange = sel.length > 0
            ? nsText.lineRange(for: sel)
            : NSRange(location: 0, length: nsText.length)
        guard let body = textView.text(in: targetRange) else { return }
        let nl = state?.lineEnding.string ?? "\n"
        let lines = body.components(separatedBy: .newlines)
        let trailingEmpty = lines.last == ""
        let payload = trailingEmpty ? Array(lines.dropLast()) : lines

        let sorted = payload.sorted { a, b in
            let keyA = Self.captureKey(in: a, regex: regex, captureIndex: captureIndex)
            let keyB = Self.captureKey(in: b, regex: regex, captureIndex: captureIndex)
            switch (keyA, keyB) {
            case (.some(let x), .some(let y)): return ascending ? x < y : x > y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
        var output = sorted.joined(separator: nl)
        if trailingEmpty { output += nl }
        textView.replace(targetRange, withText: output)
        commitTextChange()
    }

    private static func captureKey(in line: String,
                                    regex: NSRegularExpression,
                                    captureIndex: Int) -> String? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              captureIndex < match.numberOfRanges
        else { return nil }
        let r = match.range(at: captureIndex)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    // MARK: - Process Lines Containing (BBEdit)

    enum ProcessLinesAction {
        case keepMatching
        case deleteMatching
        case copyMatchingToClipboard
    }

    /// Filter the document (or selection) line-by-line against
    /// `pattern`. `regex == false` runs a substring contains check.
    /// `invert == true` operates on lines that DON'T match.
    static func processLines(pattern: String,
                              regex: Bool,
                              invert: Bool,
                              action: ProcessLinesAction) {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let sel = textView.selectedRange
        let scopeRange = sel.length > 0
            ? nsText.lineRange(for: sel)
            : NSRange(location: 0, length: nsText.length)
        guard let body = textView.text(in: scopeRange) else { return }
        let nl = state?.lineEnding.string ?? "\n"
        let lines = body.components(separatedBy: .newlines)
        let trailingEmpty = lines.last == ""
        let payload = trailingEmpty ? Array(lines.dropLast()) : lines

        let regexObj: NSRegularExpression? = regex ? (try? NSRegularExpression(pattern: pattern)) : nil
        if regex, regexObj == nil {
            Self.context.presentation.openErrorMessage = "Bad pattern: \(pattern)"
            return
        }
        let matches: (String) -> Bool = { line in
            if let regexObj {
                let r = NSRange(location: 0, length: (line as NSString).length)
                return regexObj.firstMatch(in: line, range: r) != nil
            }
            return line.contains(pattern)
        }
        let kept = payload.filter { invert ? !matches($0) : matches($0) }

        switch action {
        case .keepMatching:
            var output = kept.joined(separator: nl)
            if trailingEmpty { output += nl }
            textView.replace(scopeRange, withText: output)
            commitTextChange()
        case .deleteMatching:
            let surviving = payload.filter { invert ? matches($0) : !matches($0) }
            var output = surviving.joined(separator: nl)
            if trailingEmpty { output += nl }
            textView.replace(scopeRange, withText: output)
            commitTextChange()
        case .copyMatchingToClipboard:
            UIPasteboard.general.string = kept.joined(separator: nl)
        }
    }

    // MARK: - Canonize

    /// Apply a saved list of find/replace pairs (one pair per line,
    /// separated by a tab — left = find, right = replace) in order
    /// against the selection or whole document. `regex == true`
    /// treats the find side as a regular expression.
    static func applyCanonizePairs(_ raw: String, regex: Bool) {
        guard let textView = actions else { return }
        let pairs: [(find: String, replace: String)] = raw
            .components(separatedBy: .newlines)
            .compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { return nil }
                let find = parts[0]
                let replace = parts.dropFirst().joined(separator: "\t")
                guard !find.isEmpty else { return nil }
                return (find, replace)
            }
        guard !pairs.isEmpty else { return }

        let sel = textView.selectedRange
        let scope = sel.length > 0
            ? sel
            : NSRange(location: 0, length: (textView.text as NSString).length)
        guard let original = textView.text(in: scope) else { return }
        var working = original
        for pair in pairs {
            if regex {
                guard let r = try? NSRegularExpression(pattern: pair.find) else { continue }
                let range = NSRange(location: 0, length: (working as NSString).length)
                working = r.stringByReplacingMatches(in: working, range: range, withTemplate: pair.replace)
            } else {
                working = working.replacingOccurrences(of: pair.find, with: pair.replace)
            }
        }
        textView.replace(scope, withText: working)
        commitTextChange()
    }

    // MARK: - Case / encoding transformations

    static func uppercase()      { transformSelection { $0.uppercased() } }
    static func lowercase()      { transformSelection { $0.lowercased() } }
    static func capitalize()     { transformSelection { $0.capitalized } }
    static func titleCase()      { transformSelection(Transformations.titleCase) }
    static func snakeCase()      { transformSelection(Transformations.snakeCase) }
    static func kebabCase()      { transformSelection(Transformations.kebabCase) }
    static func camelCase()      { transformSelection(Transformations.camelCase) }
    static func pascalCase()     { transformSelection(Transformations.pascalCase) }

    static func normalizeNFC()   { transformSelection { Transformations.normalize($0, form: .nfc) } }
    static func normalizeNFD()   { transformSelection { Transformations.normalize($0, form: .nfd) } }
    static func normalizeNFKC()  { transformSelection { Transformations.normalize($0, form: .nfkc) } }
    static func normalizeNFKD()  { transformSelection { Transformations.normalize($0, form: .nfkd) } }

    static func urlEncode()      { transformSelection(Transformations.urlEncode) }
    static func urlDecode()      { transformSelection(Transformations.urlDecode) }
    static func base64Encode()   { transformSelection(Transformations.base64Encode) }
    static func base64Decode()   { transformSelection(Transformations.base64Decode) }

    static func reverseSelection() { transformSelection(Transformations.reverseCharacters) }
}
