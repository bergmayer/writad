import SwiftUI

/// iPhone-only navigation-bar toolbar: gear + file (leading), edit
/// title (principal), undo + palette/overflow (trailing). Extracted as
/// a `ToolbarContent` value so the five inline `ToolbarItem`s don't
/// inflate `EditorView.body` past the Swift type-checker's expression
/// budget. The palette-entry branch depends on whether the in-app
/// WindowToolbar is enabled — when the user has hidden the WindowToolbar
/// the trailing slot becomes a single palette button; otherwise it's
/// the combined Toolbar Actions menu.
struct PhoneEditorToolbar: ToolbarContent {

    let documentTitle: String
    let showToolbarPref: Bool
    let claimFocus: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                claimFocus()
                CommandActions.presentPreferences()
            } label: {
                Image(systemName: "gear")
            }
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                claimFocus()
                CommandActions.presentFileBrowser()
            } label: {
                Image(systemName: "folder")
            }
            .accessibilityLabel("Open File")
        }
        ToolbarItem(placement: .principal) {
            // Tappable / renameable title replaces the system
            // navigationTitle so the iPhone gets BBEdit-style inline
            // rename without a separate sheet.
            EditableTitleView(
                title: documentTitle,
                titleFont: .headline,
                maxRenameWidth: 200
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                claimFocus()
                CommandActions.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel("Undo")
        }
        ToolbarItem(placement: .topBarTrailing) {
            paletteEntry
        }
    }

    @ViewBuilder
    private var paletteEntry: some View {
        if showToolbarPref {
            combinedMenu
        } else {
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Image(systemName: "command.square")
            }
            .accessibilityLabel("Command Palette")
        }
    }

    @ViewBuilder
    private var combinedMenu: some View {
        let slots = ToolbarConfig.shared.slots
        Menu {
            // Palette pinned at top — same affordance with toolbar off.
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Label("Command Palette…", systemImage: "command.square")
            }
            if !slots.isEmpty {
                Divider()
                ForEach(slots) { slot in
                    if let cmd = CommandRegistry.lookup(id: slot.commandId) {
                        Button {
                            claimFocus()
                            if cmd.isEnabled() { cmd.action() }
                        } label: {
                            Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                        }
                        .disabled(!cmd.isEnabled())
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.rectangle")
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel("Toolbar Actions")
    }
}
