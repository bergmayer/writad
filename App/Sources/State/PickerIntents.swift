import SwiftUI

/// One pending picker at a time — a single optional, not a flag per
/// intent, so two pickers can never both think they're presenting.
@MainActor
@Observable
final class PickerIntents {

    var pending: PickerIntent?

    /// True iff `pending == intent`. Dismissing only clears the
    /// pending intent if it still matches — guards against a stale
    /// dismiss from a previous picker stomping on a newer one.
    func binding(for intent: PickerIntent) -> Binding<Bool> {
        Binding(
            get: { self.pending == intent },
            set: { presenting in
                if presenting {
                    self.pending = intent
                } else if self.pending == intent {
                    self.pending = nil
                }
            }
        )
    }
}

enum PickerIntent: Equatable {
    case open
    case saveAs
    case insertFile
    case insertFolder
}
