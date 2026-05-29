import SwiftUI

/// "Couldn't open file" alert. Extracted from `EditorView.body` for
/// the same reason as the stale-source / batch-close alerts — the
/// alert(_:isPresented:presenting:) trailing-closure call counts
/// against the Swift type-checker's expression budget.
struct OpenErrorAlertModifier: ViewModifier {

    @Binding var presented: Bool
    let message: String?

    func body(content: Content) -> some View {
        content.alert(
            "Couldn't open file",
            isPresented: $presented,
            presenting: message
        ) { _ in
            Button("OK") { AppStateBus.shared.presentation.openErrorMessage = nil }
        } message: { text in
            Text(text)
        }
    }
}
