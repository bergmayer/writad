import SwiftUI
import UniformTypeIdentifiers

// MARK: - Prefix / Suffix Lines

/// Sheet for the "Prefix Lines" / "Suffix Lines" commands. Operates on
/// the current selection if non-empty, otherwise the whole document.
struct PrefixSuffixLinesSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var prefix: String = ""
    @State private var suffix: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Prefix") {
                    TextField("Prepended to each line", text: $prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Section("Suffix") {
                    TextField("Appended to each line", text: $suffix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Section {
                    Button("Apply") {
                        CommandActions.applyPrefixSuffix(prefix: prefix, suffix: suffix)
                        dismiss()
                    }
                    .disabled(prefix.isEmpty && suffix.isEmpty)
                } footer: {
                    Text("Both fields can be filled together; either one alone also works.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Prefix / Suffix Lines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// (SurroundSelectionSheet retired — the command is a Text ▸ Surround
// Selection submenu with preset wraps now. CommandActions.surroundSelection
// is still the entry point.)

// MARK: - Lorem Ipsum inserter

struct InsertLoremIpsumSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var paragraphs: Int = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("Paragraphs") {
                    Stepper(value: $paragraphs, in: 1...50) {
                        Text("\(paragraphs) paragraph\(paragraphs == 1 ? "" : "s")")
                    }
                }
                Section {
                    Button("Insert") {
                        CommandActions.insertLoremIpsum(paragraphs: paragraphs)
                        dismiss()
                    }
                } footer: {
                    Text("Inserts placeholder Lorem Ipsum text at the current cursor position.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Insert Lorem Ipsum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
