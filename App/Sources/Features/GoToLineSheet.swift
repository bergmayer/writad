import SwiftUI

struct GoToLineSheet: View {

    let lineCount: Int
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Line") {
                        TextField("1 – \(lineCount)", text: $input)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
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
                        if let line = Int(input), line >= 1, line <= lineCount {
                            onApply(line)
                        }
                        dismiss()
                    }
                    .disabled(Int(input) == nil)
                }
            }
        }
    }
}
