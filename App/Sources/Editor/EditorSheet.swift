import Foundation

/// Sheet presentation cases the active editor scene can fire via
/// `AppStateBus.shared.editing.presentedSheet`. Identifiable id is
/// used by SwiftUI's `.sheet(item:)` to drive presentation.
enum EditorSheet: Identifiable {
    case encodingPicker
    case lineEndingPicker
    case languagePicker
    case characterInspector
    case sortLines
    case goToLine
    case selectLinesContaining
    case findReplace
    case zapGremlins
    case revisions
    case commandPalette
    case fileBrowser
    case multiFileSearch
    case preferences
    case prefixSuffixLines
    case insertLoremIpsum
    case snippetPicker
    case snippetsManager
    case clipboardHistory
    /// Launch-time recovery sheet for `DraftsStore` — surfaces every
    /// recoverable Untitled draft from prior sessions so the user
    /// can re-open or discard them.
    case draftsRecovery
    case tabSwitcher
    case processLines
    case canonize
    case characterPanel
    // case notebooks removed — feature retired.
    case markdownTable
    /// iPhone-only fallback for the Markdown Preview window. iPad
    /// opens a real second scene via `openWindow`; iPhone (single-
    /// window device) gets the same view presented as a dismissable
    /// sheet so it actually appears.
    case markdownPreview
    case organizeFootnotes

    var id: String {
        switch self {
        case .encodingPicker:        return "encoding"
        case .lineEndingPicker:      return "lineEnding"
        case .languagePicker:        return "language"
        case .characterInspector:    return "character"
        case .sortLines:             return "sort"
        case .goToLine:              return "goToLine"
        case .selectLinesContaining: return "selectLines"
        case .findReplace:           return "findReplace"
        case .zapGremlins:           return "zapGremlins"
        case .revisions:             return "revisions"
        case .commandPalette:        return "commandPalette"
        case .fileBrowser:           return "fileBrowser"
        case .multiFileSearch:       return "multiFileSearch"
        case .preferences:           return "preferences"
        case .prefixSuffixLines:     return "prefixSuffix"
        case .insertLoremIpsum:      return "lipsum"
        case .snippetPicker:         return "snippetPicker"
        case .snippetsManager:       return "snippetsManager"
        case .clipboardHistory:      return "clipboardHistory"
        case .draftsRecovery:        return "draftsRecovery"
        case .tabSwitcher:           return "tabSwitcher"
        case .processLines:          return "processLines"
        case .canonize:              return "canonize"
        case .characterPanel:        return "characterPanel"
        // .notebooks removed.
        case .markdownTable:         return "markdownTable"
        case .markdownPreview:       return "markdownPreview"
        case .organizeFootnotes:     return "organizeFootnotes"
        }
    }
}
