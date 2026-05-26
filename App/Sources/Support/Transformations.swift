import Foundation

private extension String {
    /// Pad with leading spaces so the total width is at least `width`.
    func padded(toLeftWidth width: Int) -> String {
        guard count < width else { return self }
        return String(repeating: " ", count: width - count) + self
    }
}

/// Text transformations exposed under the Text menu.
///
/// Each pure function takes a string and returns the transformed result.
/// They operate on whole input — callers slice by selection.
enum Transformations {

    // MARK: - Case conversion

    /// Title Case following common American (Chicago-ish) usage:
    /// - First and last words are always capitalized.
    /// - "Major" words are capitalized (nouns, verbs, adjectives, adverbs).
    /// - Articles, coordinating conjunctions, and short prepositions are
    ///   lowercased unless they are the first or last word.
    /// - Whitespace and punctuation are preserved.
    static func titleCase(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        var ranges: [Range<String.Index>] = []
        input.enumerateSubstrings(
            in: input.startIndex..<input.endIndex,
            options: .byWords
        ) { _, range, _, _ in
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return input }

        var result = input
        // Walk in reverse so earlier indices remain valid as we replace.
        for (offset, range) in ranges.enumerated().reversed() {
            let word = String(input[range])
            let lower = word.lowercased()
            let isFirstOrLast = (offset == 0) || (offset == ranges.count - 1)
            let replacement: String
            if !isFirstOrLast && titleCaseLowercaseWords.contains(lower) {
                replacement = lower
            } else {
                replacement = capitalizeFirst(word)
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func snakeCase(_ input: String) -> String {
        components(of: input)
            .map { $0.lowercased() }
            .joined(separator: "_")
    }

    static func kebabCase(_ input: String) -> String {
        components(of: input)
            .map { $0.lowercased() }
            .joined(separator: "-")
    }

    static func camelCase(_ input: String) -> String {
        let parts = components(of: input)
        guard let first = parts.first else { return input }
        let rest = parts.dropFirst().map(capitalizeFirst)
        return ([first.lowercased()] + rest).joined()
    }

    static func pascalCase(_ input: String) -> String {
        components(of: input).map(capitalizeFirst).joined()
    }

    // MARK: - Unicode normalization

    static func normalize(_ input: String, form: NormalizationForm) -> String {
        switch form {
        case .nfc:  return input.precomposedStringWithCanonicalMapping
        case .nfd:  return input.decomposedStringWithCanonicalMapping
        case .nfkc: return input.precomposedStringWithCompatibilityMapping
        case .nfkd: return input.decomposedStringWithCompatibilityMapping
        }
    }

    enum NormalizationForm { case nfc, nfd, nfkc, nfkd }

    // MARK: - Encoding

    static func urlEncode(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
    }

    static func urlDecode(_ input: String) -> String {
        input.removingPercentEncoding ?? input
    }

    static func base64Encode(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return input }
        return data.base64EncodedString()
    }

    static func base64Decode(_ input: String) -> String {
        guard let data = Data(base64Encoded: input, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8)
        else { return input }
        return decoded
    }

    // MARK: - Selection ops

    static func reverseCharacters(_ input: String) -> String {
        String(input.reversed())
    }

    // MARK: - Helpers

    /// Splits an arbitrary identifier-ish input into "words":
    /// - underscore-separated, hyphen-separated, space-separated, or camelCase boundaries.
    private static func components(of input: String) -> [String] {
        // Replace separators with spaces, then split on camelCase boundaries.
        let separatorsReplaced = input
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        // Insert space before each uppercase letter that follows a lowercase letter or digit.
        var spaced = ""
        var previous: Character? = nil
        for character in separatorsReplaced {
            if let p = previous,
               (p.isLowercase || p.isNumber),
               character.isUppercase {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }

        return spaced
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    /// Curated lowercase-unless-first-or-last word list for Title Case.
    /// Articles + coordinating conjunctions + short prepositions + a few extras.
    private static let titleCaseLowercaseWords: Set<String> = [
        "a", "an", "the",
        "and", "but", "for", "nor", "or", "so", "yet",
        "as", "if", "than",
        "at", "by", "in", "of", "off", "on", "out", "per",
        "to", "up", "via", "with", "from", "into", "onto",
        "over", "down", "near", "till", "upon"
    ]

    // MARK: - Paragraph helpers

    /// Splits `text` into paragraphs separated by blank lines (one or
    /// more lines containing only whitespace). Each returned chunk
    /// keeps its internal line breaks; only the blank delimiters are
    /// dropped. Used by the Add/Remove Linebreaks commands.
    static func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs
    }

    // MARK: - Lipsum

    /// Returns `n` paragraphs of classic Lorem Ipsum text, separated by
    /// `separator` (typically `"\n\n"`). The first paragraph always
    /// starts with the canonical "Lorem ipsum dolor sit amet…" opening.
    static func lipsum(paragraphs n: Int, separator: String) -> String {
        guard n > 0 else { return "" }
        var rng = SystemRandomNumberGenerator()
        let paragraphs = (0..<n).map { idx -> String in
            let opener = idx == 0 ? lipsumOpener : nil
            let sentenceCount = Int.random(in: 3...6, using: &rng)
            var sentences: [String] = []
            if let opener { sentences.append(opener) }
            while sentences.count < sentenceCount {
                let len = Int.random(in: 6...18, using: &rng)
                var words: [String] = []
                for _ in 0..<len { words.append(lipsumWords.randomElement(using: &rng) ?? "lorem") }
                var s = words.joined(separator: " ")
                s = s.prefix(1).uppercased() + s.dropFirst() + "."
                sentences.append(s)
            }
            return sentences.joined(separator: " ")
        }
        return paragraphs.joined(separator: separator)
    }

    private static let lipsumOpener = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
    private static let lipsumWords: [String] = [
        "lorem","ipsum","dolor","sit","amet","consectetur","adipiscing","elit","sed","do",
        "eiusmod","tempor","incididunt","ut","labore","et","dolore","magna","aliqua","enim",
        "ad","minim","veniam","quis","nostrud","exercitation","ullamco","laboris","nisi","aliquip",
        "ex","ea","commodo","consequat","duis","aute","irure","reprehenderit","voluptate","velit",
        "esse","cillum","dolore","fugiat","nulla","pariatur","excepteur","sint","occaecat","cupidatat",
        "non","proident","sunt","in","culpa","officia","deserunt","mollit","anim","id","est","laborum"
    ]

    // MARK: - Line-wise prefix / suffix / numbering

    /// Prepend `prefix` to every line in `text`. Line endings (`\n`,
    /// `\r`, `\r\n`) are preserved.
    static func prefixLines(_ text: String, with prefix: String) -> String {
        mapLines(text) { prefix + $0 }
    }

    /// Append `suffix` to the end of every line in `text` (before the
    /// line break).
    static func suffixLines(_ text: String, with suffix: String) -> String {
        mapLines(text) { $0 + suffix }
    }

    /// Prefix every line with a 1-based, right-aligned line number and
    /// a `". "` separator. Trailing newlines are preserved.
    static func addLineNumbers(_ text: String) -> String {
        let lines = splitKeepingNewlines(text)
        let width = String(lines.count).count
        return lines.enumerated().map { (idx, line) -> String in
            let (body, sep) = splitTrailingNewline(line)
            let padded = String(idx + 1).padded(toLeftWidth: width)
            return "\(padded). \(body)\(sep)"
        }.joined()
    }

    /// Strips a leading "N. " (or "N) " or " N. ") number prefix from
    /// every line. Lines without a prefix are passed through unchanged.
    static func removeLineNumbers(_ text: String) -> String {
        mapLines(text) { line in
            var i = line.startIndex
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            guard i < line.endIndex, line[i].isNumber else { return line }
            var j = i
            while j < line.endIndex, line[j].isNumber { j = line.index(after: j) }
            guard j < line.endIndex, line[j] == "." || line[j] == ")" else { return line }
            var k = line.index(after: j)
            while k < line.endIndex, line[k] == " " { k = line.index(after: k) }
            return String(line[k..<line.endIndex])
        }
    }

    /// Drop lines that contain only whitespace.
    static func removeBlankLines(_ text: String) -> String {
        splitKeepingNewlines(text)
            .filter { !splitTrailingNewline($0).0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
    }

    /// Prepend `"> "` to every line — the markdown "increase quote
    /// level" gesture. Already-quoted lines just get another level.
    static func increaseQuoteLevel(_ text: String) -> String {
        mapLines(text) { "> \($0)" }
    }

    /// Strip a single leading `>` (with optional space) from each line.
    /// Lines without a quote marker pass through.
    static func decreaseQuoteLevel(_ text: String) -> String {
        mapLines(text) { line in
            guard line.hasPrefix(">") else { return line }
            let after = line.dropFirst()
            if let first = after.first, first == " " { return String(after.dropFirst()) }
            return String(after)
        }
    }

    // MARK: - Whitespace / encoding

    /// Collapse runs of spaces+tabs within each line to a single space.
    /// Newlines are preserved as-is. Leading/trailing whitespace on each
    /// line is preserved (use `trim` for that).
    static func normalizeSpaces(_ text: String) -> String {
        mapLines(text) { line in
            // Walk the line once; replace consecutive (space|tab) runs.
            var out = ""
            out.reserveCapacity(line.count)
            var lastWasSpace = false
            for ch in line {
                if ch == " " || ch == "\t" {
                    if !lastWasSpace { out.append(" "); lastWasSpace = true }
                } else {
                    out.append(ch); lastWasSpace = false
                }
            }
            return out
        }
    }

    /// Replace tabs with `width` spaces. Naive — doesn't account for
    /// column position (most "fancy" editors don't either when bulk-
    /// converting; column-aware expansion is rarely what's wanted).
    static func tabsToSpaces(_ text: String, tabWidth: Int) -> String {
        let pad = String(repeating: " ", count: max(1, tabWidth))
        return text.replacingOccurrences(of: "\t", with: pad)
    }

    /// Convert runs of `tabWidth` leading spaces to single tabs on
    /// each line. Only operates on the leading-indent region; spaces
    /// inside the body are preserved (so prose isn't mangled).
    static func spacesToTabs(_ text: String, tabWidth: Int) -> String {
        guard tabWidth > 0 else { return text }
        return mapLines(text) { line in
            var i = line.startIndex
            var leading = 0
            while i < line.endIndex, line[i] == " " {
                leading += 1
                i = line.index(after: i)
            }
            let tabs = leading / tabWidth
            let rem = leading % tabWidth
            return String(repeating: "\t", count: tabs)
                + String(repeating: " ", count: rem)
                + line[i..<line.endIndex]
        }
    }

    /// Replace every line ending (`\n`, `\r`, `\r\n`) with `ending`.
    static func normalizeLineEndings(_ text: String, to ending: String) -> String {
        // Normalise CRLF first to LF, then translate every CR / LF.
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return lf.replacingOccurrences(of: "\n", with: ending)
    }

    /// "Zap gremlins" — strip ASCII control characters (except
    /// newline/CR/tab) and zero-width / private-use / non-character
    /// Unicode noise that often sneaks in from PDFs, Word, etc.
    /// One-shot variant kept for backwards-compatible quick calls;
    /// the sheet UI prefers `zapGremlins(_:options:)`.
    static func zapGremlins(_ text: String) -> String {
        zapGremlins(text, options: ZapGremlinsOptions())
    }

    /// Configurable Zap Gremlins. Each toggle selects a category of
    /// "gremlin"; `replacement` is the string substituted in (empty =
    /// delete).
    static func zapGremlins(_ text: String, options: ZapGremlinsOptions) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            for scalar in ch.unicodeScalars {
                if options.isGremlin(scalar) {
                    out.append(options.replacement)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Remove combining marks (NFD-decompose, drop combining range,
    /// recompose). `café` → `cafe`, `naïve` → `naive`.
    static func stripDiacritics(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.decomposedStringWithCanonicalMapping
        var out = String()
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            out.unicodeScalars.append(scalar)
        }
        return out.precomposedStringWithCanonicalMapping
    }

    /// Best-effort transliteration to ASCII. Uses Latin → ASCII via
    /// `CFStringTransform`, then strips anything still non-ASCII.
    static func convertToASCII(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Any-Latin; Latin-ASCII" as NSString, false)
        let folded = mutable as String
        return String(folded.unicodeScalars.filter { $0.value < 128 })
    }

    /// Interpret `\n`, `\t`, `\r`, `\\`, `\"`, `\'`, `\xHH`, `\uHHHH`
    /// escape sequences as their literal characters. Unknown escapes
    /// pass through unchanged.
    static func interpretEscapeSequences(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\\", let next = text.index(i, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex {
                let esc = text[next]
                switch esc {
                case "n": out.append("\n"); i = text.index(after: next)
                case "t": out.append("\t"); i = text.index(after: next)
                case "r": out.append("\r"); i = text.index(after: next)
                case "\\": out.append("\\"); i = text.index(after: next)
                case "\"": out.append("\""); i = text.index(after: next)
                case "'": out.append("'"); i = text.index(after: next)
                case "0": out.append("\0"); i = text.index(after: next)
                case "x":
                    if let hex = takeHex(in: text, from: text.index(after: next), count: 2),
                       let val = UInt32(hex.0, radix: 16),
                       let scalar = Unicode.Scalar(val) {
                        out.unicodeScalars.append(scalar)
                        i = hex.1
                    } else { out.append(ch); i = text.index(after: i) }
                case "u":
                    if let hex = takeHex(in: text, from: text.index(after: next), count: 4),
                       let val = UInt32(hex.0, radix: 16),
                       let scalar = Unicode.Scalar(val) {
                        out.unicodeScalars.append(scalar)
                        i = hex.1
                    } else { out.append(ch); i = text.index(after: i) }
                default: out.append(ch); i = text.index(after: i)
                }
            } else {
                out.append(ch); i = text.index(after: i)
            }
        }
        return out
    }

    /// Inverse of `interpretEscapeSequences` for the common cases: turn
    /// real newline/tab/CR/backslash into `\n`, `\t`, `\r`, `\\`.
    static func escapeSpecialCharacters(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            case "\\": out.append("\\\\")
            default:   out.append(ch)
            }
        }
        return out
    }

    /// "Educate" straight quotes into typographer's quotes. Tries to
    /// pick opening vs. closing based on the surrounding character
    /// (whitespace → opening; word char → closing). Apostrophe in
    /// contractions becomes `’`.
    static func educateQuotes(_ text: String) -> String {
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let openingContext = (prev == nil) || prev!.isWhitespace || "([{<«—–-".contains(prev!)
            switch ch {
            case "\"":
                out.append(openingContext ? "\u{201C}" : "\u{201D}")
            case "'":
                out.append(openingContext ? "\u{2018}" : "\u{2019}")
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// Reverse of `educateQuotes` — collapse curly quotes back to
    /// straight ASCII versions.
    static func straightenQuotes(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": out.append("\"")
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Helpers (line-wise)

    /// Apply `f` to each line's body (newline characters preserved).
    /// Used by the prefix/suffix/quote-level/etc helpers above so
    /// they share a single, correctness-tested splitter.
    private static func mapLines(_ text: String, _ f: (String) -> String) -> String {
        splitKeepingNewlines(text).map { piece -> String in
            let (body, nl) = splitTrailingNewline(piece)
            return f(body) + nl
        }.joined()
    }

    /// Split `text` into pieces, each piece being one line **including
    /// its trailing line break**. The final piece carries no break if
    /// the source ends mid-line.
    private static func splitKeepingNewlines(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            current.append(ch)
            if ch == "\n" {
                pieces.append(current); current.removeAll(keepingCapacity: true)
                i = text.index(after: i)
            } else if ch == "\r" {
                if let next = text.index(i, offsetBy: 1, limitedBy: text.endIndex),
                   next < text.endIndex, text[next] == "\n" {
                    current.append("\n")
                    i = text.index(after: next)
                } else {
                    i = text.index(after: i)
                }
                pieces.append(current); current.removeAll(keepingCapacity: true)
            } else {
                i = text.index(after: i)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func splitTrailingNewline(_ piece: String) -> (String, String) {
        if piece.hasSuffix("\r\n") { return (String(piece.dropLast(2)), "\r\n") }
        if piece.hasSuffix("\n")   { return (String(piece.dropLast()),  "\n") }
        if piece.hasSuffix("\r")   { return (String(piece.dropLast()),  "\r") }
        return (piece, "")
    }

    /// Read up to `count` hex digits from `text` starting at `start`.
    /// Returns the substring and the index just past the last digit
    /// consumed, or `nil` if we couldn't read any.
    private static func takeHex(in text: String, from start: String.Index, count: Int) -> (String, String.Index)? {
        var i = start
        var consumed = 0
        var out = ""
        while consumed < count, i < text.endIndex, text[i].isHexDigit {
            out.append(text[i])
            i = text.index(after: i)
            consumed += 1
        }
        return out.isEmpty ? nil : (out, i)
    }

    /// Greedy word-wrap `paragraph` to `column` characters per line,
    /// joining wrapped lines with `separator`. Whitespace inside the
    /// paragraph is normalised to single spaces first so existing
    /// hard wraps don't survive. A run of word + space won't be
    /// broken mid-word — words longer than the column appear on a
    /// line of their own.
    static func wordWrap(_ paragraph: String, to column: Int, separator: String) -> String {
        let words = paragraph
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= column {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: separator)
    }
}

/// What counts as a "gremlin" and what to put in its place. Mirrors
/// the categories surfaced in BBEdit's Zap Gremlins dialog.
struct ZapGremlinsOptions: Equatable {
    /// C0 (0x00–0x1F except TAB/LF/CR), DEL (0x7F), and C1 (0x80–0x9F).
    var asciiControl: Bool = true
    /// Zero-width joiners, BOM, word joiner, language tags, etc.
    var invisibleUnicode: Bool = true
    /// Anything with a Unicode scalar value above 0x7F.
    var nonAscii: Bool = false
    /// Empty string = delete the gremlin outright.
    var replacement: String = ""

    func isGremlin(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if asciiControl {
            if v < 0x20, v != 0x09, v != 0x0A, v != 0x0D { return true }
            if v == 0x7F { return true }
            if (0x80...0x9F).contains(v) { return true }
        }
        if invisibleUnicode {
            if (0x200B...0x200F).contains(v) { return true }
            if v == 0xFEFF { return true }
            if (0x2060...0x206F).contains(v) { return true }
        }
        if nonAscii, v > 0x7F { return true }
        return false
    }
}
