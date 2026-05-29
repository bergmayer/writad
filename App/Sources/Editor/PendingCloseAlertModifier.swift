import SwiftUI

/// Close-with-unsaved confirmation: Save / Save as Draft / Discard /
/// Cancel. Extracted because the inline alert with four Buttons +
/// presenting + message closure was the biggest single expression in
/// `EditorView.body`.
struct PendingCloseAlertModifier: ViewModifier {

    @Binding var presented: Bool
    let pending: PendingClose?

    func body(content: Content) -> some View {
        content.alert(
            "Close \(pending?.displayName ?? "tab")?",
            isPresented: $presented,
            presenting: pending
        ) { pending in
            buttons(for: pending)
        } message: { pending in
            Text(pending.isUntitled
                 ? "This document is untitled. Save it to a file, keep it as an unsaved draft, or discard the contents."
                 : "This document has unsaved changes since its last save.")
        }
    }

    @ViewBuilder
    private func buttons(for pending: PendingClose) -> some View {
        // Saved files write back to the existing URL; untitled buffers
        // open Save As, then the tab closes.
        Button(pending.isUntitled ? "Save…" : "Save and Close") {
            CommandActions.confirmSaveAndClose(pending)
        }
        // Save as Draft keeps the edits in the unsaved-drafts list
        // (reachable from the launcher) without writing them to a file
        // — fastest way out of the dialog when the user isn't ready
        // to pick a filename.
        Button("Save as Draft") {
            CommandActions.saveAsDraftAndClose(pending)
        }
        Button("Discard Changes", role: .destructive) {
            CommandActions.confirmDiscardAndClose(pending)
        }
        Button("Cancel", role: .cancel) { CommandActions.cancelPendingClose() }
    }
}
