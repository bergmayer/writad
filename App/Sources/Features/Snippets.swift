import SwiftUI
import UIKit

// MARK: - Snippets model

/// One snippet slot. Ten slots (1...10) persist permanently and map
/// to the Text ▸ Snippets menu / keyboard shortcuts — mirrors the
/// `JSTransformSlot` model so the two surfaces feel the same.
struct Snippet: Codable, Equatable, Identifiable {
    var id: Int       // 1...10
    var name: String
    var content: String

    static func empty(id: Int) -> Snippet {
        Snippet(id: id, name: "", content: "")
    }

    /// Empty `content` (whitespace-only counts as empty) means the
    /// slot's menu entry stays visible but disabled — placeholders
    /// for unset slots, parallel to JS Transforms.
    var isConfigured: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Snippet \(id)" : trimmed
    }
}

@MainActor
@Observable
final class SnippetsStore {

    static let shared = SnippetsStore()
    static let slotCount = 10

    private(set) var slots: [Snippet]

    private init() {
        self.slots = Self.load() ?? Self.defaultSlots()
    }

    private static func defaultSlots() -> [Snippet] {
        (1...slotCount).map(Snippet.empty)
    }

    func update(_ snippet: Snippet) {
        guard let idx = slots.firstIndex(where: { $0.id == snippet.id }) else { return }
        slots[idx] = snippet
        save()
    }

    /// Look up a slot by its 1-based id. Returns nil for out-of-range
    /// callers (e.g. menu shortcuts that lost sync with storage).
    func slot(id: Int) -> Snippet? {
        slots.first(where: { $0.id == id })
    }

    /// Writes `name`/`content` into the first unconfigured slot.
    /// Returns the slot id, or nil if every slot is already used —
    /// the menu's "Save Selection as Snippet" action surfaces the
    /// failure as a status message rather than overwriting silently.
    @discardableResult
    func saveToFirstEmpty(name: String, content: String) -> Int? {
        guard let idx = slots.firstIndex(where: { !$0.isConfigured }) else { return nil }
        let id = slots[idx].id
        slots[idx] = Snippet(id: id, name: name, content: content)
        save()
        return id
    }

    func clear(slotId id: Int) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[idx] = Snippet.empty(id: id)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.snippetSlots)
    }

    private static func load() -> [Snippet]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.snippetSlots),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data),
              decoded.count == SnippetsStore.slotCount
        else { return nil }
        return decoded
    }
}

// MARK: - Snippet slot editor

/// Per-slot editor presented from the Typing settings pane and from
/// the Manage Snippets sheet. Edits a copy of the slot; writes
/// through on Save.
struct SnippetEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Snippet
    let onSave: (Snippet) -> Void

    init(slot: Snippet, onSave: @escaping (Snippet) -> Void) {
        self._draft = State(initialValue: slot)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Email Signature", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextEditor(text: $draft.content)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Content")
                } footer: {
                    Text("Inserted at the cursor as-is. Leave content empty to clear the slot.")
                }
            }
            .navigationTitle("Slot \(draft.id): \(draft.name.isEmpty ? "(unnamed)" : draft.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Snippets manager sheet

/// Edit ▸ Snippets ▸ Manage Snippets opens here. Mirrors the JS
/// Transforms settings layout: ten fixed rows, tap to edit.
struct SnippetsManagerSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var store = SnippetsStore.shared
    @State private var editing: Snippet?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.slots) { slot in
                        Button {
                            editing = slot
                        } label: {
                            slotRow(slot)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Ten fixed slots, invoked from **Text ▸ Snippets** in the menu or with ⌥⌘1–⌥⌘9 (⌥⌘0 for slot 10). Empty slots are greyed out in the menu.")
                }
            }
            .navigationTitle("Manage Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { slot in
                SnippetEditorSheet(slot: slot) { updated in
                    store.update(updated)
                }
            }
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: Snippet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(slot.id).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.displayName)
                    .foregroundStyle(slot.isConfigured ? .primary : .secondary)
                Text(slot.isConfigured ? preview(of: slot.content) : "Empty")
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

    private func preview(of body: String) -> String {
        body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" })
            .first.map(String.init) ?? ""
    }
}

extension SnippetsStore {
    /// Human-readable hint for the per-slot keyboard shortcut. Used
    /// in Preferences + the manager sheet so the user can see which
    /// keys map where without launching every slot.
    static func shortcutHint(for id: Int) -> String {
        let key = id == 10 ? "0" : "\(id)"
        return "⌥⌘\(key)"
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

    // Deliberately no capture at init or on app activation: reading
    // `UIPasteboard.general.string` outside an explicit user action
    // triggers the iOS paste-permission banner on every launch /
    // foreground. The history learns about cross-app copies only when
    // the user opens the chooser sheet (its `onAppear` captures).
    private init() {
        NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
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
            // Lazy capture point for copies made outside the app —
            // see the `ClipboardHistory.init` comment.
            .onAppear { history.capture() }
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
