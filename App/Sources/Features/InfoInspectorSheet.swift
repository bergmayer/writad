import SwiftUI
import FileEncoding
import LineEnding

/// One row in the markdown outline. Captured row index is 0-based; the
/// `level` is the heading depth (1 for `#`, 2 for `##`, …, up to 6).
struct OutlineEntry: Identifiable, Equatable {
    let row: Int
    let level: Int
    let title: String
    var id: Int { row }
}

/// Walks the buffer once and collects symbols suitable for an outline.
/// Code outlines reuse `FoldDiscovery.allFoldableHeaders` so the panel
/// and the gutter agree on what counts as a "section": every foldable
/// region surfaces as one entry titled by its header line. Markdown
/// keeps its own ATX walker because the outline needs the heading level
/// (1–6), which `FoldableRegion` doesn't carry.
@MainActor
enum OutlineDiscovery {

    static func entries(in text: NSString, language: LanguageIdentifier) -> [OutlineEntry] {
        if language == .markdown {
            return markdownEntries(in: text)
        }
        return codeEntries(in: text, language: language)
    }

    private static func codeEntries(in text: NSString, language: LanguageIdentifier) -> [OutlineEntry] {
        let regions = FoldDiscovery.allFoldableHeaders(in: text, language: language)
        guard !regions.isEmpty else { return [] }

        // One pass over the buffer collects line ranges so we can pull
        // each header's text by row. Cheap relative to the fold scan.
        let lineRanges = collectLineRanges(in: text)
        let sorted = regions.sorted { $0.headerRow < $1.headerRow }

        return sorted.compactMap { region -> OutlineEntry? in
            guard region.headerRow >= 0, region.headerRow < lineRanges.count else { return nil }
            let lr = lineRanges[region.headerRow]
            let raw = text.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            // Nesting level = how many other regions enclose this header row.
            let level = sorted.reduce(into: 1) { acc, other in
                if other.headerRow < region.headerRow,
                   other.bodyRange.contains(region.headerRow) {
                    acc += 1
                }
            }
            return OutlineEntry(row: region.headerRow, level: level, title: raw)
        }
    }

    /// Line ranges keyed by row — `result[row]` is that line's NSRange
    /// (excluding the trailing newline if present).
    private static func collectLineRanges(in text: NSString) -> [NSRange] {
        let length = text.length
        var ranges: [NSRange] = []
        var start = 0
        var i = 0
        while i < length {
            let c = text.character(at: i)
            if c == 0x0A {
                ranges.append(NSRange(location: start, length: i - start))
                i += 1
                start = i
            } else if c == 0x0D {
                ranges.append(NSRange(location: start, length: i - start))
                i += 1
                if i < length, text.character(at: i) == 0x0A { i += 1 }
                start = i
            } else {
                i += 1
            }
        }
        if start < length {
            ranges.append(NSRange(location: start, length: length - start))
        } else if length == 0 || text.character(at: length - 1) == 0x0A || text.character(at: length - 1) == 0x0D {
            ranges.append(NSRange(location: length, length: 0))
        }
        return ranges
    }

    private static func markdownEntries(in text: NSString) -> [OutlineEntry] {
        let length = text.length
        guard length > 0 else { return [] }

        var entries: [OutlineEntry] = []
        var row = 0
        var atLineStart = true
        var i = 0
        while i < length {
            if atLineStart, let level = atxLevel(at: i, in: text, length: length) {
                if let title = headingTitle(at: i, level: level, in: text, length: length) {
                    entries.append(OutlineEntry(row: row, level: level, title: title))
                }
                atLineStart = false
            } else if atLineStart {
                atLineStart = false
            }
            let c = text.character(at: i)
            if c == 0x0A {
                row += 1; atLineStart = true; i += 1
            } else if c == 0x0D {
                row += 1; atLineStart = true; i += 1
                if i < length, text.character(at: i) == 0x0A { i += 1 }
            } else {
                i += 1
            }
        }
        return entries
    }

    private static func atxLevel(at pos: Int, in text: NSString, length: Int) -> Int? {
        var level = 0
        var i = pos
        while i < length && level < 7 {
            let c = text.character(at: i)
            if c == 0x23 { level += 1; i += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        guard i < length else { return nil }
        let next = text.character(at: i)
        // ATX requires a space/tab after the #s (or line end for an empty header).
        if next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D {
            return level
        }
        return nil
    }

    private static func headingTitle(at pos: Int, level: Int, in text: NSString, length: Int) -> String? {
        var i = pos + level  // skip the #s
        while i < length {
            let c = text.character(at: i)
            if c == 0x20 || c == 0x09 { i += 1 } else { break }
        }
        var end = i
        while end < length {
            let c = text.character(at: end)
            if c == 0x0A || c == 0x0D { break }
            end += 1
        }
        guard end > i else { return "" }
        var title = text.substring(with: NSRange(location: i, length: end - i))
        // Trim trailing `#`s and whitespace per ATX closing sequence.
        while let last = title.last, last == "#" || last == " " || last == "\t" {
            title.removeLast()
        }
        return title
    }
}

/// File / Outline / Count inspector. Hosted as a SwiftUI side
/// `.inspector` from `EditorView` (toggled by the ⓘ button in the
/// bottom-right status bar) — *not* a sheet, despite the historic
/// type name. The editor remains editable while this panel is open.
struct InfoInspectorSheet: View {

    let document: PlainTextDocument
    let state: EditorState
    let onJump: (Int) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case file = "File"
        case outline = "Outline"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .file:    "doc.text"
            case .outline: "list.bullet.indent"
            }
        }
    }

    @State private var tab: Tab = .file

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch tab {
            case .file:    fileSection
            case .outline: outlineSection
            }
        }
    }

    // MARK: File

    @ViewBuilder
    private var fileSection: some View {
        let attrs = fileAttributes
        Form {
            Section("File") {
                row("Created",  value: attrs?.creationDateFormatted ?? "—")
                row("Modified", value: attrs?.modificationDateFormatted ?? "—")
                row("Size",     value: attrs?.sizeFormatted ?? sizeFromBuffer)
                row("Permissions", value: attrs?.permissionsFormatted ?? "—")
                row("Owner",    value: attrs?.owner ?? "—")
                row("Full Path", value: document.fileURL?.path ?? "Unsaved", monospaced: true, multiline: true)
            }
            Section("Text Settings") {
                row("Encoding",     value: document.fileEncoding.localizedName)
                row("Line Endings", value: "\(document.lineEnding.label) (\(document.lineEnding.description))")
                row("Language",     value: LanguageRegistry.displayName(for: state.languageIdentifier))
            }
            Section("Window Appearance") {
                // Local overrides — each picker wins over the
                // matching Settings ▸ Appearance / Font preference
                // for THIS tab only. "Inherit Global" on any row
                // clears that row's override so future Settings
                // changes for it propagate again. Per-tab — a fresh
                // open of the same file in a new tab does NOT
                // inherit these choices.
                Picker("Theme", selection: windowThemeBinding) {
                    Text("Inherit Global").tag(WindowThemeChoice.inherit)
                    Divider()
                    ForEach(AppThemeName.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(WindowThemeChoice.override(theme))
                    }
                }
                Picker("Font", selection: windowFontBinding) {
                    Text("Inherit Global").tag(WindowFontChoice.inherit)
                    Divider()
                    ForEach(EditorFont.allCases, id: \.self) { face in
                        Text(face.rawValue).tag(WindowFontChoice.override(face))
                    }
                }
                HStack {
                    Text("Font Size")
                    Spacer()
                    if state.fontSizeOverride != nil {
                        Button("Inherit Global") {
                            state.fontSizeOverride = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                    Stepper(value: windowFontSizeBinding, in: 9...96, step: 1) {
                        Text("\(Int(state.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 50, alignment: .trailing)
                    }
                    .labelsHidden()
                }
                if state.themeOverride != nil || state.fontOverride != nil || state.fontSizeOverride != nil {
                    Text("This window is using one or more custom appearance settings. Settings ▸ Appearance changes won't apply here until you switch the matching row back to Inherit Global.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `.inherit` clears the per-window override and `state.font` falls
    /// back through to the global pref automatically; `.override(face)`
    /// promotes the override and `state.font` resolves to it.
    private var windowFontBinding: Binding<WindowFontChoice> {
        Binding(
            get: {
                if let override = state.fontOverride { return .override(override) }
                return .inherit
            },
            set: { choice in
                switch choice {
                case .inherit:           state.fontOverride = nil
                case .override(let f):   state.fontOverride = f
                }
            }
        )
    }

    /// Every stepper change writes the override (so user intent isn't
    /// inherited back from global on the next Settings change). The
    /// "Inherit Global" button next to it explicitly clears the override.
    private var windowFontSizeBinding: Binding<Double> {
        Binding(
            get: { state.fontSize },
            set: { state.fontSizeOverride = $0 }
        )
    }

    private enum WindowFontChoice: Hashable {
        case inherit
        case override(EditorFont)
    }

    /// `.inherit` clears the per-window override and `state.themeName`
    /// falls back through to the global pref automatically.
    private var windowThemeBinding: Binding<WindowThemeChoice> {
        Binding(
            get: {
                if let override = state.themeOverride { return .override(override) }
                return .inherit
            },
            set: { choice in
                switch choice {
                case .inherit:             state.themeOverride = nil
                case .override(let theme): state.themeOverride = theme
                }
            }
        )
    }

    /// Picker selection model — either "use whatever global says" or
    /// a specific named override. Hashable for SwiftUI tagging.
    private enum WindowThemeChoice: Hashable {
        case inherit
        case override(AppThemeName)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, monospaced: Bool = false, multiline: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .lineLimit(multiline ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var sizeFromBuffer: String {
        let bytes = document.originalData?.count ?? document.text.utf8.count
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var fileAttributes: FileAttributes? {
        guard let url = document.fileURL else { return nil }
        return FileAttributes(url: url)
    }

    // MARK: Outline

    @ViewBuilder
    private var outlineSection: some View {
        let entries = OutlineDiscovery.entries(in: document.text as NSString, language: state.languageIdentifier)
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No outline",
                    systemImage: "list.bullet.indent",
                    description: Text(state.languageIdentifier == .markdown
                                      ? "Add `# Heading` lines to build an outline."
                                      : "No symbols found at this document's language.")
                )
            } else {
                List(entries) { entry in
                    Button {
                        onJump(entry.row + 1)
                    } label: {
                        HStack(spacing: 8) {
                            // Indent by level. Level 1 sits at the left edge;
                            // level N is offset by (N-1) × 14 pt so nested
                            // sections visually nest like in Finder.
                            Spacer().frame(width: CGFloat(entry.level - 1) * 14)
                            Image(systemName: "number")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                            Text(entry.title.isEmpty ? "(empty)" : entry.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(entry.row + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

}

// MARK: - File metadata helper

private struct FileAttributes {
    let creationDateFormatted: String
    let modificationDateFormatted: String
    let sizeFormatted: String
    let permissionsFormatted: String
    let owner: String

    init?(url: URL) {
        guard let raw = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let dateStyle = Date.FormatStyle(date: .long, time: .shortened)
        self.creationDateFormatted = (raw[.creationDate] as? Date)?.formatted(dateStyle) ?? "—"
        self.modificationDateFormatted = (raw[.modificationDate] as? Date)?.formatted(dateStyle) ?? "—"
        if let size = raw[.size] as? Int {
            self.sizeFormatted = "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size.formatted(.number)) bytes)"
        } else {
            self.sizeFormatted = "—"
        }
        if let perms = raw[.posixPermissions] as? NSNumber {
            let octal = String(perms.intValue, radix: 8)
            self.permissionsFormatted = "\(octal) (\(symbolicPermissions(perms.intValue)))"
        } else {
            self.permissionsFormatted = "—"
        }
        self.owner = raw[.ownerAccountName] as? String ?? "—"
    }
}

/// Convert a POSIX mode integer to the `rwxrwxrwx` style used by `ls`.
private func symbolicPermissions(_ mode: Int) -> String {
    var s = ""
    for shift in [6, 3, 0] {
        let bits = (mode >> shift) & 0b111
        s += (bits & 0b100 != 0) ? "r" : "-"
        s += (bits & 0b010 != 0) ? "w" : "-"
        s += (bits & 0b001 != 0) ? "x" : "-"
    }
    return s
}
