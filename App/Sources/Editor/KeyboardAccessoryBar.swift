import UIKit
import EditorEngine
import GameController

/// Two-row keyboard accessory: a collapsible drawer above a fixed
/// main row, sized so it sits flush above the iOS soft keyboard.
///
///   * **iPhone (soft keyboard)** — full two-row accessory view.
///   * **iPad (soft keyboard)** — uses the system `inputAssistantItem`
///     shortcut bar instead, because a free-floating
///     `inputAccessoryView` on iPad bleeds into our status-bar overlay
///     in Stage Manager / Slide Over windows.
///   * **iPad (hardware keyboard)** — both surfaces cleared.
///
/// Hardware-keyboard connect/disconnect is observed via
/// `GameController` so the bar reappears the moment the user unplugs.
@MainActor
enum KeyboardAccessoryBar {

    static func install(on textView: EditorEngine.TextView) {
        Self.refresh(textView)
        Self.attachHardwareKeyboardObserver(for: textView)
    }

    private static func refresh(_ textView: EditorEngine.TextView) {
        if DeviceIdiom.isPhone {
            if !(textView.inputAccessoryView is EditorAccessoryView) {
                textView.inputAccessoryView = EditorAccessoryView(host: textView)
            }
        } else {
            // iPad path — preserve the existing inputAssistantItem
            // approach until the Stage-Manager bleed-through is fixed.
            let assistant = textView.inputAssistantItem
            if GCKeyboard.coalesced != nil {
                assistant.leadingBarButtonGroups = []
                assistant.trailingBarButtonGroups = []
                return
            }
            let navItems = Self.makeIPadNavigationItems(textView: textView)
            assistant.leadingBarButtonGroups = [
                UIBarButtonItemGroup(barButtonItems: navItems, representativeItem: nil)
            ]
            assistant.trailingBarButtonGroups = []
        }
    }

    private static func attachHardwareKeyboardObserver(for textView: EditorEngine.TextView) {
        let holder = KeyboardObserverHolder { [weak textView] in
            guard let textView else { return }
            Self.refresh(textView)
        }
        objc_setAssociatedObject(textView, &observerKey, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - iPad navigation items

    private static func makeIPadNavigationItems(textView: EditorEngine.TextView) -> [UIBarButtonItem] {
        [
            barItem(title: "Esc") { _ in },
            barItem(symbol: "arrow.right.to.line.compact", accessibility: "Tab") { [weak textView] _ in
                guard let textView else { return }
                textView.replace(textView.selectedRange, withText: "\t")
            },
            barItem(symbol: "arrow.right",
                    accessibility: "Move to End of Line") { [weak textView] _ in
                CaretMover.moveToLineEnd(in: textView)
            },
            barItem(symbol: "arrow.left",
                    accessibility: "Move to Start of Line") { [weak textView] _ in
                CaretMover.moveToLineStart(in: textView)
            },
            barItem(symbol: "arrow.down.to.line",
                    accessibility: "Move to End of Document") { [weak textView] _ in
                CaretMover.moveToDocumentEnd(in: textView)
            },
            barItem(symbol: "arrow.up.to.line",
                    accessibility: "Move to Start of Document") { [weak textView] _ in
                CaretMover.moveToDocumentStart(in: textView)
            }
        ]
    }

    private static func barItem(symbol: String,
                                accessibility: String,
                                handler: @escaping (UIAction) -> Void) -> UIBarButtonItem {
        let image = UIImage(systemName: symbol)
        let action = UIAction(title: accessibility, image: image, handler: handler)
        let bar = UIBarButtonItem(primaryAction: action)
        bar.accessibilityLabel = accessibility
        return bar
    }

    private static func barItem(title: String,
                                handler: @escaping (UIAction) -> Void) -> UIBarButtonItem {
        let action = UIAction(title: title, handler: handler)
        let bar = UIBarButtonItem(primaryAction: action)
        bar.accessibilityLabel = title
        return bar
    }
}

private nonisolated(unsafe) var observerKey: UInt8 = 0

/// Holds the GameController notification tokens; released alongside
/// the text view it's bound to via objc associated objects.
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

// MARK: - Caret movement helpers

@MainActor
enum CaretMover {
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

    static func moveCursor(in textView: EditorEngine.TextView?, byLines lineDelta: Int) {
        guard let textView, lineDelta != 0 else { return }
        for _ in 0..<abs(lineDelta) {
            moveOneLine(in: textView, downward: lineDelta > 0)
        }
    }

    private static func moveOneLine(in textView: EditorEngine.TextView, downward: Bool) {
        let nsText = textView.text as NSString
        let cursor = textView.selectedRange.location
        let currentLine = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let column = cursor - currentLine.location

        if downward {
            let nextStart = currentLine.location + currentLine.length
            guard nextStart < nsText.length else {
                textView.selectedRange = NSRange(location: nsText.length, length: 0)
                return
            }
            let nextLine = nsText.lineRange(for: NSRange(location: nextStart, length: 0))
            let nextLen = max(0, nextLine.length - 1)
            let target = nextLine.location + min(column, nextLen)
            textView.selectedRange = NSRange(location: min(target, nsText.length), length: 0)
        } else {
            guard currentLine.location > 0 else {
                textView.selectedRange = NSRange(location: 0, length: 0)
                return
            }
            let prevLine = nsText.lineRange(for: NSRange(location: currentLine.location - 1, length: 0))
            let prevLen = max(0, prevLine.length - 1)
            let target = prevLine.location + min(column, prevLen)
            textView.selectedRange = NSRange(location: target, length: 0)
        }
    }

    /// Word-boundary nav: moves the cursor over whitespace then over
    /// the next word, in the requested direction. Matches the macOS
    /// ⌥← / ⌥→ convention.
    static func moveWord(in textView: EditorEngine.TextView?, forward: Bool) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let length = nsText.length
        guard length > 0 else { return }
        var idx = textView.selectedRange.location
        let isWord: (unichar) -> Bool = { ch in
            (ch >= 0x30 && ch <= 0x39) ||
            (ch >= 0x41 && ch <= 0x5A) ||
            (ch >= 0x61 && ch <= 0x7A) ||
            ch == 0x5F
        }
        if forward {
            while idx < length, !isWord(nsText.character(at: idx)) { idx += 1 }
            while idx < length,  isWord(nsText.character(at: idx)) { idx += 1 }
        } else {
            while idx > 0, !isWord(nsText.character(at: idx - 1)) { idx -= 1 }
            while idx > 0,  isWord(nsText.character(at: idx - 1)) { idx -= 1 }
        }
        textView.selectedRange = NSRange(location: idx, length: 0)
    }
}

// MARK: - Armed modifier dispatch

@MainActor
enum AccessoryKeyboard {

    /// Called from the engine's `shouldChangeTextIn` when one of the
    /// accessory bar's sticky modifiers is armed. Returns `true`
    /// when the action consumed the keypress (engine should NOT
    /// insert the character), `false` to pass through.
    ///
    /// Priority is ⌘ → ⌃ → ⌥ → ⇧ so a ⌘⇧S still routes through the
    /// command path, with the shift bit folded into the lookup.
    static func handleArmedKey(_ text: String, state: EditorState) -> Bool {
        guard let textView = state.textView else { return false }
        let lower = text.lowercased()
        let engine = textView as? EditorEngine.TextView
        let shifted = state.armedAccessoryShift

        if state.armedAccessoryCommand {
            return handleCommandKey(lower, shifted: shifted, engine: engine)
        }
        if state.armedAccessoryControl {
            return handleControlKey(lower, engine: engine)
        }
        if state.armedAccessoryOption {
            return handleOptionKey(lower, engine: engine)
        }
        if shifted {
            // Bare Shift just confirms one uppercased insert — iOS
            // already capitalizes via its own shift, so this is
            // mostly a no-op safety net.
            textView.replace(textView.selectedRange, withText: text.uppercased())
            return true
        }
        return false
    }

    private static func handleCommandKey(
        _ lower: String,
        shifted: Bool,
        engine: EditorEngine.TextView?
    ) -> Bool {
        switch lower {
        case "s":
            if shifted {
                AppStateBus.shared.pickers.pending = .saveAs
            } else {
                AppStateBus.shared.editing.saveCurrentDocument?()
            }
            return true
        case "z":
            shifted ? CommandActions.redo() : CommandActions.undo()
            return true
        case "c":
            copySelection(from: engine)
            return true
        case "x":
            copySelection(from: engine, clear: true)
            return true
        case "v":
            pasteAtSelection(into: engine)
            return true
        case "a":
            engine?.selectAll()
            return true
        case "f":
            if shifted {
                CommandActions.presentMultiFileSearch()
            } else {
                CommandActions.seedFindFromSelection()
                CommandActions.presentSheet(.findReplace)
            }
            return true
        case "g":
            shifted ? CommandActions.findPrevious() : CommandActions.findNext()
            return true
        case "l":
            CommandActions.presentSheet(.goToLine)
            return true
        case "t":
            shifted ? CommandActions.reopenLastClosedTab() : CommandActions.newTab()
            return true
        case "n":
            CommandActions.newWindow()
            return true
        case "w":
            CommandActions.closeActiveTab()
            return true
        case ";":
            CommandActions.presentCommandPalette()
            return true
        case "[":
            CommandActions.outdentSelection()
            return true
        case "]":
            CommandActions.indentSelection()
            return true
        default:
            return false
        }
    }

    private static func handleControlKey(_ lower: String, engine: EditorEngine.TextView?) -> Bool {
        switch lower {
        case "k": CommandActions.deleteToEndOfLine();       return true
        case "t": CommandActions.transposeCharacters();     return true
        case "j": CommandActions.joinLines();               return true
        case "a": CommandActions.smartMoveToLineStart();    return true
        case "e": CaretMover.moveToLineEnd(in: engine);     return true
        case "f": CaretMover.move(in: engine, by: 1);       return true
        case "b": CaretMover.move(in: engine, by: -1);      return true
        case "n": CaretMover.moveCursor(in: engine, byLines: 1);  return true
        case "p": CaretMover.moveCursor(in: engine, byLines: -1); return true
        case "d": CommandActions.deleteWordForward();       return true
        case "h": CommandActions.deleteWordBackward();      return true
        default:  return false
        }
    }

    private static func handleOptionKey(_ lower: String, engine: EditorEngine.TextView?) -> Bool {
        switch lower {
        case "b":
            CaretMover.moveWord(in: engine, forward: false)
            return true
        case "f":
            CaretMover.moveWord(in: engine, forward: true)
            return true
        case "h":
            CommandActions.deleteWordBackward()
            return true
        case "d":
            CommandActions.deleteWordForward()
            return true
        default:
            return false
        }
    }

    private static func copySelection(from textView: EditorEngine.TextView?, clear: Bool = false) {
        guard let textView, textView.selectedRange.length > 0 else { return }
        let nsText = textView.text as NSString
        let str = nsText.substring(with: textView.selectedRange)
        UIPasteboard.general.string = str
        if clear {
            textView.replace(textView.selectedRange, withText: "")
        }
    }

    private static func pasteAtSelection(into textView: EditorEngine.TextView?) {
        guard let textView, let clip = UIPasteboard.general.string else { return }
        textView.replace(textView.selectedRange, withText: clip)
    }
}

// MARK: - Accessory view (iPhone)

/// Two-row input accessory view. Drawer row (collapsible) sits above
/// the main row; both scroll horizontally if content overflows.
@MainActor
final class EditorAccessoryView: UIInputView, UIScrollViewDelegate {

    weak var host: EditorEngine.TextView?

    private let mainRow: AccessoryRow
    private let drawerRow: AccessoryRow
    private var drawerOpen: Bool
    private weak var controlButton: AccessoryButton?
    private weak var commandButton: AccessoryButton?
    private weak var optionButton: AccessoryButton?
    private weak var shiftButton: AccessoryButton?

    init(host: EditorEngine.TextView) {
        self.host = host
        self.drawerOpen = UserDefaults.standard.bool(
            forKey: AppPreferenceKey.accessoryDrawerOpenByDefault
        )
        self.mainRow = AccessoryRow(style: .main)
        self.drawerRow = AccessoryRow(style: .drawer)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 92),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        buildRows()
        layout()
        refreshModifierVisuals()
        startStateObserver()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: drawerOpen ? Self.totalHeightOpen : Self.totalHeightClosed)
    }

    private static let mainRowHeight: CGFloat = 44
    private static let drawerRowHeight: CGFloat = 38
    private static let totalHeightClosed: CGFloat = mainRowHeight
    private static let totalHeightOpen: CGFloat = mainRowHeight + drawerRowHeight + 1

    private func layout() {
        let separator = UIView()
        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [drawerRow, separator, mainRow])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            drawerRow.heightAnchor.constraint(equalToConstant: Self.drawerRowHeight),
            mainRow.heightAnchor.constraint(equalToConstant: Self.mainRowHeight),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        drawerRow.isHidden = !drawerOpen
        separator.isHidden = !drawerOpen
    }

    // MARK: Row builders

    private func buildRows() {
        mainRow.setButtons(mainRowButtons())
        drawerRow.setButtons(drawerRowButtons())
    }

    private func mainRowButtons() -> [AccessoryButton] {
        var buttons: [AccessoryButton] = []

        // Dismiss keyboard
        buttons.append(button(symbol: "chevron.down", label: "Hide Keyboard") { [weak self] in
            self?.host?.resignFirstResponder()
        })

        // Tab switcher
        buttons.append(button(symbol: "square.stack", label: "Tab Switcher") { [weak self] in
            self?.claimFocus()
            CommandActions.showTabSwitcher()
        })

        // Escape — clears find / dismisses sheet / collapses selection
        buttons.append(button(symbol: "escape", label: "Escape") { [weak self] in
            self?.handleEscape()
        })

        // Sticky modifier cluster — tap arms; consumed by the next
        // key on the iOS keyboard. Tapping a different modifier
        // disarms the others so only one is in flight at a time
        // (except ⇧ + ⌘ together, which Cmd's dispatch handles).
        // IMPORTANT: hold each button in a local `let` before writing
        // to the `weak` ivar — otherwise the autoreleased return
        // value dies before the array append and the weak ref nils
        // out, crashing the next force-unwrap.
        let control = modifierButton(symbol: "control",
                                     label: "Control",
                                     keyPath: \.armedAccessoryControl)
        controlButton = control
        buttons.append(control)

        let command = modifierButton(symbol: "command",
                                     label: "Command",
                                     keyPath: \.armedAccessoryCommand)
        commandButton = command
        buttons.append(command)

        let option = modifierButton(symbol: "option",
                                    label: "Option",
                                    keyPath: \.armedAccessoryOption)
        optionButton = option
        buttons.append(option)

        let shift = modifierButton(symbol: "shift",
                                   label: "Shift",
                                   keyPath: \.armedAccessoryShift,
                                   allowStackingWith: \.armedAccessoryCommand)
        shiftButton = shift
        buttons.append(shift)

        // Line / document cursor jumps
        buttons.append(button(symbol: "arrow.left.to.line", label: "Start of Line") { [weak self] in
            CaretMover.moveToLineStart(in: self?.host)
        })
        buttons.append(button(symbol: "arrow.right.to.line", label: "End of Line") { [weak self] in
            CaretMover.moveToLineEnd(in: self?.host)
        })
        buttons.append(button(symbol: "arrow.up.to.line", label: "Start of Document") { [weak self] in
            CaretMover.moveToDocumentStart(in: self?.host)
        })
        buttons.append(button(symbol: "arrow.down.to.line", label: "End of Document") { [weak self] in
            CaretMover.moveToDocumentEnd(in: self?.host)
        })

        // Joystick — pan-gesture trackpad on the button itself
        buttons.append(joystickButton())

        // Drawer toggle
        buttons.append(button(symbol: "ellipsis", label: "Toggle Drawer") { [weak self] in
            self?.toggleDrawer()
        })

        // Accessory settings
        buttons.append(button(symbol: "gearshape", label: "Keyboard Settings") { [weak self] in
            self?.presentSettings()
        })

        return buttons
    }

    /// Sticky-modifier factory. `allowStackingWith` keeps that other
    /// flag intact when this one arms (so ⇧ can coexist with ⌘ for
    /// ⌘⇧S / ⌘⇧T / etc.).
    private func modifierButton(
        symbol: String,
        label: String,
        keyPath: ReferenceWritableKeyPath<EditorState, Bool>,
        allowStackingWith stackKeyPath: ReferenceWritableKeyPath<EditorState, Bool>? = nil
    ) -> AccessoryButton {
        button(symbol: symbol, label: label) { [weak self] in
            guard let self, let state = self.host?.editorState else { return }
            let armingThis = !state[keyPath: keyPath]
            // Disarm the other modifiers (except the explicitly
            // allowed stacking partner).
            let allOthers: [ReferenceWritableKeyPath<EditorState, Bool>] = [
                \.armedAccessoryControl,
                \.armedAccessoryCommand,
                \.armedAccessoryOption,
                \.armedAccessoryShift,
            ]
            for path in allOthers where path != keyPath && path != stackKeyPath {
                state[keyPath: path] = false
            }
            state[keyPath: keyPath] = armingThis
            self.refreshModifierVisuals()
        }
    }

    private func drawerRowButtons() -> [AccessoryButton] {
        // Order roughly mirrors the rootshell drawer: modifier
        // placeholders → punctuation → action keys.
        let chars: [(String, String)] = [
            // Punctuation palette useful for code editing.
            ("`", "Backtick"), ("~", "Tilde"), ("^", "Caret"),
            ("_", "Underscore"), ("\\", "Backslash"), ("|", "Pipe"),
            ("(", "Left Paren"), (")", "Right Paren"),
            ("{", "Left Brace"), ("}", "Right Brace"),
            ("[", "Left Bracket"), ("]", "Right Bracket"),
            ("<", "Less Than"), (">", "Greater Than"),
            ("/", "Slash"), ("?", "Question Mark"),
            ("-", "Dash"), ("=", "Equals"),
            ("'", "Single Quote"), ("\"", "Double Quote"),
            ("@", "At Sign"), ("#", "Hash"), ("$", "Dollar"),
            ("%", "Percent"), ("&", "Ampersand"), ("*", "Asterisk"),
            (";", "Semicolon"), (":", "Colon")
        ]

        var buttons: [AccessoryButton] = chars.map { (glyph, label) in
            button(title: glyph, label: label) { [weak self] in
                guard let host = self?.host else { return }
                host.replace(host.selectedRange, withText: glyph)
            }
        }

        // Trailing action keys — paste + the view toggles that
        // matter for an editor (the SSH-only ones from rootshell
        // are dropped).
        buttons.append(button(symbol: "doc.on.clipboard", label: "Paste") { [weak self] in
            guard let host = self?.host, let clip = UIPasteboard.general.string else { return }
            host.replace(host.selectedRange, withText: clip)
        })
        buttons.append(button(symbol: "rectangle.topthird.inset.filled", label: "Toggle Tab Bar") { [weak self] in
            self?.claimFocus()
            UserDefaults.standard.set(
                !UserDefaults.standard.bool(forKey: AppPreferenceKey.showToolbar),
                forKey: AppPreferenceKey.showToolbar
            )
        })

        return buttons
    }

    // MARK: Actions

    private func toggleDrawer() {
        drawerOpen.toggle()
        drawerRow.isHidden = !drawerOpen
        if let separator = drawerRow.superview?.subviews.compactMap({ $0 as? UIStackView }).first?.arrangedSubviews[safe: 1] {
            separator.isHidden = !drawerOpen
        }
        invalidateIntrinsicContentSize()
    }

    private func handleEscape() {
        // Order: clear armed modifiers → dismiss sheet → clear
        // selection. Each step short-circuits if it had work to do.
        if let state = host?.editorState,
           state.armedAccessoryControl || state.armedAccessoryShift {
            state.armedAccessoryControl = false
            state.armedAccessoryShift = false
            refreshModifierVisuals()
            return
        }
        let bus = AppStateBus.shared
        if bus.editing.presentedSheet != nil {
            bus.editing.presentedSheet = nil
            return
        }
        if let host, host.selectedRange.length > 0 {
            host.selectedRange = NSRange(location: host.selectedRange.location, length: 0)
        }
    }

    private func presentSettings() {
        claimFocus()
        AppStateBus.shared.editing.presentedSheet = .accessoryKeyboardSettings
    }

    private func claimFocus() {
        // The accessory's host is the current scene's textView, so
        // claim that as currentEditor before triggering anything
        // that reads the bus pointers.
        guard let host, let state = host.editorState else { return }
        AppStateBus.shared.scenes.currentEditor = state
    }

    private func refreshModifierVisuals() {
        let state = host?.editorState
        controlButton?.isToggled = state?.armedAccessoryControl ?? false
        commandButton?.isToggled = state?.armedAccessoryCommand ?? false
        optionButton?.isToggled  = state?.armedAccessoryOption ?? false
        shiftButton?.isToggled   = state?.armedAccessoryShift ?? false
    }

    /// Polls the host state's armed flags so the engine clearing them
    /// (after consuming a key) updates the button visuals. CADisplay-
    /// Link is overkill; a 100 ms timer is invisible to the user.
    private func startStateObserver() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshModifierVisuals() }
        }
        timer.tolerance = 0.04
        objc_setAssociatedObject(self, &observerTimerKey, timer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: Joystick

    private func joystickButton() -> AccessoryButton {
        let btn = JoystickButton()
        btn.configure(symbol: "arrow.up.and.down.and.arrow.left.and.right",
                      accessibility: "Arrow Joystick (drag to move cursor)")
        btn.host = host
        return btn
    }

    // MARK: Button factory

    private func button(symbol: String,
                        label: String,
                        action: @escaping () -> Void) -> AccessoryButton {
        let btn = AccessoryButton(style: .main)
        btn.configure(symbol: symbol, accessibility: label)
        btn.tapAction = action
        return btn
    }

    private func button(title: String,
                        label: String,
                        action: @escaping () -> Void) -> AccessoryButton {
        let btn = AccessoryButton(style: .drawer)
        btn.configure(title: title, accessibility: label)
        btn.tapAction = action
        return btn
    }
}

private nonisolated(unsafe) var observerTimerKey: UInt8 = 0

// MARK: - Row

@MainActor
private final class AccessoryRow: UIView {

    enum Style { case main, drawer }
    let style: Style

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        let hInset: CGFloat = 8
        let vInset: CGFloat = style == .main ? 4 : 2
        stack.layoutMargins = UIEdgeInsets(top: vInset, left: hInset, bottom: vInset, right: hInset)
        stack.isLayoutMarginsRelativeArrangement = true
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setButtons(_ buttons: [AccessoryButton]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for btn in buttons { stack.addArrangedSubview(btn) }
    }
}

// MARK: - Button

@MainActor
class AccessoryButton: UIControl {

    enum Style { case main, drawer }
    private let style: Style

    private let label = UILabel()
    private let symbolView = UIImageView()
    var tapAction: (() -> Void)?

    var isToggled: Bool = false {
        didSet { updateBackground() }
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = style == .main ? 8 : 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        label.font = style == .main
            ? .systemFont(ofSize: 17, weight: .regular)
            : .systemFont(ofSize: 16, weight: .regular)
        label.textAlignment = .center
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .label
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: style == .main ? 17 : 14, weight: .regular
        )
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(symbolView)
        let minWidth: CGFloat = style == .main ? 38 : 30
        let minHeight: CGFloat = style == .main ? 36 : 32
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateBackground()
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, accessibility: String) {
        symbolView.image = UIImage(systemName: symbol)
        symbolView.isHidden = false
        label.isHidden = true
        accessibilityLabel = accessibility
        isAccessibilityElement = true
    }

    func configure(title: String, accessibility: String) {
        label.text = title
        label.isHidden = false
        symbolView.isHidden = true
        accessibilityLabel = accessibility
        isAccessibilityElement = true
    }

    private func updateBackground() {
        backgroundColor = isToggled
            ? UIColor.tintColor.withAlphaComponent(0.35)
            : UIColor.label.withAlphaComponent(0.06)
    }

    override var isHighlighted: Bool {
        didSet {
            if isHighlighted {
                backgroundColor = UIColor.label.withAlphaComponent(0.18)
            } else {
                updateBackground()
            }
        }
    }

    @objc private func handleTap() {
        tapAction?()
    }
}

// MARK: - Joystick (pan-gesture trackpad)

/// Drag-to-move cursor button. Vertical drag steps by line, horizontal
/// by character; diagonal drag fires both axes simultaneously. Drag
/// thresholds are sized so a small wrist movement reaches each
/// neighbour without overshooting.
@MainActor
final class JoystickButton: AccessoryButton {

    weak var host: EditorEngine.TextView?

    /// Tracked drag offset since the last fire, per axis. Each time
    /// `|offset|` crosses the per-axis step, we fire one move and
    /// subtract that step — the user can keep dragging to keep moving.
    private var startTranslation: CGPoint = .zero
    private var firedOffset: CGPoint = .zero

    /// Pixels of drag = one cursor step. Chars move smaller than
    /// lines (~half) because lines are taller than character cells.
    private static let charStep: CGFloat = 11
    private static let lineStep: CGFloat = 18

    init() {
        super.init(style: .main)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)
        // The drag below would otherwise also fire the inherited
        // touchUpInside tap. With no tap action set on the joystick
        // (we only react to drag), `handleTap` is a no-op anyway.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            startTranslation = .zero
            firedOffset = .zero
        case .changed:
            let translation = recognizer.translation(in: self)
            consumeAxis(translation: translation)
        case .ended, .cancelled, .failed:
            startTranslation = .zero
            firedOffset = .zero
        default:
            break
        }
    }

    private func consumeAxis(translation: CGPoint) {
        // Horizontal — characters
        let dxRemainder = translation.x - firedOffset.x
        if abs(dxRemainder) >= Self.charStep {
            let steps = Int((dxRemainder / Self.charStep).rounded(.towardZero))
            CaretMover.move(in: host, by: steps)
            firedOffset.x += CGFloat(steps) * Self.charStep
        }
        // Vertical — lines
        let dyRemainder = translation.y - firedOffset.y
        if abs(dyRemainder) >= Self.lineStep {
            let lineSteps = Int((dyRemainder / Self.lineStep).rounded(.towardZero))
            CaretMover.moveCursor(in: host, byLines: lineSteps)
            firedOffset.y += CGFloat(lineSteps) * Self.lineStep
        }
    }
}

// MARK: - Helpers

private extension EditorEngine.TextView {
    /// Reach back to the `EditorState` the host owns. The accessory
    /// needs it to toggle armed modifiers and read tab-switcher
    /// targets.
    var editorState: EditorState? {
        AppStateBus.shared.scenes.allOpenSessions
            .flatMap(\.tabs)
            .first(where: { $0.state.textView === self })?
            .state
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
