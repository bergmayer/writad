import SwiftUI
import FileEncoding

struct EncodingPickerSheet: View {

    enum Action { case reinterpret, convert }

    let current: FileEncoding
    let onSelect: (FileEncoding, Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String.Encoding
    @State private var includesUTF8BOM: Bool
    @State private var action: Action = .convert

    init(current: FileEncoding, onSelect: @escaping (FileEncoding, Action) -> Void) {
        self.current = current
        self.onSelect = onSelect
        self._selection = State(initialValue: current.encoding)
        self._includesUTF8BOM = State(initialValue: current.withUTF8BOM)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Action") {
                    Picker("Action", selection: $action) {
                        Text("Convert text to this encoding").tag(Action.convert)
                        Text("Re-interpret bytes as this encoding").tag(Action.reinterpret)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Encoding") {
                    ForEach(encodingChoices, id: \.self) { encoding in
                        Button {
                            selection = encoding
                        } label: {
                            HStack {
                                Text(String.localizedName(of: encoding))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if encoding == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                if selection == .utf8 {
                    Section {
                        Toggle("Include UTF-8 BOM", isOn: $includesUTF8BOM)
                    }
                }
            }
            .navigationTitle("Text Encoding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onSelect(
                            FileEncoding(
                                encoding: selection,
                                withUTF8BOM: selection == .utf8 && includesUTF8BOM
                            ),
                            action
                        )
                        dismiss()
                    }
                }
            }
        }
    }

    private var encodingChoices: [String.Encoding] {
        String.sortedAvailableStringEncodings.compactMap { $0 }
    }
}
