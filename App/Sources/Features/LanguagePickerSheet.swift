import SwiftUI

struct LanguagePickerSheet: View {

    let current: LanguageIdentifier
    let onSelect: (LanguageIdentifier) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: LanguageIdentifier

    init(current: LanguageIdentifier, onSelect: @escaping (LanguageIdentifier) -> Void) {
        self.current = current
        self.onSelect = onSelect
        self._selection = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            List(LanguageRegistry.all, id: \.identifier) { language in
                Button {
                    selection = language.identifier
                } label: {
                    HStack {
                        Text(language.displayName).foregroundStyle(.primary)
                        Spacer()
                        if language.identifier == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Syntax Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onSelect(selection)
                        dismiss()
                    }
                }
            }
        }
    }
}
