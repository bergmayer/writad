import UIKit
import EditorEngine

/// Colour palette adapted from textamp's GUI themes. Each palette
/// drives a `PaletteTheme` instance — every editor surface (background,
/// gutter, selection, syntax slots) is derived from this small set
/// rather than hand-coded per theme so the look stays consistent
/// across the textamp-ported family.
struct ColorPalette {
    /// Editor body background.
    let background: UIColor
    /// Primary body text colour.
    let foreground: UIColor
    /// Muted text — used for comments, gutter line numbers, invisibles.
    let muted: UIColor
    /// Accent the theme treats as "active selection" / cursor highlight.
    let accent: UIColor

    // Syntax slots — each themed palette below assigns these. Monochrome
    // themes (Amber, Phosphor, B&W) collapse all syntax slots to
    // `foreground` so the look stays uniform.
    let comment:     UIColor
    let string:      UIColor
    let number:      UIColor
    let keyword:     UIColor
    let type:        UIColor
    let function:    UIColor
    let property:    UIColor
    let opColor:     UIColor
    let heading:     UIColor
    let link:        UIColor

    /// Whether the palette is a light theme — drives selection alpha
    /// and a couple of gutter-tint decisions.
    let isLight: Bool
}

// MARK: - Palettes

extension ColorPalette {

    /// Standard palette factory: a single accent applied across every
    /// syntax slot. Use for monochrome themes (Amber, Phosphor, B&W)
    /// where syntax distinction isn't expected — the look mirrors a
    /// vintage terminal where everything is the same colour.
    private static func monochrome(background: UIColor, foreground: UIColor, isLight: Bool) -> ColorPalette {
        ColorPalette(
            background: background,
            foreground: foreground,
            muted:      foreground.withAlphaComponent(0.55),
            accent:     foreground,
            comment:    foreground.withAlphaComponent(0.55),
            string:     foreground,
            number:     foreground,
            keyword:    foreground,
            type:       foreground,
            function:   foreground,
            property:   foreground,
            opColor:    foreground,
            heading:    foreground,
            link:       foreground,
            isLight:    isLight
        )
    }

    /// Solarized — canonical Ethan Schoonover palette.
    /// Reference: https://ethanschoonover.com/solarized/
    static let solarizedDark = ColorPalette(
        background: rgb(0x00, 0x2b, 0x36),  // base03
        foreground: rgb(0x83, 0x94, 0x96),  // base0
        muted:      rgb(0x58, 0x6e, 0x75),  // base01
        accent:     rgb(0x26, 0x8b, 0xd2),  // blue
        comment:    rgb(0x58, 0x6e, 0x75),  // base01
        string:     rgb(0x2a, 0xa1, 0x98),  // cyan
        number:     rgb(0xd3, 0x36, 0x82),  // magenta
        keyword:    rgb(0x85, 0x99, 0x00),  // green
        type:       rgb(0xb5, 0x89, 0x00),  // yellow
        function:   rgb(0x26, 0x8b, 0xd2),  // blue
        property:   rgb(0xcb, 0x4b, 0x16),  // orange
        opColor:    rgb(0x6c, 0x71, 0xc4),  // violet
        heading:    rgb(0xb5, 0x89, 0x00),  // yellow
        link:       rgb(0x26, 0x8b, 0xd2),  // blue
        isLight:    false
    )

    static let solarizedLight = ColorPalette(
        background: rgb(0xfd, 0xf6, 0xe3),  // base3
        foreground: rgb(0x65, 0x7b, 0x83),  // base00
        muted:      rgb(0x93, 0xa1, 0xa1),  // base1
        accent:     rgb(0x26, 0x8b, 0xd2),
        comment:    rgb(0x93, 0xa1, 0xa1),
        string:     rgb(0x2a, 0xa1, 0x98),
        number:     rgb(0xd3, 0x36, 0x82),
        keyword:    rgb(0x85, 0x99, 0x00),
        type:       rgb(0xb5, 0x89, 0x00),
        function:   rgb(0x26, 0x8b, 0xd2),
        property:   rgb(0xcb, 0x4b, 0x16),
        opColor:    rgb(0x6c, 0x71, 0xc4),
        heading:    rgb(0xb5, 0x89, 0x00),
        link:       rgb(0x26, 0x8b, 0xd2),
        isLight:    true
    )

    /// Dracula — https://draculatheme.com/contribute
    static let dracula = ColorPalette(
        background: rgb(0x28, 0x2a, 0x36),
        foreground: rgb(0xf8, 0xf8, 0xf2),
        muted:      rgb(0x62, 0x72, 0xa4),
        accent:     rgb(0xbd, 0x93, 0xf9),  // purple
        comment:    rgb(0x62, 0x72, 0xa4),
        string:     rgb(0xf1, 0xfa, 0x8c),  // yellow
        number:     rgb(0xbd, 0x93, 0xf9),  // purple
        keyword:    rgb(0xff, 0x79, 0xc6),  // pink
        type:       rgb(0x8b, 0xe9, 0xfd),  // cyan
        function:   rgb(0x50, 0xfa, 0x7b),  // green
        property:   rgb(0xff, 0xb8, 0x6c),  // orange
        opColor:    rgb(0xff, 0x79, 0xc6),  // pink
        heading:    rgb(0xbd, 0x93, 0xf9),  // purple
        link:       rgb(0x8b, 0xe9, 0xfd),  // cyan
        isLight:    false
    )

    /// Nord — https://www.nordtheme.com/docs/colors-and-palettes
    static let nord = ColorPalette(
        background: rgb(0x2e, 0x34, 0x40),  // nord0
        foreground: rgb(0xd8, 0xde, 0xe9),  // nord4
        muted:      rgb(0x4c, 0x56, 0x6a),  // nord3
        accent:     rgb(0x88, 0xc0, 0xd0),  // nord8 frost blue
        comment:    rgb(0x4c, 0x56, 0x6a),  // nord3
        string:     rgb(0xa3, 0xbe, 0x8c),  // nord14 green
        number:     rgb(0xb4, 0x8e, 0xad),  // nord15 purple
        keyword:    rgb(0x81, 0xa1, 0xc1),  // nord9
        type:       rgb(0x8f, 0xbc, 0xbb),  // nord7
        function:   rgb(0x88, 0xc0, 0xd0),  // nord8
        property:   rgb(0xd0, 0x87, 0x70),  // nord12 orange
        opColor:    rgb(0xeb, 0xcb, 0x8b),  // nord13 yellow
        heading:    rgb(0x88, 0xc0, 0xd0),
        link:       rgb(0x81, 0xa1, 0xc1),
        isLight:    false
    )

    /// Mac OS 9 "Platinum" — light gray window chrome, blue selection.
    static let platinum = ColorPalette(
        background: rgb(0xdd, 0xdd, 0xdd),
        foreground: rgb(0x00, 0x00, 0x00),
        muted:      rgb(0x55, 0x55, 0x55),
        accent:     rgb(0x3b, 0x78, 0xff),
        comment:    rgb(0x55, 0x55, 0x55),
        string:     rgb(0xcc, 0x00, 0x00),
        number:     rgb(0x80, 0x00, 0x80),
        keyword:    rgb(0x00, 0x00, 0xcc),
        type:       rgb(0x00, 0x66, 0x66),
        function:   rgb(0x00, 0x00, 0x99),
        property:   rgb(0x99, 0x66, 0x00),
        opColor:    rgb(0x99, 0x33, 0x00),
        heading:    rgb(0x00, 0x00, 0x99),
        link:       rgb(0x3b, 0x78, 0xff),
        isLight:    true
    )

    /// Norton Commander DOS — bright blue background, cyan / yellow /
    /// white accents.
    static let norton = ColorPalette(
        background: rgb(0x00, 0x00, 0xaa),
        foreground: rgb(0xff, 0xff, 0xff),
        muted:      rgb(0xaa, 0xaa, 0xff),
        accent:     rgb(0x55, 0xff, 0xff),  // bright cyan
        comment:    rgb(0xaa, 0xaa, 0xff),
        string:     rgb(0xff, 0xff, 0x55),  // bright yellow
        number:     rgb(0x55, 0xff, 0xff),
        keyword:    rgb(0xff, 0xff, 0x55),
        type:       rgb(0x55, 0xff, 0xff),
        function:   rgb(0xff, 0xff, 0xff),
        property:   rgb(0x55, 0xff, 0x55),
        opColor:    rgb(0xff, 0x55, 0x55),
        heading:    rgb(0xff, 0xff, 0x55),
        link:       rgb(0x55, 0xff, 0xff),
        isLight:    false
    )

    /// Vintage amber CRT (IBM 3270 / DEC monochrome look).
    static let amber = monochrome(
        background: rgb(0x0f, 0x08, 0x00),
        foreground: rgb(0xff, 0xb0, 0x00),
        isLight:    false
    )

    /// Vintage green CRT (Apple ][ / DEC VT terminal look).
    static let phosphorGreen = monochrome(
        background: rgb(0x00, 0x0c, 0x00),
        foreground: rgb(0x50, 0xff, 0x64),
        isLight:    false
    )

    /// Pure black on pure white — for high-contrast reading and
    /// e-ink-style preview layouts.
    static let blackAndWhite = monochrome(
        background: rgb(0xff, 0xff, 0xff),
        foreground: rgb(0x00, 0x00, 0x00),
        isLight:    true
    )
}

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
    UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// MARK: - Theme

/// Drives the editor surfaces from a `ColorPalette`. Saves writing a
/// dedicated UIColor-per-property class for every ported textamp theme.
/// Highlight resolution still routes through tree-sitter's
/// `category.subcategory` names like `keyword.builtin` — same matcher
/// the built-in Light/Dark themes use.
final class PaletteTheme: EditorEngine.Theme, EditorBackgroundProviding {

    /// Editor body background — the textamp palette's `background`.
    /// Drives the text view's scroll-view colour so picking Dracula
    /// actually shows Dracula's surface instead of `.systemBackground`.
    var editorBackgroundColor: UIColor { palette.background }


    let font: UIFont
    let lineNumberFont: UIFont
    let palette: ColorPalette
    private let syntaxMap: [String: UIColor]
    private let italicFontTraits: FontTraits = .italic
    private let boldFontTraits: FontTraits = .bold

    init(palette: ColorPalette, font: EditorFont, fontSize: CGFloat) {
        self.palette = palette
        self.font = font.uiFont(size: fontSize)
        self.lineNumberFont = .monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)
        self.syntaxMap = Self.buildMap(palette)
    }

    var textColor: UIColor { palette.foreground }
    var gutterBackgroundColor: UIColor { tintedGutter(of: palette) }
    var gutterHairlineColor: UIColor { palette.muted.withAlphaComponent(0.35) }
    var lineNumberColor: UIColor { palette.muted }
    var selectedLineBackgroundColor: UIColor {
        palette.accent.withAlphaComponent(palette.isLight ? 0.10 : 0.18)
    }
    var selectedLinesLineNumberColor: UIColor { palette.foreground }
    var selectedLinesGutterBackgroundColor: UIColor { tintedGutter(of: palette) }
    var invisibleCharactersColor: UIColor { palette.muted }
    var pageGuideHairlineColor: UIColor { palette.muted.withAlphaComponent(0.35) }
    var pageGuideBackgroundColor: UIColor { tintedGutter(of: palette) }
    var markedTextBackgroundColor: UIColor {
        palette.accent.withAlphaComponent(palette.isLight ? 0.20 : 0.30)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        traits(forHighlight: highlightName)
    }

    func textColor(for highlightName: String) -> UIColor? {
        matchHighlight(highlightName, syntaxMap)
    }

    /// Gutter background is the body background nudged by ~6 % toward
    /// the foreground — same trick as DarkTheme / LightTheme.
    private func tintedGutter(of palette: ColorPalette) -> UIColor {
        blend(palette.background, with: palette.foreground, ratio: 0.06)
    }

    private func blend(_ a: UIColor, with b: UIColor, ratio: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let t = max(0, min(1, ratio))
        return UIColor(
            red:   ar + (br - ar) * t,
            green: ag + (bg - ag) * t,
            blue:  ab + (bb - ab) * t,
            alpha: aa + (ba - aa) * t
        )
    }

    /// Build the full highlight-name → UIColor map from a palette.
    /// Keys mirror `paletteLight` / `paletteDark` in AppTheme.swift so
    /// the matcher behaves identically across the built-in and ported
    /// theme families.
    private static func buildMap(_ p: ColorPalette) -> [String: UIColor] {
        [
            // Comments
            "comment":              p.comment,
            "comments":             p.comment,
            // Strings & characters
            "string":               p.string,
            "strings":              p.string,
            "characters":           p.string,
            // Numbers
            "number":               p.number,
            "numbers":              p.number,
            "values":               p.number,
            // Keywords
            "keyword":              p.keyword,
            "keywords":             p.keyword,
            // Types
            "type":                 p.type,
            "types":                p.type,
            // Functions & commands
            "function":             p.function,
            "commands":             p.function,
            // Variables, properties, attributes, parameters, tags
            "variable":             p.foreground,
            "variables":            p.foreground,
            "property":             p.property,
            "attribute":            p.property,
            "attributes":           p.property,
            "parameter":            p.foreground,
            "tag":                  p.type,
            // Operators & punctuation
            "operator":             p.opColor,
            "punctuation":          p.opColor,
            "punctuation.special":  p.opColor,
            // Constants
            "constant":             p.number,
            "boolean":              p.number,
            "namespace":            p.type,
            // Markdown / markup
            "text.title":           p.heading,
            "text.literal":         p.string,
            "text.uri":             p.link,
            "text.reference":       p.type,
            "text.emphasis":        p.number,
            "text.strong":          p.number,
            "markup.heading":       p.heading,
            "markup.heading.1":     p.heading,
            "markup.heading.2":     p.heading,
            "markup.heading.3":     p.heading,
            "markup.heading.4":     p.heading,
            "markup.heading.5":     p.heading,
            "markup.heading.6":     p.heading,
            "markup.bold":          p.number,
            "markup.italic":        p.number,
            "markup.list":          p.opColor,
            "markup.link":          p.link,
            "markup.link.label":    p.type,
            "markup.link.url":      p.link,
            "markup.raw":           p.string,
            "markup.raw.block":     p.string,
            "markup.quote":         p.comment,
        ]
    }
}

// MARK: - Private helpers shared with the built-in themes

private func matchHighlight(_ name: String, _ map: [String: UIColor]) -> UIColor? {
    var components = name.split(separator: ".")
    while !components.isEmpty {
        let candidate = components.joined(separator: ".")
        if let color = map[candidate] { return color }
        components.removeLast()
    }
    return nil
}

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
