import SwiftUI

/// Apply tab-separated find/replace pairs (one per line) against
/// the selection or document.
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
