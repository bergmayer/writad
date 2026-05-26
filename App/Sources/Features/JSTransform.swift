import SwiftUI
import JavaScriptCore
import UIKit

// MARK: - Model

/// One JavaScript transform slot. The user writes code that operates
/// on `input` (the document or the selection) and produces a string
/// result — the value of the last expression in the script, or the
/// value assigned to `output`.
///
/// 10 slots are persisted permanently; menu / keyboard slots 1–9 map
/// to indices 0–8, slot 10 (⌃⌥0) maps to index 9 — same convention
/// as the tab-jump shortcuts.
struct JSTransformSlot: Codable, Equatable, Identifiable {
    var id: Int          // 1...10
    var name: String
    var code: String
    var scope: Scope

    enum Scope: String, Codable, CaseIterable {
        case document   // input = full document text
        case selection  // input = selected text (or empty if no selection)

        var label: String {
            switch self {
            case .document:  "Whole Document"
            case .selection: "Selection"
            }
        }
    }

    static func empty(id: Int) -> JSTransformSlot {
        JSTransformSlot(id: id, name: "", code: "", scope: .selection)
    }

    var isConfigured: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Slot \(id)" : trimmed
    }
}

@MainActor
@Observable
final class JSTransformStore {

    static let shared = JSTransformStore()
    static let slotCount = 10

    private(set) var slots: [JSTransformSlot]

    private init() {
        self.slots = Self.load() ?? Self.defaultSlots()
        Self.seedSampleSlotIfEmpty(into: &slots)
    }

    /// Default sample placed in slot 1 on first launch — a small,
    /// self-contained transform that shows the model (input
    /// string in / output string out) without needing the user to
    /// understand JSON, regex, or anything domain-specific. ROT13
    /// fits: it's reversible (run it twice to get back the original),
    /// has no parse-error branch, and is famously simple. Won't
    /// overwrite a user-edited slot 1.
    private static let sampleJSCode: String = """
    // ROT13: rotates each letter 13 places through the alphabet.
    // Running this transform twice on the same text restores the
    // original — a quick way to show the input/output model:
    // `input` is the selected text (or whole document), and the
    // script's job is to assign the transformed string to `output`.
    output = input.replace(/[A-Za-z]/g, function (ch) {
      const base = ch <= 'Z' ? 65 : 97;
      return String.fromCharCode((ch.charCodeAt(0) - base + 13) % 26 + base);
    });
    """

    private static func defaultSlots() -> [JSTransformSlot] {
        var slots = (1...Self.slotCount).map(JSTransformSlot.empty)
        slots[0] = JSTransformSlot(id: 1, name: "ROT13",
                                    code: sampleJSCode, scope: .selection)
        return slots
    }

    /// One-time seed if a long-time user upgraded into the sample
    /// — only fills slot 1 when both its name and code are empty.
    private static func seedSampleSlotIfEmpty(into slots: inout [JSTransformSlot]) {
        guard let first = slots.first,
              first.name.isEmpty,
              first.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        slots[0] = JSTransformSlot(id: 1, name: "ROT13",
                                    code: sampleJSCode, scope: .selection)
    }

    func update(_ slot: JSTransformSlot) {
        guard let idx = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[idx] = slot
        save()
    }

    /// Slot index by id (1-based). Returns nil for out-of-range
    /// callers (e.g. menu shortcuts that lost sync with storage).
    func slot(id: Int) -> JSTransformSlot? {
        slots.first(where: { $0.id == id })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.jsTransformSlots)
    }

    private static func load() -> [JSTransformSlot]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.jsTransformSlots),
              let decoded = try? JSONDecoder().decode([JSTransformSlot].self, from: data),
              decoded.count == JSTransformStore.slotCount
        else { return nil }
        return decoded
    }
}

// MARK: - Execution

/// Runs a slot's JavaScript against the slot's scoped input and writes
/// the result back to the editor. Captured exceptions surface through
/// `bus.editing.openErrorMessage` rather than crashing the JSContext.
@MainActor
enum JSTransformRunner {

    static func run(_ slot: JSTransformSlot) {
        guard slot.isConfigured else { return }
        guard let textView = AppStateBus.shared.scenes.currentEditor?.textView else { return }

        let (input, replaceRange): (String, NSRange) = {
            switch slot.scope {
            case .document:
                return (textView.text, NSRange(location: 0, length: (textView.text as NSString).length))
            case .selection:
                let sel = textView.selectedRange
                guard sel.length > 0, let s = textView.text(in: sel) else {
                    // Fall through with empty input; user gets ""
                    // — they can still produce output that we'll
                    // insert at the cursor.
                    return ("", sel)
                }
                return (s, sel)
            }
        }()

        switch evaluate(code: slot.code, input: input) {
        case .ok(let output):
            textView.replace(replaceRange, withText: output)
        case .failed(let message):
            AppStateBus.shared.editing.openErrorMessage =
                "\(slot.displayName): \(message)"
        }
    }

    /// Outcome of evaluating a transform. We don't lift the failure
    /// into Swift's `Error` protocol because the failure value is just
    /// the JS engine's exception text — there's no Swift call site
    /// that needs to propagate it as a typed error.
    private enum Outcome {
        case ok(String)
        case failed(String)
    }

    /// Evaluate the user's JS with `input` and `text` predefined as
    /// the source string. The script's last expression value is the
    /// transform result; if the user assigned to `output`, that wins.
    /// Exceptions from inside the script come back as `.failed`.
    private static func evaluate(code: String, input: String) -> Outcome {
        guard let ctx = JSContext() else {
            return .failed("Couldn't create a JavaScript context.")
        }
        var errorMessage: String?
        ctx.exceptionHandler = { _, exception in
            errorMessage = exception?.toString() ?? "Unknown JavaScript error."
        }
        ctx.setObject(input, forKeyedSubscript: "input" as NSString)
        ctx.setObject(input, forKeyedSubscript: "text"  as NSString)
        ctx.setObject(NSNull(), forKeyedSubscript: "output" as NSString)

        let lastExpression = ctx.evaluateScript(code)

        if let errorMessage {
            return .failed(errorMessage)
        }
        let outputGlobal = ctx.objectForKeyedSubscript("output")
        if let outputGlobal, !outputGlobal.isNull, !outputGlobal.isUndefined {
            return .ok(outputGlobal.toString() ?? "")
        }
        if let last = lastExpression, !last.isUndefined, !last.isNull {
            return .ok(last.toString() ?? "")
        }
        return .ok("")
    }
}

// MARK: - Editor sheet

/// Per-slot editor presented from the Typing settings pane. Edits a
/// copy of the slot and writes through to the store on Save.
struct JSTransformEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var draft: JSTransformSlot
    let onSave: (JSTransformSlot) -> Void

    init(slot: JSTransformSlot, onSave: @escaping (JSTransformSlot) -> Void) {
        self._draft = State(initialValue: slot)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Reverse Lines", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Scope") {
                    Picker("Apply To", selection: $draft.scope) {
                        ForEach(JSTransformSlot.Scope.allCases, id: \.self) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextEditor(text: $draft.code)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("JavaScript")
                } footer: {
                    Text("`input` (or `text`) holds the source string. Return the result as the last expression, or assign it to `output`. Example: `input.split('\\n').reverse().join('\\n')`.")
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
