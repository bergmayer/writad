import SwiftUI

struct ToolbarPreferencesTab: View {

    @Bindable private var prefs = AppPreferencesStore.shared
    @State private var config = ToolbarConfig.shared
    @State private var addingSlot: Bool = false
    @State private var editingIndex: Int?

    var body: some View {
        Form {
            Section {
                Toggle("Show toolbar at top of every window", isOn: $prefs.showToolbar)
            } footer: {
                Text("Tap an item to edit its icon or assigned command. Drag the handle to reorder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Items") {
                ForEach(Array(config.slots.enumerated()), id: \.element.id) { index, slot in
                    Button {
                        editingIndex = index
                    } label: {
                        HStack(spacing: 12) {
                            toolbarSymbol(slot.symbol.isEmpty ? "questionmark.square.dashed" : slot.symbol, size: 20)
                                .frame(width: 36, height: 36)
                                .background(.quaternary, in: .rect(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commandTitle(for: slot.commandId))
                                    .foregroundStyle(.primary)
                                Text(slot.symbol.isEmpty ? "No symbol" : slot.symbol)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) { config.remove(at: index) }
                }
                .onMove { source, destination in
                    config.move(from: source, to: destination)
                }
            }

            Section {
                Button {
                    addingSlot = true
                } label: {
                    Label("Add Item…", systemImage: "plus.circle.fill")
                }
                Button(role: .destructive) {
                    config.resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .sheet(isPresented: $addingSlot) {
            ToolbarSlotAdder()
        }
        .sheet(item: Binding<EditingSlotID?>(
            get: { editingIndex.map(EditingSlotID.init) },
            set: { editingIndex = $0?.value }
        )) { wrapper in
            ToolbarSlotEditor(slotIndex: wrapper.value, initial: config.slots[wrapper.value])
        }
    }

    private func commandTitle(for id: String) -> String {
        CommandRegistry.lookup(id: id)?.title ?? id
    }

    private struct EditingSlotID: Identifiable {
        let value: Int
        var id: Int { value }
    }
}

/// Fuzzy command picker + SF Symbol name. Save → ToolbarConfig.insert(_:).
private struct ToolbarSlotAdder: View {

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedCommandId: String = ""
    @State private var symbol: String = "circle"
    @State private var pickingSymbol: Bool = false

    private let allCommands: [EditorCommandSpec] = CommandRegistry.all()

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") {
                    iconPickerRow(symbol: $symbol, pickingSymbol: $pickingSymbol)
                }
                Section("Command") {
                    TextField("Search commands…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(filtered) { cmd in
                        Button {
                            selectedCommandId = cmd.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cmd.title).foregroundStyle(.primary)
                                    Text(cmd.category.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cmd.id == selectedCommandId {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Toolbar Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        ToolbarConfig.shared.insert(ToolbarSlot(commandId: selectedCommandId, symbol: symbol))
                        dismiss()
                    }
                    .disabled(selectedCommandId.isEmpty || symbol.isEmpty)
                }
            }
        }
    }

    private var filtered: [EditorCommandSpec] {
        if query.isEmpty {
            return Array(allCommands.prefix(80))
        }
        return allCommands
            .compactMap { cmd -> (EditorCommandSpec, Int)? in
                guard let s = FuzzyMatcher.bestScore(query, against: cmd) else { return nil }
                return (cmd, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
