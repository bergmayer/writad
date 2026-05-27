import SwiftUI

/// Renders the unsaved-changes confirmation for batch close
/// flows (Close Other Tabs / Close Tabs to the Right / Close All
/// Tabs). Extracted into a ViewModifier so it doesn't push
/// `EditorView.body`'s modifier chain past the Swift type-
/// checker's expression budget — same reason
/// `StaleSourceAlertModifier` lives in its own file.
struct BatchCloseAlertModifier: ViewModifier {

    @Binding var presented: Bool
    let pending: PendingBatchClose?
    let message: (PendingBatchClose) -> String

    func body(content: Content) -> some View {
        content.alert(
            "There are unsaved changes",
            isPresented: $presented,
            presenting: pending
        ) { pending in
            Button("Save to Drafts") {
                CommandActions.confirmBatchSaveAsDrafts(pending)
            }
            Button("Discard", role: .destructive) {
                CommandActions.confirmBatchDiscard(pending)
            }
            Button("Cancel", role: .cancel) {
                CommandActions.cancelBatchClose()
            }
        } message: { pending in
            Text(message(pending))
        }
    }
}
