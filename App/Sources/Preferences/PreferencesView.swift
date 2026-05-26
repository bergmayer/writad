import SwiftUI
import FileEncoding
import LineEnding

/// Mac-style multi-select row. Tapping the row flips the bool; the leading
/// glyph is a filled checkmark when on, an empty square when off. iOS
/// doesn't ship a stock `.checkbox` Toggle style, so this is a small
/// composed view.
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
        // Minimum frame is iPad-only — iPhone presents as a sheet
        // where the frame is the screen width; forcing 520pt would
        // clip on a compact-width device.
        .frame(minWidth: DeviceIdiom.isPhone ? nil : 520,
               minHeight: DeviceIdiom.isPhone ? nil : 420)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(DeviceIdiom.isPhone ? .inline : .automatic)
        .toolbar {
            // Sheet presentation on iPhone needs a Done button —
            // there's no system-supplied dismiss affordance.
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
    @AppStorage(AppPreferenceKey.launchBehavior) private var launchBehaviorRaw: String = LaunchBehavior.newBlank.rawValue
    @AppStorage(AppPreferenceKey.syntaxLimitBytes) private var syntaxLimitRaw: Int = SyntaxLimit.up5MB.rawValue

    /// Stepper drives an `Int` and we round-trip through the
    /// `Double`-backed `@AppStorage` so other consumers (live editor
    /// state, menu zoom commands) keep working unchanged.
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

    private var launchBehaviorBinding: Binding<LaunchBehavior> {
        Binding(
            get: { LaunchBehavior(rawValue: launchBehaviorRaw) ?? .newBlank },
            set: { launchBehaviorRaw = $0.rawValue }
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
                    // Monospaced faces grouped first since they're
                    // the typical pick for a code editor.
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

            // The old app-wide "Open documents in" picker is gone —
            // the File menu now exposes explicit "Open in New Tab…"
            // and "Open in New Window…" entries (plus the plain
            // "Open…" which defaults to a new window on iPad).

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

            Section("On Launch") {
                Picker("When no windows are restored", selection: launchBehaviorBinding) {
                    ForEach(LaunchBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
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
        }
        // No .formStyle(.grouped) — that style runs the sections
        // edge-to-edge with no horizontal margin, which looked bad
        // on iPhone (sheet width = screen width). The default style
        // resolves to insetGrouped on iOS, which gives the rounded
        // cards with comfortable side padding.
    }
}

// MARK: - Format (deprecated; merged into Editor)


// MARK: - Typing

private struct TypingPreferencesTab: View {

    @AppStorage(AppPreferenceKey.autoCorrect) private var autoCorrect: Bool = false
    @AppStorage(AppPreferenceKey.autoCapitalize) private var autoCapitalize: Bool = false
    @AppStorage(AppPreferenceKey.smartQuotes) private var smartQuotes: Bool = false
    @AppStorage(AppPreferenceKey.spellCheck) private var spellCheck: Bool = false
    @AppStorage(AppPreferenceKey.autoContinueLists) private var autoContinueLists: Bool = true
    @AppStorage(AppPreferenceKey.keyboardShowsBracketPairs) private var kbBrackets: Bool = false

    @State private var snippetsStore = SnippetsStore.shared
    @State private var editingSnippet: Snippet?
    @State private var addingSnippet: Bool = false

    @State private var jsStore = JSTransformStore.shared
    @State private var editingJSSlot: JSTransformSlot?

    var body: some View {
        Form {
            Section("System Input Assistance") {
                Toggle("Auto-correct", isOn: $autoCorrect)
                Toggle("Auto-capitalize", isOn: $autoCapitalize)
                Toggle("Smart Quotes & Dashes", isOn: $smartQuotes)
                Toggle("Check Spelling", isOn: $spellCheck)
            }

            Section {
                Text("These are typically left off for plain-text and code editing — they change the bytes you type.")
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

            Section {
                Toggle("Bracket pair keys (), [], {}, <>", isOn: $kbBrackets)
            } header: {
                Text("On-Screen Keyboard Extras")
            } footer: {
                Text("Bracket pairs appear in the keyboard's shortcut bar above the soft keyboard. Changes apply the next time the keyboard appears.")
            }

            // Per-app snippet management. The snippet picker (palette
            // → "Insert Snippet…") pulls from this list; the keyboard
            // accessory bar and the Edit menu's Save Selection-as-
            // Snippet write into the same store.
            Section {
                if snippetsStore.snippets.isEmpty {
                    Text("No snippets yet. Tap **Add Snippet** to create one, or save the current selection from the editor.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snippetsStore.snippets) { snippet in
                        Button {
                            editingSnippet = snippet
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.name.isEmpty ? "(unnamed)" : snippet.name)
                                        .foregroundStyle(.primary)
                                    Text(snippetPreview(snippet.content))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        snippetsStore.remove(at: offsets)
                    }
                    .onMove { source, destination in
                        snippetsStore.move(from: source, to: destination)
                    }
                }
                Button {
                    addingSnippet = true
                } label: {
                    Label("Add Snippet", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Snippets insert their content at the cursor. Invoke from the command palette ⇧⌘P → \"Insert Snippet…\".")
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

            // System-level text replacement lives in iOS Settings. We
            // can't add entries on the user's behalf (no public API),
            // but `openSettingsURLString` drops them at the app's
            // Settings page; from there they navigate to General ▸
            // Keyboard ▸ Text Replacement.
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
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorSheet(snippet: bindingForExisting(snippet)) { updated in
                snippetsStore.update(updated)
            }
        }
        .sheet(item: $editingJSSlot) { slot in
            JSTransformEditorSheet(slot: slot) { updated in
                jsStore.update(updated)
            }
        }
        .sheet(isPresented: $addingSnippet) {
            // Start with an empty snippet; commit-or-cancel handled
            // by SnippetEditorSheet — `add` is only called if the
            // user taps Save.
            SnippetEditorSheet(snippet: .constant(Snippet(name: "", content: ""))) { created in
                snippetsStore.add(created)
            }
        }
    }

    private func slotShortcutHint(for id: Int) -> String {
        let key = id == 10 ? "0" : "\(id)"
        return "⌃⌥\(key)"
    }

    private func bindingForExisting(_ snippet: Snippet) -> Binding<Snippet> {
        Binding(
            get: { snippet },
            set: { newValue in
                editingSnippet = newValue
            }
        )
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
        // No .formStyle(.grouped) — that style runs the sections
        // edge-to-edge with no horizontal margin, which looked bad
        // on iPhone (sheet width = screen width). The default style
        // resolves to insetGrouped on iOS, which gives the rounded
        // cards with comfortable side padding.
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

/// Sheet for appending a new toolbar slot. Lets the user pick a command
/// from a fuzzy-searched list and enter an SF Symbol name; on Save the
/// slot is appended via `ToolbarConfig.insert(_:)`.
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
