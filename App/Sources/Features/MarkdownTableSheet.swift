import SwiftUI

/// Picks size + alignment and emits a GitHub-Flavored Markdown
/// table at the cursor.
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
