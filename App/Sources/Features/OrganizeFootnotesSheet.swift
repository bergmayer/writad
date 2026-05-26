import SwiftUI

/// End-of-document vs end-of-paragraph placement picker for
/// Organize Footnotes.
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
