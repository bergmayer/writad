import SwiftUI

struct TypingPreferencesTab: View {

    @Bindable private var prefs = AppPreferencesStore.shared

    @State private var snippetsStore = SnippetsStore.shared
    @State private var editingSnippet: Snippet?

    @State private var jsStore = JSTransformStore.shared
    @State private var editingJSSlot: JSTransformSlot?

    var body: some View {
        Form {
            Section("System Input Assistance") {
                Toggle("Auto-correct", isOn: $prefs.autoCorrect)
                Toggle("Auto-capitalize", isOn: $prefs.autoCapitalize)
                Toggle("Smart Quotes & Dashes", isOn: $prefs.smartQuotes)
                Toggle("Live Spell Check", isOn: $prefs.spellCheck)
            }

            Section {
                Text("These are typically left off for plain-text and code editing — they change the bytes you type. The walk-through spell checker (Check Spelling… in the command palette) is always available regardless of these toggles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-continue lists", isOn: $prefs.autoContinueLists)
            } header: {
                Text("Editing Helpers")
            } footer: {
                Text("Pressing return on a list line repeats the bullet (-, *, +) or increments the number on the next line. Pressing return on an empty list line drops the marker.")
            }

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

            // No public API for Text Replacement; openSettingsURLString
            // is the closest hop and lands on this app's Settings page.
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
