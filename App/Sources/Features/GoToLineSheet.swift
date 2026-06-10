import SwiftUI

struct GoToLineSheet: View {

    let lineCount: Int
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @FocusState private var fieldFocused: Bool

    /// Parsed input, nil when empty / non-numeric / out of range —
    /// gates the Go button so a bad value can't silently dismiss.
    private var validLine: Int? {
        guard let line = Int(input), line >= 1, line <= lineCount else { return nil }
        return line
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Line") {
                        TextField("1 – \(lineCount)", text: $input)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($fieldFocused)
                    }
                } footer: {
                    Text("Enter a line number between 1 and \(lineCount).")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Go to Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        if let line = validLine {
                            onApply(line)
                        }
                        dismiss()
                    }
                    .disabled(validLine == nil)
                }
            }
            .onAppear { fieldFocused = true }
        }
    }
}
