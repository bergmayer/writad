import SwiftUI
import LineEnding

struct LineEndingPickerSheet: View {

    let current: LineEnding
    let onSelect: (LineEnding) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: LineEnding

    init(current: LineEnding, onSelect: @escaping (LineEnding) -> Void) {
        self.current = current
        self.onSelect = onSelect
        self._selection = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Line Endings") {
                    ForEach(LineEnding.allCases, id: \.self) { lineEnding in
                        Button {
                            selection = lineEnding
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lineEnding.label).font(.body)
                                    Text(lineEnding.description).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if lineEnding == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Line Endings")
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

extension LineEnding {
    /// Verbose description for the picker UI.
    public var description: String {
        switch self {
        case .lf:                 return "Unix (LF)"
        case .cr:                 return "Classic Mac (CR)"
        case .crlf:               return "Windows (CRLF)"
        case .nel:                return "Next Line"
        case .lineSeparator:      return "Line Separator"
        case .paragraphSeparator: return "Paragraph Separator"
        }
    }
}
