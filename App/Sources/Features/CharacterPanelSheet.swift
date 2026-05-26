import SwiftUI

/// Counterpart to `CharacterInspectorSheet`: that reads, this writes.
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

enum CharacterPanelCatalog {
    struct Entry {
        let character: String
        let name: String
    }

    /// Hand-picked editor characters — no attempt at full Unicode
    /// coverage.
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
