import SwiftUI

// MARK: - Slot model

/// `commandId` matches `CommandRegistry.all()`.
struct ToolbarSlot: Codable, Equatable, Identifiable {
    var commandId: String
    /// SF Symbol name OR `u:HEX` for a raw codepoint (`u:1F4BE` =
    /// the floppy disk). The unicode form lets us surface non-SF
    /// glyphs at the toolbar size in monochrome.
    var symbol: String
    var id: String { commandId + "|" + symbol }
}

/// SF Symbol via name, or a raw codepoint via the `u:HEX` prefix.
/// The unicode path appends U+FE0E (text-presentation VS15) so
/// emoji-form codepoints like 💾 render in monochrome to match the
/// SF Symbols around them.
@ViewBuilder
func toolbarSymbol(_ symbol: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
    if let scalar = unicodeScalar(forSymbolRef: symbol) {
        Text(String(scalar) + "\u{FE0E}")
            .font(.system(size: size * 1.1, weight: weight))
            .foregroundStyle(.primary)
    } else {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.hierarchical)
    }
}

private func unicodeScalar(forSymbolRef ref: String) -> Unicode.Scalar? {
    guard ref.hasPrefix("u:") else { return nil }
    let hex = String(ref.dropFirst(2))
    guard let value = UInt32(hex, radix: 16),
          let scalar = Unicode.Scalar(value) else { return nil }
    return scalar
}

// MARK: - Config / persistence

/// Shared by the toolbar, slot editor, and Settings UI.
@MainActor
@Observable
final class ToolbarConfig {

    static let shared = ToolbarConfig()

    /// Broken symbol names render as a placeholder glyph at runtime.
    static let defaults: [ToolbarSlot] = [
        .init(commandId: "find",      symbol: "magnifyingglass"),
        .init(commandId: "findRepl",  symbol: "arrow.triangle.2.circlepath"),
        .init(commandId: "gotoLine",  symbol: "arrow.down.to.line.compact"),
        .init(commandId: "comment",   symbol: "number"),
        .init(commandId: "indent",    symbol: "increase.indent"),
        .init(commandId: "outdent",   symbol: "decrease.indent"),
        .init(commandId: "sortLines", symbol: "arrow.up.arrow.down"),
        .init(commandId: "trim",      symbol: "scissors")
    ]

    private(set) var slots: [ToolbarSlot]

    private init() {
        self.slots = Self.load() ?? Self.defaults
    }

    func setSlots(_ newSlots: [ToolbarSlot]) {
        slots = newSlots
        save()
    }

    func update(slotAt index: Int, commandId: String, symbol: String) {
        guard slots.indices.contains(index) else { return }
        slots[index] = ToolbarSlot(commandId: commandId, symbol: symbol)
        save()
    }

    func insert(_ slot: ToolbarSlot, at index: Int? = nil) {
        if let index, slots.indices.contains(index) {
            slots.insert(slot, at: index)
        } else {
            slots.append(slot)
        }
        save()
    }

    func remove(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots.remove(at: index)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func resetToDefaults() {
        slots = Self.defaults
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.toolbarSlots)
    }

    private static func load() -> [ToolbarSlot]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.toolbarSlots),
              let decoded = try? JSONDecoder().decode([ToolbarSlot].self, from: data)
        else { return nil }
        return decoded
    }
}

// MARK: - Toolbar view

/// Title + a horizontal pill of SF Symbol buttons on the same line,
/// collapsing what would otherwise be two stacked rows (system nav
/// bar + custom toolbar). Overflow folds into a trailing `+` menu.
struct WindowToolbar: View {

    let title: String
    let subtitle: String
    /// Claims focus on the bus before any toolbar action fires, so
    /// a stale `currentEditor` doesn't land sheets / pickers in the
    /// wrong window.
    let onInteraction: (() -> Void)?

    @State private var config = ToolbarConfig.shared
    @State private var editing: EditingSlot?

    /// Glyph size; touch target is bigger (see `ToolbarSlotButton`).
    static let buttonSize: CGFloat = 30
    /// iPad HIG minimum — 44×44 pt would also be valid; 38 reads
    /// better in the pill at our point size.
    static let touchTarget: CGFloat = 38
    private static let buttonSpacing: CGFloat = 2
    private static let pillInsetH: CGFloat = 6
    private static let pillInsetV: CGFloat = 4
    private static let outerPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 6
    /// Keeps the last visible item from butting against the `+`.
    private static let overflowSlot: CGFloat = touchTarget + buttonSpacing

    init(title: String, subtitle: String, onInteraction: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.onInteraction = onInteraction
    }

    var body: some View {
        let registry = CommandRegistry.all()
        GeometryReader { proxy in
            // iPad scene chrome (●●● stoplight) takes the top-left
            // — ~60 pt + breathing room so the title isn't behind it.
            let stoplightInset: CGFloat = 70
            // Mirror inset for the centered pill: 2× this keeps the
            // pill symmetric around the midpoint without crashing
            // into the undo + palette cluster.
            let trailingZone = Self.touchTarget * 2 + Self.buttonSpacing + Self.outerPadding
            // 600 = iPhone Plus landscape. Below that the centered
            // pill would overlap the title (it claims 60% of width
            // and the title's flex zone goes negative), so collapse
            // every slot into the overflow.
            let compact = proxy.size.width < 600
            if compact {
                compactBody(proxy: proxy,
                            stoplightInset: stoplightInset,
                            trailingZone: trailingZone,
                            registry: registry)
            } else {
                regularBody(proxy: proxy,
                            stoplightInset: stoplightInset,
                            trailingZone: trailingZone,
                            registry: registry)
            }
        }
        .frame(height: Self.touchTarget + Self.pillInsetV * 2 + Self.verticalPadding * 2)
        .sheet(item: $editing) { editing in
            ToolbarSlotEditor(slotIndex: editing.index, initial: editing.slot)
        }
    }

    /// Centered pill flanked by title + trailing controls.
    @ViewBuilder
    private func regularBody(
        proxy: GeometryProxy,
        stoplightInset: CGFloat,
        trailingZone: CGFloat,
        registry: [EditorCommandSpec]
    ) -> some View {
        let estimatedPill = min(
            CGFloat(config.slots.count + 1) * (Self.touchTarget + Self.buttonSpacing) + Self.pillInsetH * 2,
            proxy.size.width * 0.6,
            max(0, proxy.size.width - 2 * (stoplightInset + trailingZone))
        )
        let titleAvailable = max(60, (proxy.size.width - estimatedPill) / 2 - stoplightInset - 12)
        let fitCount = visibleCount(forPillInteriorWidth: estimatedPill - Self.pillInsetH * 2)
        let visible = Array(config.slots.prefix(fitCount))
        let overflow = Array(config.slots.dropFirst(fitCount))
        ZStack(alignment: .center) {
            HStack(spacing: 8) {
                sidebarButton
                    .padding(.leading, stoplightInset)
                titleBlock
                    .frame(maxWidth: max(60, titleAvailable - Self.touchTarget - 8),
                           alignment: .leading)
                Spacer(minLength: 0)
            }
            pill(visible: visible, overflow: overflow, registry: registry)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                trailingControls
                    .padding(.trailing, Self.outerPadding)
            }
        }
        .padding(.vertical, Self.verticalPadding)
    }

    /// Narrow / Split-View / Stage-Manager-skinny — drops the pill;
    /// every slot folds into a single trailing-edge overflow menu.
    @ViewBuilder
    private func compactBody(
        proxy: GeometryProxy,
        stoplightInset: CGFloat,
        trailingZone: CGFloat,
        registry: [EditorCommandSpec]
    ) -> some View {
        // No stoplight chrome in compact widths — system chrome
        // collapses to a single icon.
        let compactLeading: CGFloat = 8
        HStack(spacing: 6) {
            sidebarButton
                .padding(.leading, compactLeading)
            titleBlock
                .layoutPriority(1)
            Spacer(minLength: 0)
            if !config.slots.isEmpty {
                compactOverflowMenu(registry: registry)
            }
            trailingControls
                .padding(.trailing, Self.outerPadding)
        }
        .padding(.vertical, Self.verticalPadding)
    }

    @ViewBuilder
    private func compactOverflowMenu(registry: [EditorCommandSpec]) -> some View {
        Menu {
            ForEach(Array(config.slots.enumerated()), id: \.element.id) { _, slot in
                if let cmd = registry.first(where: { $0.id == slot.commandId }) {
                    Button {
                        onInteraction?()
                        if cmd.isEnabled() { cmd.action() }
                    } label: {
                        Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                    }
                    .disabled(!cmd.isEnabled())
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("More toolbar actions")
    }

    /// Tap / context-menu / inline-rename behaviour is shared with
    /// the iPhone nav-bar principal item via `EditableTitleView`.
    @ViewBuilder
    private var titleBlock: some View {
        EditableTitleView(
            title: title,
            subtitle: subtitle,
            titleFont: .system(size: Self.buttonSize * 0.45, weight: .semibold),
            subtitleFont: .caption,
            maxRenameWidth: 280,
            // Same per-window focus claim as the toolbar buttons —
            // without this, title-tap Save As lands in whichever
            // window `currentEditor` happens to point at.
            onInteraction: onInteraction
        )
    }

    @ViewBuilder
    private var sidebarButton: some View {
        bareButton(symbol: "sidebar.left", help: "Toggle Sidebar") {
            CommandActions.toggleSidebar()
        }
    }

    /// Undo + Command Palette — chrome, not customizable.
    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: Self.buttonSpacing) {
            bareButton(symbol: "arrow.uturn.backward", help: "Undo") {
                CommandActions.undo()
            }
            bareButton(symbol: "command.square", help: "Command Palette") {
                CommandActions.presentCommandPalette()
            }
        }
    }

    @ViewBuilder
    private func bareButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            // Claim focus first so the action's sheet/window lands
            // on this scene and not whichever was last in scenePhase.
            onInteraction?()
            action()
        }) {
            Image(systemName: symbol)
                .font(.system(size: Self.buttonSize * 0.5, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func pill(visible: [ToolbarSlot], overflow: [ToolbarSlot], registry: [EditorCommandSpec]) -> some View {
        HStack(spacing: Self.buttonSpacing) {
            ForEach(visible) { slot in
                ToolbarSlotButton(
                    slot: slot,
                    command: command(for: slot.commandId, in: registry),
                    onLongPress: { editSlot(slot) },
                    onInteraction: onInteraction
                )
            }
            if !overflow.isEmpty {
                overflowMenu(items: overflow, registry: registry)
            }
        }
        .padding(.horizontal, Self.pillInsetH)
        .padding(.vertical, Self.pillInsetV)
        .background(.bar, in: .capsule)
        .overlay(
            Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    /// Reserves space for the `+` button only when the slots
    /// actually overflow; otherwise returns the full count so the
    /// `+` doesn't render.
    private func visibleCount(forPillInteriorWidth interior: CGFloat) -> Int {
        let total = config.slots.count
        guard total > 0, interior > 0 else { return 0 }
        let perItem = Self.touchTarget + Self.buttonSpacing
        let allFit = CGFloat(total) * perItem - Self.buttonSpacing
        if allFit <= interior { return total }
        let usable = interior - Self.overflowSlot
        let count = max(0, Int(floor((usable + Self.buttonSpacing) / perItem)))
        return min(count, total)
    }

    @ViewBuilder
    private func overflowMenu(items: [ToolbarSlot], registry: [EditorCommandSpec]) -> some View {
        Menu {
            ForEach(items) { slot in
                if let cmd = command(for: slot.commandId, in: registry) {
                    Button {
                        if cmd.isEnabled() { cmd.action() }
                    } label: {
                        Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                    }
                    .disabled(!cmd.isEnabled())
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.buttonSize * 0.45, weight: .regular))
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
    }

    private func command(for id: String, in registry: [EditorCommandSpec]) -> EditorCommandSpec? {
        registry.first { $0.id == id }
    }

    private func editSlot(_ slot: ToolbarSlot) {
        guard let index = config.slots.firstIndex(where: { $0.id == slot.id }) else { return }
        editing = EditingSlot(index: index, slot: slot)
    }

    private struct EditingSlot: Identifiable {
        let index: Int
        let slot: ToolbarSlot
        var id: String { "\(index)|\(slot.id)" }
    }
}

private struct ToolbarSlotButton: View {

    let slot: ToolbarSlot
    let command: EditorCommandSpec?
    let onLongPress: () -> Void
    let onInteraction: (() -> Void)?

    private var isEnabled: Bool { command?.isEnabled() ?? false }
    private var symbolName: String { slot.symbol.isEmpty ? "questionmark.square.dashed" : slot.symbol }

    var body: some View {
        Button {
            onInteraction?()
            if let cmd = command, cmd.isEnabled() { cmd.action() }
        } label: {
            toolbarSymbol(symbolName, size: WindowToolbar.buttonSize * 0.5)
                .frame(width: WindowToolbar.touchTarget, height: WindowToolbar.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .help(command?.title ?? slot.commandId)
        // Long-press opens the per-slot editor. Settings ▸ Toolbar
        // is the canonical customization UI.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() }
        )
    }
}

// MARK: - SF Symbol picker

/// A curated picker — Apple doesn't ship one, and the full ~6 000-
/// symbol catalogue would be unbrowsable. Users can still enter any
/// name manually; the library is just the discoverable shortlist.
enum ToolbarSymbolLibrary {

    /// Order is intentional — most-used categories first.
    static let groups: [(String, [String])] = [
        ("Find & Navigate", [
            "magnifyingglass", "text.magnifyingglass", "arrow.triangle.2.circlepath",
            "arrow.uturn.backward", "arrow.uturn.forward",
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
            "arrow.up.to.line", "arrow.down.to.line",
            "arrow.up.to.line.compact", "arrow.down.to.line.compact",
            "chevron.up", "chevron.down", "chevron.left", "chevron.right",
            "chevron.left.forwardslash.chevron.right", "arrow.forward", "arrow.backward"
        ]),
        ("Text Format", [
            "textformat", "textformat.size", "textformat.size.larger", "textformat.size.smaller",
            "textformat.abc", "textformat.123", "textformat.alt",
            "bold", "italic", "underline", "strikethrough",
            "text.justify", "text.alignleft", "text.aligncenter", "text.alignright",
            "increase.indent", "decrease.indent",
            "increase.quotelevel", "decrease.quotelevel",
            "characters.lowercase", "characters.uppercase"
        ]),
        ("Lines & Lists", [
            "list.bullet", "list.dash", "list.number", "list.bullet.indent",
            "list.triangle", "line.3.horizontal", "line.horizontal.3.decrease",
            "arrow.up.arrow.down", "arrow.up.and.down.text.horizontal",
            "line.diagonal.arrow", "arrow.left.and.right",
            "rectangle.compress.vertical", "rectangle.expand.vertical"
        ]),
        ("Edit", [
            "pencil", "square.and.pencil", "pencil.tip",
            "scissors", "doc.on.doc", "doc.on.clipboard",
            "trash", "trash.slash",
            "arrow.uturn.left.circle", "arrow.uturn.right.circle",
            "plus", "minus", "xmark", "checkmark",
            "plus.circle", "minus.circle", "xmark.circle", "checkmark.circle"
        ]),
        ("Code", [
            "curlybraces", "curlybraces.square", "parentheses",
            "number", "number.square", "percent",
            "function", "terminal", "command",
            "doc.text", "doc.plaintext", "doc.text.below.ecg"
        ]),
        ("File", [
            "doc", "doc.fill", "doc.text.magnifyingglass",
            "folder", "folder.badge.plus",
            "square.and.arrow.up", "square.and.arrow.down",
            "tray", "tray.full", "paperplane", "paperclip",
            "link", "rectangle.and.paperclip",
            // 💾 — classic floppy via toolbarSymbol's `u:HEX` path
            // (VS15 forces monochrome).
            "u:1F4BE"
        ]),
        ("View", [
            "sidebar.left", "sidebar.right", "rectangle.split.2x1",
            "eye", "eye.slash",
            "square.grid.2x2", "rectangle.lefthalf.inset.filled",
            "ruler", "ruler.fill"
        ]),
        ("Bookmarks & Marks", [
            "bookmark", "bookmark.fill", "star", "star.fill",
            "flag", "flag.fill", "tag", "tag.fill",
            "exclamationmark.triangle", "exclamationmark.circle",
            "info.circle", "questionmark.circle"
        ]),
        ("Misc", [
            "circle", "square", "diamond", "triangle",
            "asterisk", "at", "underscore",
            "scribble", "highlighter", "paintbrush",
            "wand.and.stars", "sparkles",
            "wrench.and.screwdriver", "gear", "sliders.horizontal"
        ])
    ]

    /// Flat list, used by the search filter.
    static let all: [String] = groups.flatMap(\.1)
}

/// Tap commits + dismisses. The free-text row at the bottom takes
/// any system symbol name, not just what's in the library.
struct ToolbarSymbolPicker: View {

    @Environment(\.dismiss) private var dismiss
    @Binding var selected: String
    @State private var query: String = ""
    @State private var manualEntry: String

    init(selected: Binding<String>) {
        self._selected = selected
        self._manualEntry = State(initialValue: selected.wrappedValue)
    }

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                ScrollView {
                    if query.isEmpty {
                        ForEach(ToolbarSymbolLibrary.groups, id: \.0) { (category, symbols) in
                            section(title: category, symbols: symbols)
                        }
                    } else {
                        let matches = ToolbarSymbolLibrary.all.filter {
                            $0.localizedCaseInsensitiveContains(query)
                        }
                        if matches.isEmpty {
                            ContentUnavailableView(
                                "No matches",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different word, or enter the exact SF Symbol name below.")
                            )
                            .padding(.top, 40)
                        } else {
                            section(title: "Results", symbols: matches)
                        }
                    }

                    manualSection
                }
            }
            .navigationTitle("Choose Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search symbols", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(title: String, symbols: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(symbols, id: \.self) { name in
                    cell(symbol: name)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func cell(symbol name: String) -> some View {
        let isSelected = (name == selected)
        Button {
            selected = name
            dismiss()
        } label: {
            VStack(spacing: 4) {
                toolbarSymbol(name, size: 24)
                    .frame(width: 56, height: 44)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: .rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                Text(name)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Symbol Name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            HStack(spacing: 12) {
                toolbarSymbol(manualEntry.isEmpty ? "questionmark.square.dashed" : manualEntry, size: 24)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                TextField("e.g. flame.circle.fill", text: $manualEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Use") {
                    let trimmed = manualEntry.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        selected = trimmed
                        dismiss()
                    }
                }
                .disabled(manualEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

/// Shared by `ToolbarSlotEditor` and `ToolbarSlotAdder`.
@ViewBuilder
func iconPickerRow(symbol: Binding<String>, pickingSymbol: Binding<Bool>) -> some View {
    HStack(spacing: 16) {
        toolbarSymbol(symbol.wrappedValue.isEmpty ? "questionmark.square.dashed" : symbol.wrappedValue, size: 32)
            .frame(width: 60, height: 60)
            .background(.quaternary, in: .rect(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 4) {
            Button {
                pickingSymbol.wrappedValue = true
            } label: {
                Label("Choose Symbol…", systemImage: "square.grid.2x2")
            }
            Text(symbol.wrappedValue.isEmpty ? "No symbol" : symbol.wrappedValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        Spacer()
    }
    .padding(.vertical, 4)
    .sheet(isPresented: pickingSymbol) {
        ToolbarSymbolPicker(selected: symbol)
    }
}

// MARK: - Slot editor (long-press target; also reused by Settings)

struct ToolbarSlotEditor: View {

    @Environment(\.dismiss) private var dismiss
    let slotIndex: Int
    @State private var query: String = ""
    @State private var selectedCommandId: String
    @State private var symbol: String
    @State private var pickingSymbol: Bool = false

    private let allCommands: [EditorCommandSpec] = CommandRegistry.all()

    init(slotIndex: Int, initial: ToolbarSlot) {
        self.slotIndex = slotIndex
        _selectedCommandId = State(initialValue: initial.commandId)
        _symbol = State(initialValue: initial.symbol)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") {
                    iconPickerRow(symbol: $symbol, pickingSymbol: $pickingSymbol)
                }
                Section("Command") {
                    TextField("Search commands…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(filtered) { cmd in
                        Button {
                            selectedCommandId = cmd.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cmd.title).foregroundStyle(.primary)
                                    Text(cmd.category.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cmd.id == selectedCommandId {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Toolbar Item \(slotIndex + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ToolbarConfig.shared.update(
                            slotAt: slotIndex,
                            commandId: selectedCommandId,
                            symbol: symbol
                        )
                        dismiss()
                    }
                    .disabled(selectedCommandId.isEmpty || symbol.isEmpty)
                }
            }
        }
    }

    private var filtered: [EditorCommandSpec] {
        if query.isEmpty {
            let head = allCommands.filter { $0.id == selectedCommandId }
            let rest = allCommands.filter { $0.id != selectedCommandId }
            return Array((head + rest).prefix(80))
        }
        return allCommands
            .compactMap { cmd -> (EditorCommandSpec, Int)? in
                guard let s = FuzzyMatcher.bestScore(query, against: cmd) else { return nil }
                return (cmd, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
