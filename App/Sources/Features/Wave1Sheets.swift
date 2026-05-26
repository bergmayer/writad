import SwiftUI
import UIKit

// MARK: - Process Lines Containing

/// "Process Lines Containing" — BBEdit's line-filter modal. Match
/// every line in the document (or selection) against a pattern,
/// then keep the matches / delete them / pull them onto the
/// clipboard. The most-used "shape a document" operation in BBEdit.
struct ProcessLinesSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var pattern: String = ""
    @State private var useRegex: Bool = false
    @State private var invertMatch: Bool = false
    @State private var action: CommandActions.ProcessLinesAction = .keepMatching

    var body: some View {
        NavigationStack {
            Form {
                Section("Pattern") {
                    TextField("Substring or regex", text: $pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Toggle("Regular expression", isOn: $useRegex)
                    Toggle("Invert (operate on non-matching lines)", isOn: $invertMatch)
                }
                Section("Action") {
                    Picker("What to do", selection: $action) {
                        Text("Keep matching lines").tag(CommandActions.ProcessLinesAction.keepMatching)
                        Text("Delete matching lines").tag(CommandActions.ProcessLinesAction.deleteMatching)
                        Text("Copy matching lines to clipboard").tag(CommandActions.ProcessLinesAction.copyMatchingToClipboard)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Text("Operates on the current selection if non-empty, otherwise the whole document.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Process Lines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        CommandActions.processLines(
                            pattern: pattern,
                            regex: useRegex,
                            invert: invertMatch,
                            action: action
                        )
                        dismiss()
                    }
                    .disabled(pattern.isEmpty)
                }
            }
        }
    }
}

// MARK: - Canonize

/// Canonize / Text Merge — apply a saved list of find/replace pairs
/// (tab-separated, one per line) against the selection or document.
struct CanonizeSheet: View {

    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppPreferenceKey.canonizePairs) private var pairsRaw: String = ""
    @AppStorage(AppPreferenceKey.canonizeRegex) private var useRegex: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Treat find side as regex", isOn: $useRegex)
                } header: {
                    Text("Options")
                } footer: {
                    Text("Capture groups (\\1, \\2…) are available in the replacement when regex mode is on.")
                }
                Section {
                    TextEditor(text: $pairsRaw)
                        .font(.body.monospaced())
                        .frame(minHeight: 240)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Find / Replace Pairs")
                } footer: {
                    Text("One pair per line — left side, a literal **tab**, then the replacement. The list is applied top-to-bottom in order.")
                }
            }
            .navigationTitle("Canonize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        CommandActions.applyCanonizePairs(pairsRaw, regex: useRegex)
                        dismiss()
                    }
                    .disabled(pairsRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Character Panel

/// Curated grid of common Unicode characters to insert at the cursor.
/// Complements `CharacterInspectorSheet` — that one reads a selection,
/// this one writes new content.
struct CharacterPanelSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(CharacterPanelCatalog.groups, id: \.0) { group, entries in
                        section(title: group, entries: filter(entries))
                    }
                }
                .padding(16)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Insert Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, entries: [CharacterPanelCatalog.Entry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 80), spacing: 8)], spacing: 8) {
                    ForEach(entries, id: \.character) { entry in
                        Button {
                            CommandActions.pasteString(entry.character)
                        } label: {
                            VStack(spacing: 4) {
                                Text(entry.character)
                                    .font(.system(size: 26))
                                    .frame(width: 56, height: 40)
                                    .background(.quaternary, in: .rect(cornerRadius: 8))
                                Text(entry.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func filter(_ entries: [CharacterPanelCatalog.Entry]) -> [CharacterPanelCatalog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(q) || $0.character.contains(q) }
    }
}

// MARK: - Organize Footnotes

/// Sheet for the Organize Footnotes command. Asks where to put the
/// re-numbered definitions — at the end of the document, or after
/// each paragraph that references them.
struct OrganizeFootnotesSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var placement: CommandActions.FootnotePlacement = .endOfDocument

    var body: some View {
        NavigationStack {
            Form {
                Section("Where should footnote definitions go?") {
                    Picker("Placement", selection: $placement) {
                        Text("End of Document").tag(CommandActions.FootnotePlacement.endOfDocument)
                        Text("End of Each Paragraph").tag(CommandActions.FootnotePlacement.endOfParagraph)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Button("Organize") {
                        CommandActions.organizeFootnotes(placement: placement)
                        dismiss()
                    }
                } footer: {
                    Text("References will be re-numbered 1, 2, 3… by appearance order in the body. Definitions move to the chosen location and are kept in numeric order.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Organize Footnotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// and an alignment for each column; emits a ready-to-edit GitHub-
/// Flavored Markdown table at the cursor.
struct MarkdownTableSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var rows: Int = 3
    @State private var cols: Int = 3
    @State private var alignment: Alignment = .left

    enum Alignment: String, CaseIterable, Identifiable {
        case left, center, right
        var id: String { rawValue }
        var marker: String {
            switch self {
            case .left:   "---"
            case .center: ":---:"
            case .right:  "---:"
            }
        }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Size") {
                    Stepper(value: $cols, in: 1...12) {
                        Text("Columns \(cols)").monospacedDigit()
                    }
                    Stepper(value: $rows, in: 1...50) {
                        Text("Body rows \(rows)").monospacedDigit()
                    }
                }
                Section("Alignment (applies to all columns)") {
                    Picker("Alignment", selection: $alignment) {
                        ForEach(Alignment.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Preview") {
                    Text(buildTable())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Insert Markdown Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        CommandActions.pasteString(buildTable())
                        dismiss()
                    }
                }
            }
        }
    }

    private func buildTable() -> String {
        let headerCells = (1...cols).map { "Header \($0)" }
        let separatorCells = Array(repeating: alignment.marker, count: cols)
        let bodyRow = (1...cols).map { _ in "  " }
        var lines: [String] = []
        lines.append("| " + headerCells.joined(separator: " | ") + " |")
        lines.append("| " + separatorCells.joined(separator: " | ") + " |")
        for _ in 0..<rows {
            lines.append("| " + bodyRow.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum CharacterPanelCatalog {
    struct Entry {
        let character: String
        let name: String
    }

    /// Section-grouped catalog. Skips the full ~150K-point Unicode
    /// space — these are the characters editor users actually
    /// want one-tap access to.
    static let groups: [(String, [Entry])] = [
        ("Dashes & Spaces", [
            Entry(character: "—", name: "em dash"),
            Entry(character: "–", name: "en dash"),
            Entry(character: "−", name: "minus"),
            Entry(character: "⁃", name: "hyphen bullet"),
            Entry(character: "\u{00A0}", name: "no-break space"),
            Entry(character: "\u{2009}", name: "thin space"),
            Entry(character: "…", name: "ellipsis"),
        ]),
        ("Quotes", [
            Entry(character: "“", name: "ldquo"),
            Entry(character: "”", name: "rdquo"),
            Entry(character: "‘", name: "lsquo"),
            Entry(character: "’", name: "rsquo"),
            Entry(character: "«", name: "laquo"),
            Entry(character: "»", name: "raquo"),
            Entry(character: "„", name: "low double"),
            Entry(character: "‚", name: "low single"),
        ]),
        ("Arrows", [
            Entry(character: "←", name: "left"),
            Entry(character: "→", name: "right"),
            Entry(character: "↑", name: "up"),
            Entry(character: "↓", name: "down"),
            Entry(character: "↔", name: "left right"),
            Entry(character: "⇐", name: "left double"),
            Entry(character: "⇒", name: "right double"),
            Entry(character: "↩", name: "carriage return"),
            Entry(character: "↪", name: "rightwards arrow with hook"),
        ]),
        ("Math & Logic", [
            Entry(character: "±", name: "plus minus"),
            Entry(character: "×", name: "times"),
            Entry(character: "÷", name: "divide"),
            Entry(character: "≠", name: "not equal"),
            Entry(character: "≈", name: "almost equal"),
            Entry(character: "≤", name: "less or equal"),
            Entry(character: "≥", name: "greater or equal"),
            Entry(character: "∞", name: "infinity"),
            Entry(character: "√", name: "square root"),
            Entry(character: "∑", name: "sum"),
            Entry(character: "∏", name: "product"),
            Entry(character: "∂", name: "partial"),
            Entry(character: "∇", name: "nabla"),
            Entry(character: "∈", name: "element of"),
            Entry(character: "∉", name: "not element of"),
            Entry(character: "∀", name: "for all"),
            Entry(character: "∃", name: "exists"),
            Entry(character: "¬", name: "not"),
            Entry(character: "∧", name: "and"),
            Entry(character: "∨", name: "or"),
        ]),
        ("Currency", [
            Entry(character: "€", name: "euro"),
            Entry(character: "£", name: "pound"),
            Entry(character: "¥", name: "yen"),
            Entry(character: "¢", name: "cent"),
            Entry(character: "₿", name: "bitcoin"),
            Entry(character: "₩", name: "won"),
        ]),
        ("Greek (Math)", [
            Entry(character: "α", name: "alpha"),
            Entry(character: "β", name: "beta"),
            Entry(character: "γ", name: "gamma"),
            Entry(character: "δ", name: "delta"),
            Entry(character: "Δ", name: "Delta (cap)"),
            Entry(character: "λ", name: "lambda"),
            Entry(character: "μ", name: "mu"),
            Entry(character: "π", name: "pi"),
            Entry(character: "σ", name: "sigma"),
            Entry(character: "Σ", name: "Sigma (cap)"),
            Entry(character: "φ", name: "phi"),
            Entry(character: "ω", name: "omega"),
            Entry(character: "Ω", name: "Omega (cap)"),
        ]),
        ("Markup & Punctuation", [
            Entry(character: "§", name: "section"),
            Entry(character: "¶", name: "pilcrow"),
            Entry(character: "†", name: "dagger"),
            Entry(character: "‡", name: "double dagger"),
            Entry(character: "•", name: "bullet"),
            Entry(character: "‣", name: "triangle bullet"),
            Entry(character: "‱", name: "per ten thousand"),
            Entry(character: "‰", name: "per mille"),
            Entry(character: "©", name: "copyright"),
            Entry(character: "®", name: "registered"),
            Entry(character: "™", name: "trademark"),
        ]),
    ]
}

// MARK: - Drafts recovery

/// Launch-time recovery sheet for unsaved Untitled drafts.
/// Surfaces every entry from `DraftsStore.shared.loadAll()` so the
/// user can re-open it (the bytes are loaded into a fresh tab, still
/// Untitled + dirty so the title's "edited" subtitle stays on) or
/// discard it (the on-disk draft is deleted). "Keep" leaves the
/// draft on disk for a future recovery cycle.
struct DraftsRecoverySheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [DraftRecord] = []

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    ContentUnavailableView(
                        "No drafts to recover",
                        systemImage: "doc.badge.clock",
                        description: Text("Untitled drafts from previous sessions show up here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(drafts) { draft in
                                row(for: draft)
                            }
                        } footer: {
                            Text("Drafts are kept until you save the buffer to a real file or tap Discard. Tap a row to open it as a new Untitled tab with the bytes already loaded.")
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Recover Unsaved Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep") { dismiss() }
                }
                if !drafts.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open All") {
                            let toOpen = drafts
                            dismiss()
                            Task { @MainActor in
                                try? await Task.sleep(for: Timing.paletteHandoff)
                                for draft in toOpen {
                                    CommandActions.recoverDraft(draft)
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", role: .destructive) {
                            for draft in drafts {
                                DraftsStore.shared.discard(draft.url)
                            }
                            drafts.removeAll()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { drafts = DraftsStore.shared.loadAll() }
        }
    }

    @ViewBuilder
    private func row(for draft: DraftRecord) -> some View {
        HStack(spacing: 10) {
            // Body of the row — tappable to recover.
            Button {
                let target = draft
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: Timing.paletteHandoff)
                    CommandActions.recoverDraft(target)
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        // Source path takes the top line when
                        // present — the user is more likely to
                        // recognize "Notes / ideas.md" than the
                        // buffer's first 80 chars. The preview
                        // becomes the secondary line. Untitled
                        // drafts flip back to preview-on-top.
                        if let display = draft.metadata?.sourceDisplay {
                            Text(display)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                                .font(.body.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Text("\(draft.bytes.formatted(.byteCount(style: .file))) · \(draft.modified.formatted(date: .abbreviated, time: .shortened))\(draft.metadata?.sourceDisplay == nil ? "" : " · was open file")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // Explicit per-row × — easier to discover than a
            // swipe gesture, especially on iPad where users may
            // not think to swipe a list row. Confirmation isn't
            // required because individual drafts can't be
            // unmistakably valuable — if it were, the user would
            // have tapped Recover. Bulk-clear ("Discard All") in
            // the toolbar still requires an explicit Hold-style
            // destructive tap.
            Button {
                DraftsStore.shared.discard(draft.url)
                drafts.removeAll { $0.id == draft.id }
                if drafts.isEmpty { dismiss() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard draft")
        }
        .swipeActions {
            Button("Discard", role: .destructive) {
                DraftsStore.shared.discard(draft.url)
                drafts.removeAll { $0.id == draft.id }
                if drafts.isEmpty { dismiss() }
            }
        }
    }
}
