import Foundation

/// Mirrors macOS's find pasteboard so ⌘G / ⌘⇧G keep working after
/// the sheet is dismissed.
@MainActor
@Observable
final class FindState {
    var context = FindContext()

    /// One-shot toggles cleared by `FindReplaceSheet.onAppear` after
    /// reading. Let menu items request the sheet with Replace
    /// expanded or in step-through mode.
    var pendingShowReplace = false
    var pendingQueryMode   = false
}

struct FindContext: Equatable {
    var query: String = ""
    var replacement: String = ""
    var useRegex: Bool = false
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
}
