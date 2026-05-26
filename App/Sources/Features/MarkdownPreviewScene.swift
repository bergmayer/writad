import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Markdown preview, rendered the same way regardless of host. iPad
/// presents this inside a dedicated WindowGroup scene; iPhone (which
/// can't host extra windows) presents it as a dismissable sheet —
/// see `MarkdownPreviewSheet` and `MarkdownPreviewScene` below. Output
/// is a WKWebView hosting an HTML scaffold built by `MarkdownRenderer`.
///
/// Toolbar exposes a Share button — the system share sheet's "Print"
/// flow includes "Save as PDF", which is the iPad-native way to turn
/// the preview into a PDF.
struct MarkdownPreviewContent: View {

    /// How to dismiss this view. Scene version calls `dismissWindow`;
    /// sheet version calls SwiftUI's `dismiss`. Optional Done button
    /// is hidden when nil — useful if the host already has its own.
    var onDone: (() -> Void)?

    @State private var renderedHTML: String = ""
    /// Snapshot of the markdown source we last rendered — used to
    /// throttle re-renders when the editor text changes.
    @State private var lastSource: String = ""

    var body: some View {
        NavigationStack {
            MarkdownWebView(html: renderedHTML)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done", action: onDone).bold()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: htmlExportURL,
                                  preview: SharePreview(currentTitle))
                    }
                }
        }
        .onAppear { rerender() }
        // Pick up changes to the underlying document. EditorState is
        // a class so `text` mutations don't drive SwiftUI directly;
        // we re-read from `AppStateBus` on a short timer instead.
        // 600 ms is far enough below typing speed to feel "live" but
        // doesn't thrash the WebView while the user is typing fast.
        .task(id: lastSource) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                rerender()
            }
        }
    }

    private func rerender() {
        let src = AppStateBus.shared.scenes.currentSession?
            .activeTab.document.text ?? ""
        guard src != lastSource else { return }
        lastSource = src
        renderedHTML = MarkdownRenderer.html(for: src, title: currentTitle)
    }

    private var currentTitle: String {
        AppStateBus.shared.scenes.currentSession?
            .activeTab.document.fileURL?
            .deletingPathExtension()
            .lastPathComponent ?? "Untitled"
    }

    /// Temporary URL that ShareLink hands the system — backs an
    /// `.html` file written into the scratch sandbox each time the
    /// share sheet is opened. The system's Print → Save as PDF flow
    /// in the share sheet renders the HTML to PDF.
    private var htmlExportURL: URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(currentTitle).html")
        let safeHTML = renderedHTML.isEmpty
            ? MarkdownRenderer.html(for: lastSource, title: currentTitle)
            : renderedHTML
        try? safeHTML.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// iPad/multi-window host for the preview. Opened via
/// `openWindow(id: SceneID.markdownPreview.rawValue)`.
struct MarkdownPreviewScene: View {

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        MarkdownPreviewContent(onDone: {
            dismissWindow(id: SceneID.markdownPreview.rawValue)
        })
        .onAppear {
            // Guard the same way the file browser does — if iPadOS
            // restored the preview window after a quit, drop it.
            if !AppStateBus.shared.scenes.consumeOpen(.markdownPreview) {
                dismissWindow(id: SceneID.markdownPreview.rawValue)
            }
        }
    }
}

/// iPhone host for the preview. Routed via `.sheet(item:)` because
/// iPhone is single-window — `openWindow` is a no-op there. The user
/// dismisses with the toolbar Done button or a swipe.
struct MarkdownPreviewSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarkdownPreviewContent(onDone: { dismiss() })
    }
}

// MARK: - WebView host

private struct MarkdownWebView: UIViewRepresentable {

    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // No JS bridge needed — the markdown rendering runs entirely
        // inside the HTML scaffold via `marked.js`.
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Renderer

/// Wraps the markdown source in a self-contained HTML document that
/// pulls in `marked.js` (vendored as a string at the bottom) and runs
/// it against the source. Styles match the active color scheme so
/// the preview tracks dark/light mode.
enum MarkdownRenderer {

    static func html(for source: String, title: String) -> String {
        let body = SwiftMarkdown.render(source)
        let titleEscaped = htmlEscape(title)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(titleEscaped)</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          font: 16px/1.55 -apple-system, system-ui, sans-serif;
          margin: 0 auto;
          padding: 24px 32px 64px;
          max-width: 760px;
          color: -apple-system-label;
          background: -apple-system-background;
        }
        h1, h2, h3, h4, h5, h6 {
          font-weight: 600;
          margin: 1.6em 0 0.6em;
          line-height: 1.25;
        }
        h1 { font-size: 2em; border-bottom: 1px solid rgba(127,127,127,0.3); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid rgba(127,127,127,0.2); padding-bottom: 0.2em; }
        h3 { font-size: 1.25em; }
        p  { margin: 0.8em 0; }
        a  { color: #0a84ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
          font: 0.92em SF Mono, Menlo, monospace;
          background: rgba(127,127,127,0.18);
          padding: 0.12em 0.35em;
          border-radius: 4px;
        }
        pre {
          background: rgba(127,127,127,0.12);
          border-radius: 8px;
          padding: 14px 16px;
          overflow: auto;
        }
        pre code { background: transparent; padding: 0; font-size: 0.92em; }
        blockquote {
          border-left: 4px solid rgba(127,127,127,0.4);
          margin: 1em 0;
          padding: 0.1em 1em;
          color: rgba(127,127,127,1);
        }
        hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 2em 0; }
        ul, ol { padding-left: 1.4em; }
        sup a { font-size: 0.75em; }
        .footnotes { font-size: 0.92em; border-top: 1px solid rgba(127,127,127,0.3); margin-top: 3em; padding-top: 1em; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - SwiftMarkdown

/// A small, self-contained Markdown → HTML converter. Covers the
/// subset every casual markdown user writes: ATX headers, bold /
/// italic / strike / inline code, fenced + indented code, ordered &
/// unordered lists, blockquotes, horizontal rules, inline links &
/// images, hard line-breaks, and the GFM-style footnote extension
/// (`[^id]` references with matching `[^id]:` definitions).
///
/// Intentionally NOT a full CommonMark implementation — tables,
/// nested-list indentation rules, HTML inlining and reference-style
/// links are skipped. Good enough for a live preview while typing;
/// users who want bit-perfect rendering can Share → Open the
/// `.html` in Safari or use a dedicated previewer.
enum SwiftMarkdown {

    static func render(_ source: String) -> String {
        var parser = Parser(lines: source.components(separatedBy: "\n"))
        parser.parse()
        return parser.html
    }

    fileprivate struct Footnote {
        var id: String
        var body: String
    }

    fileprivate struct Parser {
        var lines: [String]
        var html: String = ""
        var footnotes: [Footnote] = []
        private var index = 0

        init(lines: [String]) {
            self.lines = lines
        }

        mutating func parse() {
            // Pass 1: extract footnote definitions (`[^id]: …`) so
            // they don't appear inline in the body and so the
            // references in pass 2 know what's defined.
            var bodyLines: [String] = []
            var i = 0
            while i < lines.count {
                let line = lines[i]
                if let defMatch = footnoteDefinitionMatch(line) {
                    var collected = defMatch.body
                    // Continuation lines: indented 4+ spaces or tab.
                    var j = i + 1
                    while j < lines.count {
                        let next = lines[j]
                        if next.hasPrefix("    ") || next.hasPrefix("\t") {
                            let trimmed = next.drop(while: { $0 == " " || $0 == "\t" })
                            collected += "\n" + String(trimmed)
                            j += 1
                        } else if next.trimmingCharacters(in: .whitespaces).isEmpty {
                            j += 1
                        } else { break }
                    }
                    footnotes.append(Footnote(id: defMatch.id, body: collected))
                    i = j
                    continue
                }
                bodyLines.append(line)
                i += 1
            }
            lines = bodyLines
            index = 0

            // Pass 2: block-level parse.
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    continue
                }
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    consumeFencedCodeBlock(fence: String(line.prefix(3)))
                } else if isHorizontalRule(line) {
                    html += "<hr>\n"
                    index += 1
                } else if let header = headerMatch(line) {
                    html += "<h\(header.level)>\(inline(header.text))</h\(header.level)>\n"
                    index += 1
                } else if line.hasPrefix("> ") || line == ">" {
                    consumeBlockquote()
                } else if isUnorderedListItem(line) {
                    consumeList(ordered: false)
                } else if isOrderedListItem(line) {
                    consumeList(ordered: true)
                } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                    consumeIndentedCodeBlock()
                } else {
                    consumeParagraph()
                }
            }

            if !footnotes.isEmpty {
                appendFootnotes()
            }
        }

        // MARK: Block helpers

        private mutating func consumeFencedCodeBlock(fence: String) {
            index += 1
            var code = ""
            while index < lines.count, !lines[index].hasPrefix(fence) {
                code += htmlEscape(lines[index]) + "\n"
                index += 1
            }
            if index < lines.count { index += 1 }  // skip closing fence
            html += "<pre><code>\(code)</code></pre>\n"
        }

        private mutating func consumeIndentedCodeBlock() {
            var code = ""
            while index < lines.count,
                  (lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t")) {
                let trimmed = lines[index].hasPrefix("\t")
                    ? String(lines[index].dropFirst())
                    : String(lines[index].dropFirst(4))
                code += htmlEscape(trimmed) + "\n"
                index += 1
            }
            html += "<pre><code>\(code)</code></pre>\n"
        }

        private mutating func consumeBlockquote() {
            var inner = ""
            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("> ") {
                    inner += inline(String(line.dropFirst(2))) + "<br>\n"
                    index += 1
                } else if line == ">" {
                    inner += "<br>\n"
                    index += 1
                } else { break }
            }
            html += "<blockquote>\(inner)</blockquote>\n"
        }

        private mutating func consumeList(ordered: Bool) {
            let tag = ordered ? "ol" : "ul"
            html += "<\(tag)>\n"
            while index < lines.count {
                let line = lines[index]
                if ordered ? isOrderedListItem(line) : isUnorderedListItem(line) {
                    html += "<li>\(inline(stripListMarker(line)))</li>\n"
                    index += 1
                } else { break }
            }
            html += "</\(tag)>\n"
        }

        private mutating func consumeParagraph() {
            var paragraph: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if isHorizontalRule(line) { break }
                if headerMatch(line) != nil { break }
                if line.hasPrefix("> ") || line == ">" { break }
                if isUnorderedListItem(line) || isOrderedListItem(line) { break }
                if line.hasPrefix("```") || line.hasPrefix("~~~") { break }
                paragraph.append(line)
                index += 1
            }
            html += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"
        }

        private mutating func appendFootnotes() {
            html += "<div class=\"footnotes\"><hr><ol>\n"
            for footnote in footnotes {
                let safeID = htmlEscape(footnote.id)
                html += "<li id=\"fn-\(safeID)\">\(inline(footnote.body)) <a href=\"#fnref-\(safeID)\">↩</a></li>\n"
            }
            html += "</ol></div>\n"
        }

        // MARK: Block detection

        private func isHorizontalRule(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            let first = trimmed.first!
            guard first == "-" || first == "*" || first == "_" else { return false }
            return trimmed.allSatisfy { $0 == first || $0 == " " }
        }

        private func headerMatch(_ line: String) -> (level: Int, text: String)? {
            var hashes = 0
            for ch in line {
                if ch == "#" { hashes += 1 } else { break }
            }
            guard (1...6).contains(hashes) else { return nil }
            let afterHashes = line.dropFirst(hashes)
            guard afterHashes.first == " " else { return nil }
            return (hashes, String(afterHashes.dropFirst()))
        }

        private func isUnorderedListItem(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            guard let first = trimmed.first else { return false }
            guard first == "-" || first == "*" || first == "+" else { return false }
            return trimmed.dropFirst().first == " "
        }

        private func isOrderedListItem(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            var digits = 0
            for ch in trimmed {
                if ch.isASCII && ch.isNumber { digits += 1 } else { break }
            }
            guard digits > 0 else { return false }
            let rest = trimmed.dropFirst(digits)
            guard let dot = rest.first, dot == "." || dot == ")" else { return false }
            return rest.dropFirst().first == " "
        }

        private func stripListMarker(_ line: String) -> String {
            let trimmed = line.drop(while: { $0 == " " })
            // unordered: marker is 1 char
            if let first = trimmed.first, first == "-" || first == "*" || first == "+" {
                return String(trimmed.dropFirst(2))
            }
            // ordered: digits + . + space
            let rest = trimmed.drop(while: { $0.isASCII && $0.isNumber })
            return String(rest.dropFirst(2))
        }

        // MARK: Footnote definition

        private func footnoteDefinitionMatch(_ line: String) -> (id: String, body: String)? {
            guard line.hasPrefix("[^") else { return nil }
            // [^id]: body
            guard let closeBracket = line.range(of: "]:") else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket.lowerBound])
            let body = String(line[closeBracket.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (id, body)
        }

        // MARK: Inline

        private func inline(_ source: String) -> String {
            // Escape HTML first; markdown markers are still detectable
            // in the escaped string because we only escape `<>&"`.
            var text = htmlEscape(source)
            // Images then links (order matters — image `![…](…)`
            // contains the link pattern).
            text = applyPattern(text, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { groups in
                "<img alt=\"\(groups[1])\" src=\"\(groups[2])\">"
            }
            text = applyPattern(text, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { groups in
                "<a href=\"\(groups[2])\">\(groups[1])</a>"
            }
            // Footnote references (after links so `[^id]` doesn't get
            // grabbed by the link pattern — the link pattern needs
            // `(`, footnotes don't).
            text = applyPattern(text, pattern: #"\[\^([^\]]+)\]"#) { groups in
                let safe = htmlEscape(groups[1])
                return "<sup id=\"fnref-\(safe)\"><a href=\"#fn-\(safe)\">\(safe)</a></sup>"
            }
            // Bold then italic — `**` before `*` so the longer marker
            // wins; same for `__` vs `_`.
            text = applyPattern(text, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
            text = applyPattern(text, pattern: #"__([^_]+)__"#)     { "<strong>\($0[1])</strong>" }
            text = applyPattern(text, pattern: #"\*([^*]+)\*"#)     { "<em>\($0[1])</em>" }
            text = applyPattern(text, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#) { "<em>\($0[1])</em>" }
            text = applyPattern(text, pattern: #"~~([^~]+)~~"#)     { "<del>\($0[1])</del>" }
            text = applyPattern(text, pattern: #"`([^`]+)`"#)       { "<code>\($0[1])</code>" }
            return text
        }

        private func applyPattern(_ source: String,
                                   pattern: String,
                                   replacement: ([String]) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
            let nsSource = source as NSString
            let matches = regex.matches(in: source,
                                        range: NSRange(location: 0, length: nsSource.length))
            // Apply bottom-up so earlier match offsets stay valid.
            var result = source
            for match in matches.reversed() {
                var groups: [String] = []
                for g in 0..<match.numberOfRanges {
                    let r = match.range(at: g)
                    groups.append(r.location == NSNotFound ? "" : nsSource.substring(with: r))
                }
                let rangeInResult = Range(match.range, in: result)!
                result.replaceSubrange(rangeInResult, with: replacement(groups))
            }
            return result
        }

        private func htmlEscape(_ string: String) -> String {
            string
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
    }
}
