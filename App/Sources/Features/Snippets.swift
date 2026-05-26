import SwiftUI
import UIKit

// MARK: - Snippets model

/// A named text macro. `content` is inserted at the cursor when the
/// snippet is invoked from the Snippets palette / menu.
struct Snippet: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var content: String
}

@MainActor
@Observable
final class SnippetsStore {

    static let shared = SnippetsStore()

    private(set) var snippets: [Snippet]

    private init() {
        self.snippets = Self.load() ?? []
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func remove(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.snippets)
    }

    private static func load() -> [Snippet]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.snippets),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return nil }
        return decoded
    }
}

// MARK: - Snippets picker sheet

/// Sheet for picking a snippet to insert. Selecting a row inserts
/// the snippet's content at the cursor and dismisses the sheet.
struct SnippetPickerSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var store = SnippetsStore.shared
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.snippets.isEmpty {
                    ContentUnavailableView(
                        "No snippets yet",
                        systemImage: "doc.text",
                        description: Text("Add snippets in Settings → Typing, or save the current selection from the Edit menu.")
                    )
                } else {
                    // List + tap-gesture row instead of Button-in-row.
                    // On iPhone, a SwiftUI `Button` (even with
                    // `.buttonStyle(.plain)`) inside a `List` row
                    // competes with the List's own row hit area: the
                    // row visibly highlights on touch but the
                    // Button's action never fires, so snippet rows
                    // looked unresponsive. Anchoring the tap on the
                    // row's HStack via `.contentShape(.rect)` +
                    // `.onTapGesture` makes the whole row a single,
                    // reliable hit target on both idioms.
                    List {
                        ForEach(filtered) { snippet in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.name).foregroundStyle(.primary)
                                    Text(preview(of: snippet.content))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                let target = snippet
                                dismiss()
                                // Defer the insert until the sheet's
                                // dismissal animation finishes — on
                                // iPhone the editor only re-becomes
                                // first responder after the sheet is
                                // gone, so inserting mid-dismiss
                                // either drops the keystroke or
                                // lands it on the wrong selection.
                                Task { @MainActor in
                                    try? await Task.sleep(for: Timing.paletteHandoff)
                                    CommandActions.insertSnippet(target)
                                }
                            }
                        }
                    }
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
                }
            }
            .navigationTitle("Insert Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filtered: [Snippet] {
        guard !query.isEmpty else { return store.snippets }
        return store.snippets.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func preview(of body: String) -> String {
        body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" }).first.map(String.init) ?? ""
    }
}

/// Editor for a single snippet — used by Preferences. Pass a binding
/// to the snippet being edited; this sheet doesn't add or remove.
struct SnippetEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Binding var snippet: Snippet
    let onSave: (Snippet) -> Void

    @State private var name: String
    @State private var content: String

    init(snippet: Binding<Snippet>, onSave: @escaping (Snippet) -> Void) {
        self._snippet = snippet
        self.onSave = onSave
        self._name = State(initialValue: snippet.wrappedValue.name)
        self._content = State(initialValue: snippet.wrappedValue.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Snippet name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Content") {
                    TextEditor(text: $content)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(snippet.name.isEmpty ? "New Snippet" : snippet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = snippet
                        updated.name = name
                        updated.content = content
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Snippets manager sheet

/// Full CRUD for the snippet library — Edit ▸ Snippets ▸ Manage
/// Snippets opens here instead of bouncing into Preferences.
struct SnippetsManagerSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var store = SnippetsStore.shared
    /// Editor target. `Optional<Snippet>` instead of `Bool` so the
    /// editor sheet can present per-snippet identity (and SwiftUI's
    /// `.sheet(item:)` reuses the same view for new + edit).
    @State private var editing: EditingTarget?

    /// Wrapper carries both the snippet and whether this is a "new"
    /// session (so the editor's Save creates vs. updates). Conforms to
    /// `Identifiable` for `.sheet(item:)`.
    private struct EditingTarget: Identifiable {
        let id: UUID
        var snippet: Snippet
        let isNew: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.snippets.isEmpty {
                    ContentUnavailableView {
                        Label("No snippets yet", systemImage: "doc.text")
                    } description: {
                        Text("Add a snippet with the + button. Snippets are inserted at the cursor from Edit ▸ Snippets ▸ Insert Snippet…")
                    } actions: {
                        Button {
                            beginAdd()
                        } label: {
                            Label("Add Snippet", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.snippets) { snippet in
                            Button {
                                editing = EditingTarget(id: snippet.id, snippet: snippet, isNew: false)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.name).foregroundStyle(.primary)
                                    Text(preview(of: snippet.content))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in store.remove(at: offsets) }
                        .onMove { from, to in store.move(from: from, to: to) }
                    }
                    .toolbar { EditButton() }
                }
            }
            .navigationTitle("Manage Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        beginAdd()
                    } label: {
                        Label("Add Snippet", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { target in
                SnippetEditorSheet(
                    snippet: Binding(
                        get: { target.snippet },
                        set: { editing?.snippet = $0 }
                    ),
                    onSave: { updated in
                        if target.isNew {
                            store.add(updated)
                        } else {
                            store.update(updated)
                        }
                    }
                )
            }
        }
    }

    private func beginAdd() {
        let blank = Snippet(name: "", content: "")
        editing = EditingTarget(id: blank.id, snippet: blank, isNew: true)
    }

    private func preview(of body: String) -> String {
        body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" }).first.map(String.init) ?? ""
    }
}

// MARK: - Clipboard history

/// App-wide pasteboard tracker. `shared` is the single source of
/// truth — all windows see the same recent-copy list. `⌘⇧V` opens
/// the chooser sheet; tapping an entry pastes it at the active
/// editor's cursor.
@MainActor
@Observable
final class ClipboardHistory {

    static let shared = ClipboardHistory()
    static let maxEntries = 50

    private(set) var entries: [Entry] = []
    private var lastChangeCount: Int = -1

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let body: String
        let timestamp: Date
    }

    private init() {
        capture()
        NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
    }

    /// Snapshot the pasteboard if its `changeCount` advanced. Skips
    /// the entry if it duplicates the head of the list (common after
    /// copy → paste cycles).
    func capture() {
        let board = UIPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        guard let s = board.string, !s.isEmpty else { return }
        if let head = entries.first, head.body == s { return }
        entries.insert(Entry(body: s, timestamp: Date()), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    func clear() { entries.removeAll() }
}

/// Sheet showing every recent clipboard copy. Tap an entry → paste
/// at the active editor's cursor and dismiss. Bound to ⌘⇧V from the
/// Edit menu.
struct ClipboardHistorySheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var history = ClipboardHistory.shared

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    ContentUnavailableView(
                        "Clipboard is empty",
                        systemImage: "doc.on.clipboard",
                        description: Text("Copy text from anywhere — including other apps — to populate the list.")
                    )
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            Button {
                                CommandActions.pasteString(entry.body)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.body)
                                        .font(.body.monospaced())
                                        .lineLimit(3)
                                        .truncationMode(.tail)
                                        .foregroundStyle(.primary)
                                    Text(relativeDate(entry.timestamp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Clipboard History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive) { history.clear() }
                    }
                }
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
