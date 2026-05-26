import UIKit
import EditorEngine
import GameController

/// Attaches caret-navigation buttons to a text view in the way that
/// works best per device + input combination:
///
///   * **iPad, software keyboard** — `inputAssistantItem` shortcut
///     bar at the top of the keyboard. System-managed positioning,
///     so the bar follows the keyboard around in Stage Manager and
///     never glitches into a floating-window's status bar.
///   * **iPad, hardware keyboard** — both groups cleared. iPadOS
///     would otherwise render a floating shortcut pill near the
///     bottom of the screen; the user already has a real keyboard,
///     so the pill is clutter.
///   * **iPhone** — `inputAccessoryView` (a slim `UIToolbar`). The
///     `inputAssistantItem` shortcut bar simply doesn't render on
///     iPhone, so navigation buttons would otherwise be unreachable.
///     iPhone is single-window so the inputAccessoryView layout
///     glitch that motivated the iPad switch can't happen there.
///
/// Listens for `GCKeyboardDidConnect` / `GCKeyboardDidDisconnect`
/// and refreshes the iPad bar live so the user gets buttons back
/// the moment they unplug the hardware keyboard.
@MainActor
enum KeyboardAccessoryBar {

    static func install(on textView: EditorEngine.TextView) {
        Self.refresh(textView)
        Self.attachHardwareKeyboardObserver(for: textView)
    }

    // MARK: - Routing

    /// Wire whichever attachment surface is appropriate for the
    /// current device + input combo. Idempotent — safe to call
    /// repeatedly (e.g. on every keyboard connect/disconnect).
    private static func refresh(_ textView: EditorEngine.TextView) {
        if DeviceIdiom.isPhone {
            // iPhone path: use inputAccessoryView. The assistant
            // bar's leading/trailing groups don't render on iPhone,
            // so buttons would be unreachable otherwise.
            if textView.inputAccessoryView == nil {
                textView.inputAccessoryView = Self.makeAccessoryToolbar(textView: textView)
            }
        } else {
            // iPad path: assistant item shortcut bar. Cleared when a
            // hardware keyboard is attached — no point showing a
            // floating pill above a physical kb.
            let assistant = textView.inputAssistantItem
            if GCKeyboard.coalesced != nil {
                assistant.leadingBarButtonGroups = []
                assistant.trailingBarButtonGroups = []
                return
            }
            let navItems = Self.makeNavigationBarItems(textView: textView)
            assistant.leadingBarButtonGroups = [
                UIBarButtonItemGroup(barButtonItems: navItems, representativeItem: nil)
            ]
            let defaults = UserDefaults.standard
            var trailing: [UIBarButtonItemGroup] = []
            if defaults.bool(forKey: AppPreferenceKey.keyboardShowsBracketPairs) {
                trailing.append(Self.makeBracketGroup(textView: textView))
            }
            assistant.trailingBarButtonGroups = trailing
        }
    }

    /// One observer per text view — registers for GameController's
    /// hardware-keyboard notifications and refreshes the assistant
    /// bar when the user plugs or unplugs. Token lifetime is bound
    /// to the text view via objc associated objects so it cleans
    /// up when the view goes away.
    private static func attachHardwareKeyboardObserver(for textView: EditorEngine.TextView) {
        let holder = KeyboardObserverHolder { [weak textView] in
            guard let textView else { return }
            Self.refresh(textView)
        }
        objc_setAssociatedObject(textView, &observerKey, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - iPhone toolbar

    private static func makeAccessoryToolbar(textView: EditorEngine.TextView) -> UIView {
        let bar = UIToolbar()
        bar.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        bar.autoresizingMask = [.flexibleWidth]
        bar.sizeToFit()
        let flex = UIBarButtonItem.flexibleSpace()
        var items: [UIBarButtonItem] = []
        let nav = Self.makeNavigationBarItems(textView: textView)
        for (idx, item) in nav.enumerated() {
            items.append(item)
            if idx < nav.count - 1 { items.append(flex) }
        }
        bar.items = items
        return bar
    }

    // MARK: - Navigation items

    /// Six caret-navigation buttons in the user's preferred order:
    /// Esc, Tab, End of Line, Begin of Line, End of Document, Begin
    /// of Document. Glyph scheme: Tab uses the standard
    /// `arrow.right.to.line.compact` (compact bar at the right);
    /// line navigation uses plain horizontal arrows (← →) so they
    /// read as "move along this line"; document navigation uses
    /// `arrow.up.to.line` / `arrow.down.to.line` (vertical arrows
    /// with a terminator bar) so they read as "go to the very
    /// top/bottom of the document". No two buttons share a glyph.
    private static func makeNavigationBarItems(textView: EditorEngine.TextView) -> [UIBarButtonItem] {
        [
            item(title: "Esc") { _ in
                // Visual finger-rest column; no app-level action.
            },
            item(symbol: "arrow.right.to.line.compact", accessibility: "Tab") { [weak textView] _ in
                guard let textView else { return }
                textView.replace(textView.selectedRange, withText: "\t")
            },
            item(symbol: "arrow.right",
                 accessibility: "Move to End of Line") { [weak textView] _ in
                CaretMover.moveToLineEnd(in: textView)
            },
            item(symbol: "arrow.left",
                 accessibility: "Move to Start of Line") { [weak textView] _ in
                CaretMover.moveToLineStart(in: textView)
            },
            item(symbol: "arrow.down.to.line",
                 accessibility: "Move to End of Document") { [weak textView] _ in
                CaretMover.moveToDocumentEnd(in: textView)
            },
            item(symbol: "arrow.up.to.line",
                 accessibility: "Move to Start of Document") { [weak textView] _ in
                CaretMover.moveToDocumentStart(in: textView)
            }
        ]
    }

    // MARK: - Optional groups (iPad-only)

    private static func makeBracketGroup(textView: EditorEngine.TextView) -> UIBarButtonItemGroup {
        let wrap: (String) -> Void = { [weak textView] pair in
            guard let textView else { return }
            textView.replace(textView.selectedRange, withText: pair)
            CaretMover.move(in: textView, by: -1)
        }
        let items: [UIBarButtonItem] = [
            item(title: "()") { _ in wrap("()") },
            item(title: "[]") { _ in wrap("[]") },
            item(title: "{}") { _ in wrap("{}") },
            item(title: "<>") { _ in wrap("<>") },
            item(title: "\"\"") { _ in wrap("\"\"") },
            item(title: "''") { _ in wrap("''") }
        ]
        let representative = item(title: "()…") { _ in wrap("()") }
        return UIBarButtonItemGroup(barButtonItems: items, representativeItem: representative)
    }

    // MARK: - Item factory

    private static func item(symbol: String,
                             accessibility: String,
                             handler: @escaping (UIAction) -> Void) -> UIBarButtonItem {
        let image = UIImage(systemName: symbol)
        let action = UIAction(title: accessibility, image: image, handler: handler)
        let bar = UIBarButtonItem(primaryAction: action)
        bar.accessibilityLabel = accessibility
        return bar
    }

    private static func item(title: String,
                             handler: @escaping (UIAction) -> Void) -> UIBarButtonItem {
        let action = UIAction(title: title, handler: handler)
        let bar = UIBarButtonItem(primaryAction: action)
        bar.accessibilityLabel = title
        return bar
    }
}

private nonisolated(unsafe) var observerKey: UInt8 = 0

/// Holds the hardware-keyboard-connect / disconnect observer tokens
/// alongside the text view they belong to. Non-actor-isolated so its
/// `deinit` can clean up notifications without hopping to the main
/// actor. Bound to the text view via objc associated objects so its
/// lifetime tracks the view.
private final class KeyboardObserverHolder: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    init(_ refresh: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        let connect = center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { _ in Task { @MainActor in refresh() } }
        let disconnect = center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { _ in Task { @MainActor in refresh() } }
        tokens = [connect, disconnect]
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

// MARK: - Caret movement

@MainActor
private enum CaretMover {
    static func move(in textView: EditorEngine.TextView?, by offset: Int) {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        let cursor = textView.selectedRange.location + offset
        let clamped = max(0, min(length, cursor))
        textView.selectedRange = NSRange(location: clamped, length: 0)
    }

    static func moveToLineStart(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let line = nsText.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        textView.selectedRange = NSRange(location: line.location, length: 0)
    }

    static func moveToLineEnd(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let line = nsText.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        // Park before the trailing newline if one exists.
        var endOfLine = line.location + line.length
        if endOfLine > line.location {
            let lastChar = nsText.substring(with: NSRange(location: endOfLine - 1, length: 1))
            if lastChar == "\n" || lastChar == "\r" { endOfLine -= 1 }
        }
        textView.selectedRange = NSRange(location: endOfLine, length: 0)
    }

    static func moveToDocumentStart(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        textView.selectedRange = NSRange(location: 0, length: 0)
    }

    static func moveToDocumentEnd(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        textView.selectedRange = NSRange(location: length, length: 0)
    }
}
