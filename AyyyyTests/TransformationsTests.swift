import XCTest
@testable import Ayyyy

final class TransformationsTests: XCTestCase {

    // MARK: - Case

    func test_titleCase_capitalizesMajorWordsAndLowercasesShortFunctionWords() {
        // "over" is in the lowercase-when-internal set; "jumps" is not.
        XCTAssertEqual(
            Transformations.titleCase("the quick brown fox jumps over the lazy dog"),
            "The Quick Brown Fox Jumps over the Lazy Dog"
        )
    }

    func test_titleCase_alwaysCapitalizesFirstAndLastWords() {
        XCTAssertEqual(
            Transformations.titleCase("a tale of two cities"),
            "A Tale of Two Cities"
        )
        XCTAssertEqual(
            Transformations.titleCase("a"),
            "A"
        )
    }

    func test_snakeCase_splitsCamelAndSeparators() {
        XCTAssertEqual(Transformations.snakeCase("helloWorld"),      "hello_world")
        XCTAssertEqual(Transformations.snakeCase("hello-world"),     "hello_world")
        XCTAssertEqual(Transformations.snakeCase("Hello World"),     "hello_world")
        // Camel splitter inserts a boundary only at lower→upper /
        // digit→upper. Consecutive uppercase letters stay glued —
        // intentional, since the alternative mangles initialisms.
        XCTAssertEqual(Transformations.snakeCase("MyHTTPServer"),    "my_httpserver")
    }

    func test_kebabCase_emitsLowercaseWithHyphens() {
        XCTAssertEqual(Transformations.kebabCase("MyAwesomeThing"),  "my-awesome-thing")
        XCTAssertEqual(Transformations.kebabCase("foo bar baz"),     "foo-bar-baz")
    }

    func test_camelCase_lowercasesFirstWordCapitalizesRest() {
        XCTAssertEqual(Transformations.camelCase("my awesome thing"), "myAwesomeThing")
        XCTAssertEqual(Transformations.camelCase("foo-bar-baz"),      "fooBarBaz")
    }

    func test_pascalCase_capitalizesEveryWord() {
        XCTAssertEqual(Transformations.pascalCase("my awesome thing"), "MyAwesomeThing")
    }

    // MARK: - Line ops

    func test_addLineNumbers_padsRightAlignedAndPreservesNewlines() {
        let input = "alpha\nbeta\ngamma\n"
        let expected = "1. alpha\n2. beta\n3. gamma\n"
        XCTAssertEqual(Transformations.addLineNumbers(input), expected)
    }

    func test_removeLineNumbers_stripsParenAndPeriodPrefixes() {
        XCTAssertEqual(
            Transformations.removeLineNumbers("1. alpha\n  2. beta\n3) gamma\nplain\n"),
            "alpha\nbeta\ngamma\nplain\n"
        )
    }

    func test_removeBlankLines_dropsWhitespaceOnlyLines() {
        XCTAssertEqual(
            Transformations.removeBlankLines("a\n\n  \nb\n\t\n"),
            "a\nb\n"
        )
    }

    func test_prefixLines_appliesToEveryLineAndPreservesLF() {
        XCTAssertEqual(
            Transformations.prefixLines("a\nb\nc", with: "> "),
            "> a\n> b\n> c"
        )
    }

    func test_prefixLines_appliesToEveryLineAndPreservesCRLF() {
        let out = Transformations.prefixLines("a\r\nb\r\nc", with: "> ")
        // Body bytes are preserved per-line; the CRLF round-trips through
        // splitKeepingNewlines as a single grapheme cluster so the assert
        // matches by string comparison rather than per-codepoint.
        XCTAssertEqual(out, "> a\r\n> b\r\n> c")
    }

    func test_increaseAndDecreaseQuoteLevel_areInverseForSimpleQuotes() {
        let quoted = Transformations.increaseQuoteLevel("hello\nworld")
        XCTAssertEqual(quoted, "> hello\n> world")
        XCTAssertEqual(Transformations.decreaseQuoteLevel(quoted), "hello\nworld")
    }

    // MARK: - Whitespace / encoding

    func test_tabsToSpaces_usesGivenWidth() {
        XCTAssertEqual(Transformations.tabsToSpaces("\ta\tb", tabWidth: 2), "  a  b")
    }

    func test_spacesToTabs_leadingIndentOnlyPreservesBodySpaces() {
        XCTAssertEqual(
            Transformations.spacesToTabs("    hello world", tabWidth: 4),
            "\thello world"
        )
        XCTAssertEqual(
            Transformations.spacesToTabs("      hello", tabWidth: 4),
            "\t  hello"
        )
    }

    func test_normalizeLineEndings_collapsesMixedEndingsToTarget() {
        XCTAssertEqual(
            Transformations.normalizeLineEndings("a\r\nb\rc\n", to: "\n"),
            "a\nb\nc\n"
        )
    }

    func test_zapGremlins_stripsAsciiControlAndZeroWidthByDefault() {
        let input = "hello\u{0001}\u{200B}world\u{FEFF}!"
        XCTAssertEqual(Transformations.zapGremlins(input), "helloworld!")
    }

    func test_stripDiacritics_keepsBaseCharacters() {
        XCTAssertEqual(Transformations.stripDiacritics("café naïve résumé"), "cafe naive resume")
    }

    func test_convertToASCII_transliteratesLatin() {
        XCTAssertEqual(Transformations.convertToASCII("Crème brûlée"), "Creme brulee")
    }

    func test_interpretEscapeSequences_handlesCommonEscapesAndHex() {
        XCTAssertEqual(Transformations.interpretEscapeSequences(#"a\nb\tc\x41é"#), "a\nb\tcAé")
    }

    func test_escapeSpecialCharacters_isInverseForCommonCases() {
        XCTAssertEqual(Transformations.escapeSpecialCharacters("a\nb\tc\\"), #"a\nb\tc\\"#)
    }

    func test_educateAndStraightenQuotes_roundTripToSafeForm() {
        let curly = Transformations.educateQuotes("he said \"hi\" and 'bye'")
        XCTAssertTrue(curly.contains("\u{201C}"))
        XCTAssertTrue(curly.contains("\u{201D}"))
        XCTAssertEqual(Transformations.straightenQuotes(curly), "he said \"hi\" and 'bye'")
    }

    // MARK: - Paragraph helpers

    func test_splitParagraphs_dropsBlankDelimitersKeepsInternalLineBreaks() {
        let input = """
        first paragraph
        still first

        second paragraph

        third
        """
        XCTAssertEqual(
            Transformations.splitParagraphs(input),
            ["first paragraph\nstill first", "second paragraph", "third"]
        )
    }

    // MARK: - Word wrap

    func test_wordWrap_breaksAtColumnBoundary() {
        XCTAssertEqual(
            Transformations.wordWrap("the quick brown fox", to: 10, separator: "\n"),
            "the quick\nbrown fox"
        )
    }

    func test_wordWrap_keepsOverlongWordsAlone() {
        XCTAssertEqual(
            Transformations.wordWrap("supercalifragilistic and tiny", to: 8, separator: "\n"),
            "supercalifragilistic\nand tiny"
        )
    }
}
