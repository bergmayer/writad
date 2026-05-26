import SwiftUI

/// Word-style walk-through: one misspelling at a time, with
/// suggestions and Change / Ignore / Learn actions. Works regardless
/// of the per-tab live-spell-check toggle — the user can audit a
/// document without enabling the inline squiggles.
struct SpellCheckSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Range of the current flagged word in the document, or `nil`
    /// when the walk has finished (or never found anything).
    @State private var currentRange: NSRange?
    @State private var currentWord: String = ""
    @State private var suggestions: [String] = []
    @State private var replacement: String = ""
    @State private var finished: Bool = false

    private var actions: (any EditorActions)? {
        AppStateBus.shared.scenes.currentEditor?.textView
    }

    private var startLocation: Int {
        AppStateBus.shared.scenes.currentEditor?.selectedRange.location ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if finished {
                    Section {
                        Label("Spell check complete.", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }
                } else if currentRange == nil {
                    Section {
                        ProgressView("Scanning…")
                    }
                } else {
                    Section("Not in dictionary") {
                        Text(currentWord)
                            .font(.title3.monospaced())
                            .foregroundStyle(.red)
                        TextField("Replacement", text: $replacement)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Suggestions") {
                        if suggestions.isEmpty {
                            Text("(no suggestions)")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(suggestions, id: \.self) { sug in
                                Button {
                                    replacement = sug
                                } label: {
                                    HStack {
                                        Text(sug)
                                            .font(.body.monospaced())
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if sug == replacement {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section {
                        Button("Change") { change() }
                            .disabled(replacement.isEmpty || replacement == currentWord)
                        Button("Ignore") { advance() }
                        Button("Ignore All") { ignoreAll() }
                        Button("Learn") { learn() }
                    }
                }
            }
            .navigationTitle("Check Spelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(finished ? "Done" : "Stop") { dismiss() }
                }
            }
            .onAppear { findNext(from: startLocation) }
        }
    }

    /// Locates the next misspelling, updates state, and scrolls the
    /// document so the flagged word is visible behind the sheet.
    private func findNext(from location: Int) {
        guard let actions, let hit = actions.nextMisspelling(from: location) else {
            currentRange = nil
            currentWord = ""
            suggestions = []
            replacement = ""
            finished = true
            return
        }
        currentRange = hit.range
        currentWord = hit.word
        suggestions = hit.suggestions
        replacement = hit.suggestions.first ?? hit.word
        finished = false
        actions.setSelection(hit.range)
        actions.scrollSelectionToVisible()
    }

    private func change() {
        guard let actions, let range = currentRange, !replacement.isEmpty else { return }
        actions.replace(range, withText: replacement)
        // Advance past the replacement so we don't re-flag the
        // freshly-corrected word.
        let nextStart = range.location + (replacement as NSString).length
        findNext(from: nextStart)
    }

    private func advance() {
        guard let range = currentRange else { return }
        findNext(from: NSMaxRange(range))
    }

    private func ignoreAll() {
        guard let actions, !currentWord.isEmpty else { return }
        actions.ignoreWord(currentWord)
        guard let range = currentRange else { return }
        findNext(from: NSMaxRange(range))
    }

    private func learn() {
        guard let actions, !currentWord.isEmpty else { return }
        actions.learnWord(currentWord)
        guard let range = currentRange else { return }
        findNext(from: NSMaxRange(range))
    }
}
