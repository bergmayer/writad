import UIKit
import EditorEngine

/// The font face used by the editor view. Raw values persist to
/// `UserDefaults` (`AppPreferenceKey.fontName`) and are shown verbatim in
/// the Settings.app picker, so don't rename them lightly.
enum EditorFont: String, CaseIterable, Codable {
    // Monospaced
    case systemMono   = "System Mono"
    case menlo        = "Menlo"
    case courier      = "Courier New"
    case andaleMono   = "Andale Mono"
    // Proportional
    case system       = "System"
    case helvetica    = "Helvetica Neue"
    case georgia      = "Georgia"
    case timesNewRoman = "Times New Roman"
    case avenir       = "Avenir Next"
    case palatino     = "Palatino"

    /// Whether this font face has fixed-width glyphs.
    var isMonospaced: Bool {
        switch self {
        case .systemMono, .menlo, .courier, .andaleMono: true
        default: false
        }
    }

    var displayName: String { rawValue }

    /// Build a concrete `UIFont` at the requested point size. Falls back to
    /// the system monospaced face if a named font isn't installed.
    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .systemMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system:
            return .systemFont(ofSize: size)
        default:
            return UIFont(name: rawValue, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Resolve a stored raw value (legacy or sentinel) to a known case.
    init(stored value: String?) {
        if let value, let resolved = EditorFont(rawValue: value) {
            self = resolved
        } else {
            self = .systemMono
        }
    }
}

/// The persisted theme name. The legacy value "Default" maps to `.automatic`.
/// Beyond the original Automatic/Light/Dark, the textamp-ported themes
/// are stored here too; resolution happens in `AppTheme.current(_:…)`.
enum AppThemeName: String, CaseIterable, Codable {
    case automatic = "Automatic"
    case light     = "Light"
    case dark      = "Dark"
    case solarizedLight = "Solarized Light"
    case solarizedDark  = "Solarized Dark"
    case dracula        = "Dracula"
    case nord           = "Nord"
    case platinum       = "Platinum"
    case norton         = "Norton"
    case amber          = "Amber CRT"
    case phosphorGreen  = "Phosphor Green"
    case blackAndWhite  = "Black and White"

    /// Migrates older stored values (`"Default"`) and unknown values to
    /// `.automatic`. Any new theme rawValue matches via the enum init.
    init(stored value: String?) {
        if let value, let resolved = AppThemeName(rawValue: value) {
            self = resolved
        } else {
            self = .automatic
        }
    }

    var displayName: String { rawValue }

    /// Whether the theme's chrome should render with a dark color
    /// scheme. `nil` → defer to the system (Automatic). Drives
    /// `.preferredColorScheme` on the editor scene so the nav bar,
    /// status bar, and other system surfaces tone-match the editor
    /// when the user picks a non-auto theme.
    var preferredColorScheme: UIUserInterfaceStyle? {
        switch self {
        case .automatic:
            return nil
        case .light, .solarizedLight, .platinum, .blackAndWhite:
            return .light
        case .dark, .solarizedDark, .dracula, .nord, .norton, .amber, .phosphorGreen:
            return .dark
        }
    }
}

/// Marker for themes that own their own editor body background.
/// The text view consults this to set its scroll-view background —
/// PaletteTheme returns the palette colour; built-in Light/Dark
/// default to `.systemBackground` (the protocol's default).
protocol EditorBackgroundProviding: EditorEngine.Theme {
    var editorBackgroundColor: UIColor { get }
}

extension EditorBackgroundProviding {
    var editorBackgroundColor: UIColor { .systemBackground }
}

/// Theme registry that produces `EditorEngine.Theme` instances.
enum AppTheme {

    static var displayNames: [String] { AppThemeName.allCases.map(\.displayName) }

    /// Resolves the theme name to a concrete `EditorEngine.Theme`. For
    /// `.automatic`, follows the supplied user-interface style (falls back
    /// to the current trait collection if not provided). Ported textamp
    /// themes resolve to a `PaletteTheme` with their own colour palette.
    static func current(
        _ name: AppThemeName,
        font: EditorFont = .systemMono,
        fontSize: CGFloat = 14,
        userInterfaceStyle: UIUserInterfaceStyle? = nil
    ) -> EditorEngine.Theme {
        let resolved: AppThemeName
        switch name {
        case .automatic:
            let style = userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
            resolved = (style == .dark) ? .dark : .light
        default:
            resolved = name
        }
        switch resolved {
        case .dark:           return DarkTheme(font: font, fontSize: fontSize)
        case .light:          return LightTheme(font: font, fontSize: fontSize)
        case .solarizedDark:  return PaletteTheme(palette: .solarizedDark,  font: font, fontSize: fontSize)
        case .solarizedLight: return PaletteTheme(palette: .solarizedLight, font: font, fontSize: fontSize)
        case .dracula:        return PaletteTheme(palette: .dracula,        font: font, fontSize: fontSize)
        case .nord:           return PaletteTheme(palette: .nord,           font: font, fontSize: fontSize)
        case .platinum:       return PaletteTheme(palette: .platinum,       font: font, fontSize: fontSize)
        case .norton:         return PaletteTheme(palette: .norton,         font: font, fontSize: fontSize)
        case .amber:          return PaletteTheme(palette: .amber,          font: font, fontSize: fontSize)
        case .phosphorGreen:  return PaletteTheme(palette: .phosphorGreen,  font: font, fontSize: fontSize)
        case .blackAndWhite:  return PaletteTheme(palette: .blackAndWhite,  font: font, fontSize: fontSize)
        case .automatic:      return LightTheme(font: font, fontSize: fontSize) // unreachable
        }
    }
}

/// Tree-sitter highlight names are dot-separated like `constant.builtin`.
/// We match by stripping trailing components until a known prefix is hit.
private func matchHighlight(_ name: String, _ map: [String: UIColor]) -> UIColor? {
    var components = name.split(separator: ".")
    while !components.isEmpty {
        let candidate = components.joined(separator: ".")
        if let color = map[candidate] { return color }
        components.removeLast()
    }
    return nil
}

/// Font traits per highlight tag. Mostly for markdown — italics for
/// `*emphasis*`, bold for `**strong**`, bold for headings — but applies
/// to any language whose highlight names match.
private func traits(forHighlight name: String) -> FontTraits {
    var components = name.split(separator: ".")
    while !components.isEmpty {
        let candidate = components.joined(separator: ".")
        switch candidate {
        case "text.emphasis", "markup.italic":
            return .italic
        case "text.strong", "markup.bold",
             "text.title",
             "markup.heading", "markup.heading.1", "markup.heading.2",
             "markup.heading.3", "markup.heading.4", "markup.heading.5",
             "markup.heading.6":
            return .bold
        default:
            components.removeLast()
        }
    }
    return []
}

private final class LightTheme: EditorEngine.Theme, EditorBackgroundProviding {
    let font: UIFont
    let lineNumberFont: UIFont

    init(font: EditorFont, fontSize: CGFloat) {
        self.font = font.uiFont(size: fontSize)
        // Line numbers stay monospaced for column alignment regardless of
        // the user's body font choice.
        self.lineNumberFont = .monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        traits(forHighlight: highlightName)
    }

    let textColor: UIColor = .label
    let gutterBackgroundColor: UIColor = .secondarySystemBackground
    let gutterHairlineColor: UIColor = .separator
    let lineNumberColor: UIColor = .tertiaryLabel
    let selectedLineBackgroundColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.08)
    let selectedLinesLineNumberColor: UIColor = .label
    let selectedLinesGutterBackgroundColor: UIColor = .secondarySystemBackground
    let invisibleCharactersColor: UIColor = .tertiaryLabel
    let pageGuideHairlineColor: UIColor = .separator
    let pageGuideBackgroundColor: UIColor = .secondarySystemBackground
    let markedTextBackgroundColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.2)

    private static let palette: [String: UIColor] = paletteLight

    func textColor(for highlightName: String) -> UIColor? {
        matchHighlight(highlightName, Self.palette)
    }
}

private let paletteLight: [String: UIColor] = [
    // Comments
    "comment":              .secondaryLabel,
    "comments":             .secondaryLabel,
    // Strings & characters
    "string":               .systemRed,
    "strings":              .systemRed,
    "characters":           .systemRed,
    // Numbers
    "number":               .systemPurple,
    "numbers":              .systemPurple,
    "values":               .systemPurple,
    // Keywords
    "keyword":              .systemBlue,
    "keywords":             .systemBlue,
    // Types
    "type":                 .systemTeal,
    "types":                .systemTeal,
    // Functions & commands
    "function":             .systemIndigo,
    "commands":             .systemIndigo,
    // Variables, properties, attributes, parameters, tags
    "variable":             .label,
    "variables":            .label,
    "property":             .systemBrown,
    "attribute":            .systemBrown,
    "attributes":           .systemBrown,
    "parameter":            .label,
    "tag":                  .systemTeal,
    // Operators & punctuation
    "operator":             .systemOrange,
    "punctuation":          .systemPink,
    "punctuation.special":  .systemPink,
    // Constants
    "constant":             .systemPurple,
    "boolean":              .systemPurple,
    "namespace":            .systemTeal,
    // Markdown / markup — explicit entries so headings, links, code spans
    // pop instead of resolving to .label (which is the default text color
    // and therefore invisible).
    "text.title":           .systemIndigo,
    "text.literal":         .systemRed,
    "text.uri":             .systemBlue,
    "text.reference":       .systemTeal,
    "text.emphasis":        .systemPurple,
    "text.strong":          .systemPurple,
    "markup.heading":       .systemIndigo,
    "markup.heading.1":     .systemIndigo,
    "markup.heading.2":     .systemIndigo,
    "markup.heading.3":     .systemIndigo,
    "markup.heading.4":     .systemIndigo,
    "markup.heading.5":     .systemIndigo,
    "markup.heading.6":     .systemIndigo,
    "markup.bold":          .systemPurple,
    "markup.italic":        .systemPurple,
    "markup.list":          .systemPink,
    "markup.link":          .systemBlue,
    "markup.link.label":    .systemTeal,
    "markup.link.url":      .systemBlue,
    "markup.raw":           .systemRed,
    "markup.raw.block":     .systemRed,
    "markup.quote":         .secondaryLabel
]

private final class DarkTheme: EditorEngine.Theme, EditorBackgroundProviding {
    /// Dark theme stays close to system dark mode but pulls the body
    /// surface a touch darker than `.systemBackground` so the gutter
    /// (defined here at white:0.10) reads as a visible step.
    var editorBackgroundColor: UIColor { UIColor(white: 0.06, alpha: 1) }

    let font: UIFont
    let lineNumberFont: UIFont

    init(font: EditorFont, fontSize: CGFloat) {
        self.font = font.uiFont(size: fontSize)
        self.lineNumberFont = .monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        traits(forHighlight: highlightName)
    }

    let textColor: UIColor = .white
    let gutterBackgroundColor: UIColor = UIColor(white: 0.10, alpha: 1)
    let gutterHairlineColor: UIColor = UIColor(white: 0.20, alpha: 1)
    let lineNumberColor: UIColor = UIColor(white: 0.45, alpha: 1)
    let selectedLineBackgroundColor: UIColor = UIColor(white: 1, alpha: 0.05)
    let selectedLinesLineNumberColor: UIColor = .white
    let selectedLinesGutterBackgroundColor: UIColor = UIColor(white: 0.13, alpha: 1)
    let invisibleCharactersColor: UIColor = UIColor(white: 0.4, alpha: 1)
    let pageGuideHairlineColor: UIColor = UIColor(white: 0.25, alpha: 1)
    let pageGuideBackgroundColor: UIColor = UIColor(white: 0.10, alpha: 1)
    let markedTextBackgroundColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.25)

    private static let palette: [String: UIColor] = paletteDark

    func textColor(for highlightName: String) -> UIColor? {
        matchHighlight(highlightName, Self.palette)
    }
}

private let paletteDark: [String: UIColor] = {
    let comment    = UIColor(white: 0.55, alpha: 1)
    let string     = UIColor(red: 1.0,  green: 0.55, blue: 0.55, alpha: 1)
    let number     = UIColor(red: 0.78, green: 0.62, blue: 1.0,  alpha: 1)
    let keyword    = UIColor(red: 0.58, green: 0.78, blue: 1.0,  alpha: 1)
    let type       = UIColor(red: 0.45, green: 0.85, blue: 0.78, alpha: 1)
    let function   = UIColor(red: 0.75, green: 0.75, blue: 1.0,  alpha: 1)
    let opColor    = UIColor(red: 1.0,  green: 0.7,  blue: 0.4,  alpha: 1)
    let property   = UIColor(red: 0.85, green: 0.75, blue: 0.55, alpha: 1)
    let heading    = UIColor(red: 0.85, green: 0.75, blue: 1.0,  alpha: 1)
    let link       = UIColor(red: 0.55, green: 0.80, blue: 1.0,  alpha: 1)
    return [
        "comment":              comment,
        "comments":             comment,
        "string":               string,
        "strings":              string,
        "characters":           string,
        "number":               number,
        "numbers":              number,
        "values":               number,
        "keyword":              keyword,
        "keywords":             keyword,
        "type":                 type,
        "types":                type,
        "function":             function,
        "commands":             function,
        "variable":             .white,
        "variables":            .white,
        "property":             property,
        "attribute":            property,
        "attributes":           property,
        "parameter":            .white,
        "tag":                  type,
        "operator":             opColor,
        "punctuation":          opColor,
        "punctuation.special":  opColor,
        "constant":             number,
        "boolean":              number,
        "namespace":            type,
        // Markdown / markup
        "text.title":           heading,
        "text.literal":         string,
        "text.uri":             link,
        "text.reference":       type,
        "text.emphasis":        number,
        "text.strong":          number,
        "markup.heading":       heading,
        "markup.heading.1":     heading,
        "markup.heading.2":     heading,
        "markup.heading.3":     heading,
        "markup.heading.4":     heading,
        "markup.heading.5":     heading,
        "markup.heading.6":     heading,
        "markup.bold":          number,
        "markup.italic":        number,
        "markup.list":          opColor,
        "markup.link":          link,
        "markup.link.label":    type,
        "markup.link.url":      link,
        "markup.raw":           string,
        "markup.raw.block":     string,
        "markup.quote":         comment
    ]
}()
