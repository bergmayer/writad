import SwiftUI
import FileEncoding
import LineEnding

/// iOS has no stock `.checkbox` Toggle style — this is the
/// composed equivalent.
private struct CheckboxRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct PreferencesView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            EditorPreferencesTab()
                .tabItem { Label("Editor", systemImage: "text.justify") }

            TypingPreferencesTab()
                .tabItem { Label("Typing", systemImage: "keyboard") }

            ToolbarPreferencesTab()
                .tabItem { Label("Toolbar", systemImage: "rectangle.topthird.inset.filled") }
        }
        // iPad-only minimum frame — iPhone presents as a sheet at
        // screen width, where forcing 520pt would clip.
        .frame(minWidth: DeviceIdiom.isPhone ? nil : 520,
               minHeight: DeviceIdiom.isPhone ? nil : 420)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(DeviceIdiom.isPhone ? .inline : .automatic)
        .toolbar {
            // iPhone sheet has no system-supplied dismiss.
            if DeviceIdiom.isPhone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
        }
    }
}

// MARK: - Editor

private struct EditorPreferencesTab: View {

    @AppStorage(AppPreferenceKey.fontSize) private var fontSize: Double = 14
    @AppStorage(AppPreferenceKey.showLineNumbers) private var showLineNumbers: Bool = true
    @AppStorage(AppPreferenceKey.wrapLines) private var wrapLines: Bool = true
    @AppStorage(AppPreferenceKey.overscroll) private var overscroll: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibles) private var showInvisibles: Bool = false
    @AppStorage(AppPreferenceKey.showInvisibleSpace) private var showInvisibleSpace: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleTab) private var showInvisibleTab: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleNewline) private var showInvisibleNewline: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleNonBreakingSpace) private var showInvisibleNBSP: Bool = true
    @AppStorage(AppPreferenceKey.showPageGuide) private var showPageGuide: Bool = false
    @AppStorage(AppPreferenceKey.pageGuideColumn) private var pageGuideColumn: Int = 80
    @AppStorage(AppPreferenceKey.usesTabs) private var usesTabs: Bool = false
    @AppStorage(AppPreferenceKey.indentWidth) private var indentWidth: Int = 4
    @AppStorage(AppPreferenceKey.insertCharacterPairs) private var insertCharacterPairs: Bool = true
    @AppStorage(AppPreferenceKey.themeName) private var themeRaw: String = AppThemeName.automatic.rawValue
    @AppStorage(AppPreferenceKey.fontName) private var fontNameRaw: String = EditorFont.systemMono.rawValue

    // Merged from the dropped Format tab.
    @AppStorage(AppPreferenceKey.defaultEncodingRaw) private var defaultEncodingRaw: Int = Int(String.Encoding.utf8.rawValue)
    @AppStorage(AppPreferenceKey.defaultLineEndingRaw) private var defaultLineEndingRaw: String = "\n"
    @AppStorage(AppPreferenceKey.defaultLanguage) private var defaultLanguageRaw: String = LanguageIdentifier.plain.rawValue
    @AppStorage(AppPreferenceKey.ensureTrailingNewline) private var ensureTrailingNewline: Bool = false
    @AppStorage(AppPreferenceKey.trimTrailingWhitespaceOnSave) private var trimTrailingWhitespace: Bool = false
    @AppStorage(AppPreferenceKey.syntaxLimitBytes) private var syntaxLimitRaw: Int = SyntaxLimit.up5MB.rawValue
    @AppStorage(AppPreferenceKey.iCloudSyncEnabled) private var iCloudSyncEnabled: Bool = true

    /// Round-trips Int↔Double so the Double-backed `@AppStorage`
    /// stays compatible with the live editor / menu zoom callers.
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { Int(fontSize.rounded()) },
            set: { fontSize = Double($0) }
        )
    }

    private var defaultEncodingBinding: Binding<UInt> {
        Binding(
            get: { UInt(defaultEncodingRaw) },
            set: { defaultEncodingRaw = Int($0) }
        )
    }

    private var defaultLineEndingBinding: Binding<LineEnding> {
        Binding(
            get: { LineEnding(rawValue: defaultLineEndingRaw.first ?? "\n") ?? .lf },
            set: { defaultLineEndingRaw = String($0.rawValue) }
        )
    }

    private var defaultLanguageBinding: Binding<LanguageIdentifier> {
        Binding(
            get: { LanguageIdentifier(rawValue: defaultLanguageRaw) ?? .plain },
            set: { defaultLanguageRaw = $0.rawValue }
        )
    }

    private var syntaxLimitBinding: Binding<SyntaxLimit> {
        Binding(
            get: { SyntaxLimit(rawValue: syntaxLimitRaw) ?? .up5MB },
            set: { syntaxLimitRaw = $0.rawValue }
        )
    }

    private var themeBinding: Binding<AppThemeName> {
        Binding(
            get: { AppThemeName(stored: themeRaw) },
            set: { themeRaw = $0.rawValue }
        )
    }

    private var commonEncodings: [String.Encoding] {
        [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32,
            .windowsCP1252, .isoLatin1, .isoLatin2, .macOSRoman,
            .shiftJIS, .japaneseEUC, .iso2022JP
        ]
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: themeBinding) {
                    ForEach(AppThemeName.allCases, id: \.self) { name in
                        Text(name.displayName).tag(name)
                    }
                }
            }

            Section("Display") {
                Picker("Font", selection: $fontNameRaw) {
                    // Monospaced first — typical code-editor pick.
                    Section("Monospaced") {
                        ForEach(EditorFont.allCases.filter(\.isMonospaced), id: \.rawValue) { face in
                            Text(face.displayName).tag(face.rawValue)
                        }
                    }
                    Section("Proportional") {
                        ForEach(EditorFont.allCases.filter { !$0.isMonospaced }, id: \.rawValue) { face in
                            Text(face.displayName).tag(face.rawValue)
                        }
                    }
                }
                LabeledContent("Font Size") {
                    Stepper(value: fontSizeBinding, in: 9...96, step: 1) {
                        Text("\(fontSizeBinding.wrappedValue) pt")
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                Toggle("Show Line Numbers", isOn: $showLineNumbers)
                Toggle("Wrap Lines", isOn: $wrapLines)
                Toggle("Scroll Past Last Line", isOn: $overscroll)
                Toggle("Show Page Guide", isOn: $showPageGuide)
                LabeledContent("Page Guide Column") {
                    Stepper(value: $pageGuideColumn, in: 20...200, step: 1) {
                        Text("\(pageGuideColumn)")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Show Invisible Characters", isOn: $showInvisibles)
                CheckboxRow(label: "Space",              isOn: $showInvisibleSpace)
                CheckboxRow(label: "Tab",                isOn: $showInvisibleTab)
                CheckboxRow(label: "Newline",            isOn: $showInvisibleNewline)
                CheckboxRow(label: "Non-Breaking Space", isOn: $showInvisibleNBSP)
            } header: {
                Text("Invisible Characters")
            } footer: {
                Text("The master switch gates the whole effect; tap a row to toggle each mark.")
            }

            Section("Indentation") {
                Picker("Indent With", selection: $usesTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
                LabeledContent("Width") {
                    Stepper(value: $indentWidth, in: 1...12, step: 1) {
                        Text("\(indentWidth)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
            }

            Section("Editing") {
                Toggle("Insert Closing Brackets / Quotes Automatically", isOn: $insertCharacterPairs)
            }

            Section("Defaults for New Documents") {
                Picker("Text Encoding", selection: defaultEncodingBinding) {
                    ForEach(commonEncodings, id: \.rawValue) { encoding in
                        Text(String.localizedName(of: encoding))
                            .tag(encoding.rawValue)
                    }
                }
                Picker("Line Endings", selection: defaultLineEndingBinding) {
                    ForEach(LineEnding.allCases, id: \.self) { lineEnding in
                        Text("\(lineEnding.label)").tag(lineEnding)
                    }
                }
                Picker("Syntax Language", selection: defaultLanguageBinding) {
                    ForEach(LanguageRegistry.all, id: \.identifier) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }
            }

            Section {
                Toggle("Ensure file ends with a newline", isOn: $ensureTrailingNewline)
                Toggle("Trim trailing whitespace", isOn: $trimTrailingWhitespace)
            } header: {
                Text("On Save")
            } footer: {
                Text("Applied each time the document is written to disk — including the debounced auto-save that fires ~800 ms after typing stops. BOM and line endings are handled per document via the encoding and line-ending pickers in the status bar.")
            }

            Section {
                Picker("Apply syntax & folding", selection: syntaxLimitBinding) {
                    ForEach(SyntaxLimit.allCases) { limit in
                        Text(limit.label).tag(limit)
                    }
                }
            } header: {
                Text("Large Files")
            } footer: {
                Text("Files over the limit open in plain-text mode for snappy typing. Tree-sitter syntax highlighting, code folding, and the Markdown inline decorator are all skipped.")
            }

            iCloudSection
        }
        // No `.formStyle(.grouped)`: it runs sections edge-to-edge
        // and looks bad on iPhone (sheet = screen width). Default
        // resolves to `insetGrouped`, which has comfortable padding.
    }

    /// Toggle for the iCloud Drive sync that drafts + templates
    /// flow through. The launcher always reads from both iCloud and
    /// local locations, so flipping the toggle is non-destructive —
    /// nothing existing gets stranded or moved. The header copy
    /// changes when iCloud is unavailable so the user understands
    /// why the toggle is disabled.
    @ViewBuilder
    private var iCloudSection: some View {
        let signedIn = UbiquityContainer.isAvailable
        Section {
            Toggle("Sync via iCloud Drive", isOn: $iCloudSyncEnabled)
                .disabled(!signedIn)
        } header: {
            Text("iCloud")
        } footer: {
            if signedIn {
                Text("New drafts and template seeds are written to iCloud Drive and sync across your devices. Switching this off keeps existing iCloud files reachable in the launcher — new content just goes to local storage instead.")
            } else {
                Text("Sign in to iCloud and enable Drive in the system settings to sync drafts and templates across your devices.")
            }
        }
    }
}

// MARK: - Typing

private struct TypingPreferencesTab: View {

    @AppStorage(AppPreferenceKey.autoCorrect) private var autoCorrect: Bool = false
    @AppStorage(AppPreferenceKey.autoCapitalize) private var autoCapitalize: Bool = false
    @AppStorage(AppPreferenceKey.smartQuotes) private var smartQuotes: Bool = false
    @AppStorage(AppPreferenceKey.spellCheck) private var spellCheck: Bool = false
    @AppStorage(AppPreferenceKey.autoContinueLists) private var autoContinueLists: Bool = true

    @State private var snippetsStore = SnippetsStore.shared
    @State private var editingSnippet: Snippet?

    @State private var jsStore = JSTransformStore.shared
    @State private var editingJSSlot: JSTransformSlot?

    var body: some View {
        Form {
            Section("System Input Assistance") {
                Toggle("Auto-correct", isOn: $autoCorrect)
                Toggle("Auto-capitalize", isOn: $autoCapitalize)
                Toggle("Smart Quotes & Dashes", isOn: $smartQuotes)
                Toggle("Live Spell Check", isOn: $spellCheck)
            }

            Section {
                Text("These are typically left off for plain-text and code editing — they change the bytes you type. The walk-through spell checker (Check Spelling… in the command palette) is always available regardless of these toggles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-continue lists", isOn: $autoContinueLists)
            } header: {
                Text("Editing Helpers")
            } footer: {
                Text("Pressing return on a list line repeats the bullet (-, *, +) or increments the number on the next line. Pressing return on an empty list line drops the marker.")
            }

            // Ten fixed slots mirroring JS Transforms. The Text ▸
            // Snippets menu and Edit ▸ Save Selection as Snippet both
            // funnel here; tap a row to edit name + content.
            Section {
                ForEach(snippetsStore.slots) { slot in
                    Button {
                        editingSnippet = slot
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(slot.id).")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.displayName)
                                    .foregroundStyle(slot.isConfigured ? .primary : .secondary)
                                Text(slot.isConfigured ? snippetPreview(slot.content) : "Empty")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 0)
                            Text(SnippetsStore.shortcutHint(for: slot.id))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Ten fixed slots, invoked from the **Text ▸ Snippets** menu or with ⌥⌘1–⌥⌘9 (⌥⌘0 for slot 10). Edit ▸ Save Selection as Snippet writes into the first empty slot.")
            }

            Section {
                ForEach(jsStore.slots) { slot in
                    Button {
                        editingJSSlot = slot
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(slot.id).")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.displayName)
                                    .foregroundStyle(slot.isConfigured ? .primary : .secondary)
                                Text(slot.isConfigured ? slot.scope.label : "Empty")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text(slotShortcutHint(for: slot.id))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("JavaScript Transforms")
            } footer: {
                Text("Each slot runs a snippet of JavaScript against the document or current selection. Invoke from the **Text ▸ JavaScript Transforms** menu or with ⌃⌥1–⌃⌥9 (⌃⌥0 for slot 10). The script's last expression — or its `output` variable — replaces the target text.")
            }

            // No public API to add Text Replacement entries —
            // `openSettingsURLString` is the closest we can get, and
            // lands on the app's Settings page.
            Section {
                Button {
                    openSystemSettings()
                } label: {
                    Label("Open iOS Settings…", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("System Text Replacement")
            } footer: {
                Text("Manage system-wide typing shortcuts (e.g. \"omw\" → \"On my way!\") in iOS Settings ▸ General ▸ Keyboard ▸ Text Replacement. They're shared across every app on your device.")
            }
        }
        .sheet(item: $editingSnippet) { slot in
            SnippetEditorSheet(slot: slot) { updated in
                snippetsStore.update(updated)
            }
        }
        .sheet(item: $editingJSSlot) { slot in
            JSTransformEditorSheet(slot: slot) { updated in
                jsStore.update(updated)
            }
        }
    }

    private func slotShortcutHint(for id: Int) -> String {
        let key = id == 10 ? "0" : "\(id)"
        return "⌃⌥\(key)"
    }

    private func snippetPreview(_ body: String) -> String {
        body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" })
            .first.map(String.init) ?? "(empty)"
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Toolbar

private struct ToolbarPreferencesTab: View {

    @AppStorage(AppPreferenceKey.showToolbar) private var showToolbar: Bool = true
    @State private var config = ToolbarConfig.shared
    @State private var addingSlot: Bool = false
    @State private var editingIndex: Int?

    private let registry: [EditorCommandSpec] = CommandRegistry.all()

    var body: some View {
        Form {
            Section {
                Toggle("Show toolbar at top of every window", isOn: $showToolbar)
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
        // No `.formStyle(.grouped)`: it runs sections edge-to-edge
        // and looks bad on iPhone (sheet = screen width). Default
        // resolves to `insetGrouped`, which has comfortable padding.
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
        registry.first(where: { $0.id == id })?.title ?? id
    }

    private struct EditingSlotID: Identifiable {
        let value: Int
        var id: Int { value }
    }
}

/// Fuzzy-searched command picker + SF Symbol name input. Save
/// appends via `ToolbarConfig.insert(_:)`.
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
