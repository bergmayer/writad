import SwiftUI

// MARK: - SF Symbol picker

/// A curated picker — Apple doesn't ship one, and the full ~6 000-
/// symbol catalogue would be unbrowsable. Users can still enter any
/// name manually; the library is just the discoverable shortlist.
enum ToolbarSymbolLibrary {

    /// Order is intentional — most-used categories first.
    static let groups: [(String, [String])] = [
        ("Find & Navigate", [
            "magnifyingglass", "text.magnifyingglass", "arrow.triangle.2.circlepath",
            "arrow.uturn.backward", "arrow.uturn.forward",
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
            "arrow.up.to.line", "arrow.down.to.line",
            "arrow.up.to.line.compact", "arrow.down.to.line.compact",
            "chevron.up", "chevron.down", "chevron.left", "chevron.right",
            "chevron.left.forwardslash.chevron.right", "arrow.forward", "arrow.backward"
        ]),
        ("Text Format", [
            "textformat", "textformat.size", "textformat.size.larger", "textformat.size.smaller",
            "textformat.abc", "textformat.123", "textformat.alt",
            "bold", "italic", "underline", "strikethrough",
            "text.justify", "text.alignleft", "text.aligncenter", "text.alignright",
            "increase.indent", "decrease.indent",
            "increase.quotelevel", "decrease.quotelevel",
            "characters.lowercase", "characters.uppercase"
        ]),
        ("Lines & Lists", [
            "list.bullet", "list.dash", "list.number", "list.bullet.indent",
            "list.triangle", "line.3.horizontal", "line.horizontal.3.decrease",
            "arrow.up.arrow.down", "arrow.up.and.down.text.horizontal",
            "line.diagonal.arrow", "arrow.left.and.right",
            "rectangle.compress.vertical", "rectangle.expand.vertical"
        ]),
        ("Edit", [
            "pencil", "square.and.pencil", "pencil.tip",
            "scissors", "doc.on.doc", "doc.on.clipboard",
            "trash", "trash.slash",
            "arrow.uturn.left.circle", "arrow.uturn.right.circle",
            "plus", "minus", "xmark", "checkmark",
            "plus.circle", "minus.circle", "xmark.circle", "checkmark.circle"
        ]),
        ("Code", [
            "curlybraces", "curlybraces.square", "parentheses",
            "number", "number.square", "percent",
            "function", "terminal", "command",
            "doc.text", "doc.plaintext", "doc.text.below.ecg"
        ]),
        ("File", [
            "doc", "doc.fill", "doc.text.magnifyingglass",
            "folder", "folder.badge.plus",
            "square.and.arrow.up", "square.and.arrow.down",
            "tray", "tray.full", "paperplane", "paperclip",
            "link", "rectangle.and.paperclip",
            // 💾 — classic floppy via toolbarSymbol's `u:HEX` path
            // (VS15 forces monochrome).
            "u:1F4BE"
        ]),
        ("View", [
            "sidebar.left", "sidebar.right", "rectangle.split.2x1",
            "eye", "eye.slash",
            "square.grid.2x2", "rectangle.lefthalf.inset.filled",
            "ruler", "ruler.fill"
        ]),
        ("Bookmarks & Marks", [
            "bookmark", "bookmark.fill", "star", "star.fill",
            "flag", "flag.fill", "tag", "tag.fill",
            "exclamationmark.triangle", "exclamationmark.circle",
            "info.circle", "questionmark.circle"
        ]),
        ("Misc", [
            "circle", "square", "diamond", "triangle",
            "asterisk", "at", "underscore",
            "scribble", "highlighter", "paintbrush",
            "wand.and.stars", "sparkles",
            "wrench.and.screwdriver", "gear", "sliders.horizontal"
        ])
    ]

    /// Flat list, used by the search filter.
    static let all: [String] = groups.flatMap(\.1)
}

/// Tap commits + dismisses. The free-text row at the bottom takes
/// any system symbol name, not just what's in the library.
struct ToolbarSymbolPicker: View {

    @Environment(\.dismiss) private var dismiss
    @Binding var selected: String
    @State private var query: String = ""
    @State private var manualEntry: String

    init(selected: Binding<String>) {
        self._selected = selected
        self._manualEntry = State(initialValue: selected.wrappedValue)
    }

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                ScrollView {
                    if query.isEmpty {
                        ForEach(ToolbarSymbolLibrary.groups, id: \.0) { (category, symbols) in
                            section(title: category, symbols: symbols)
                        }
                    } else {
                        let matches = ToolbarSymbolLibrary.all.filter {
                            $0.localizedCaseInsensitiveContains(query)
                        }
                        if matches.isEmpty {
                            ContentUnavailableView(
                                "No matches",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different word, or enter the exact SF Symbol name below.")
                            )
                            .padding(.top, 40)
                        } else {
                            section(title: "Results", symbols: matches)
                        }
                    }

                    manualSection
                }
            }
            .navigationTitle("Choose Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search symbols", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(title: String, symbols: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(symbols, id: \.self) { name in
                    cell(symbol: name)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func cell(symbol name: String) -> some View {
        let isSelected = (name == selected)
        Button {
            selected = name
            dismiss()
        } label: {
            VStack(spacing: 4) {
                toolbarSymbol(name, size: 24)
                    .frame(width: 56, height: 44)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: .rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                Text(name)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Symbol Name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            HStack(spacing: 12) {
                toolbarSymbol(manualEntry.isEmpty ? "questionmark.square.dashed" : manualEntry, size: 24)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                TextField("e.g. flame.circle.fill", text: $manualEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Use") {
                    let trimmed = manualEntry.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        selected = trimmed
                        dismiss()
                    }
                }
                .disabled(manualEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}
