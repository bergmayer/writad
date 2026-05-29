import SwiftUI
import FileEncoding
import LineEnding

struct EditorStatusBar: View {

    let document: PlainTextDocument
    @Bindable var state: EditorState

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.showToolbar) private var showToolbarPref: Bool = true

    var body: some View {
        if DeviceIdiom.isPhone || horizontalSizeClass == .compact {
            phoneBar
        } else {
            wideBar
        }
    }

    @ViewBuilder
    private var wideBar: some View {
        HStack(spacing: 12) {
            splitCycleButton
            Divider().frame(height: 14)
            // ViewThatFits drops the counts when the bar can't fit
            // them on one line — wrapping would double row height.
            ViewThatFits(in: .horizontal) {
                counts.foregroundStyle(.secondary)
                EmptyView()
            }
            Spacer(minLength: 8)
            byteCountLabel.foregroundStyle(.secondary)
            Divider().frame(height: 14)
            encodingMenu
            Divider().frame(height: 14)
            lineEndingMenu
            Divider().frame(height: 14)
            languageMenu
            Divider().frame(height: 14)
            revisionsButton
            Divider().frame(height: 14)
            infoToggle
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var phoneBar: some View {
        HStack(spacing: 16) {
            phoneTabsButton
            splitCycleButton
            Spacer()
            revisionsButton
            phoneOverflowMenu
            infoToggle
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                    if value.translation.width < -40 {
                        CommandActions.nextTab()
                    } else if value.translation.width > 40 {
                        CommandActions.previousTab()
                    }
                }
        )
    }

    @ViewBuilder
    private var phoneTabsButton: some View {
        Button {
            claimFocus()
            CommandActions.showTabSwitcher()
        } label: {
            ZStack {
                Image(systemName: "square.on.square")
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                if let count = phoneTabBadgeCount {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: .capsule)
                        .offset(x: 10, y: -8)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show All Tabs")
        .accessibilityLabel("Show All Tabs")
        .contextMenu { TabOverviewContextMenu() }
    }

    private var phoneTabBadgeCount: Int? {
        let count = bus.scenes.currentSession?.tabs.count ?? 1
        return count > 1 ? count : nil
    }

    @ViewBuilder
    private var phoneOverflowMenu: some View {
        Menu {
            Menu("Encoding")     { encodingMenuChoices }
            Menu("Line Endings") { lineEndingMenuChoices }
            Menu("Syntax")       { languageMenuChoices }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .help("Document settings")
    }

    @ViewBuilder
    private var splitCycleButton: some View {
        Button {
            claimFocus()
            CommandActions.cycleSplitView()
        } label: {
            Image(systemName: splitCycleSymbol)
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(splitCycleLabel)
        .help(splitCycleLabel)
    }

    private var splitCycleSymbol: String {
        switch (state.splitOpen, state.splitOrientation) {
        case (false, _):          return "rectangle"
        case (true, .horizontal): return "rectangle.split.2x1"
        case (true, .vertical):   return "rectangle.split.1x2"
        }
    }

    private var splitCycleLabel: String {
        switch (state.splitOpen, state.splitOrientation) {
        case (false, _):          return "Open Split View"
        case (true, .horizontal): return "Switch to Vertical Split"
        case (true, .vertical):   return "Close Split View"
        }
    }

    @ViewBuilder
    private var revisionsButton: some View {
        Button {
            claimFocus()
            CommandActions.presentRevisions()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Browse and restore previous versions of this document")
    }

    @ViewBuilder
    private var infoToggle: some View {
        Button {
            state.inspectorOpen.toggle()
        } label: {
            Image(systemName: "info")
                .font(.system(size: 14, weight: state.inspectorOpen ? .bold : .regular))
                .foregroundStyle(state.inspectorOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show file info, outline, and counts")
    }

    @ViewBuilder
    private var counts: some View {
        let nsText = document.text as NSString
        let (line, column) = TextMetrics.lineColumn(for: state.selectedRange.location, in: nsText)
        let lineCount = TextMetrics.lineCount(in: nsText)
        HStack(spacing: 8) {
            Text("Lines: \(lineCount)  ·  Chars: \(nsText.length)  ·  Loc: \(state.selectedRange.location)  ·  Ln \(line):\(column)")
            if state.liveMatchCount > 0 {
                Text("·  \(state.liveMatchCount) match\(state.liveMatchCount == 1 ? "" : "es")")
                    .foregroundStyle(.tint)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var byteCountLabel: some View {
        let bytes = document.originalData?.count ?? document.text.utf8.count
        Text("\(bytes.formatted(.number)) bytes")
    }

    @ViewBuilder
    private var encodingMenu: some View {
        Menu { encodingMenuChoices } label: {
            statusMenuLabel(document.fileEncoding.localizedName)
        }
    }

    @ViewBuilder
    private var encodingMenuChoices: some View {
        ForEach(Self.statusEncodingChoices, id: \.self) { encoding in
            let title = String.localizedName(of: encoding)
            Button {
                claimFocus()
                CommandActions.setEncoding(FileEncoding(encoding: encoding))
            } label: {
                if document.fileEncoding.encoding == encoding && !document.fileEncoding.withUTF8BOM {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
        if Self.statusEncodingChoices.contains(.utf8) {
            Divider()
            Button {
                claimFocus()
                CommandActions.setEncoding(FileEncoding(encoding: .utf8, withUTF8BOM: true))
            } label: {
                if document.fileEncoding.encoding == .utf8 && document.fileEncoding.withUTF8BOM {
                    Label("Unicode (UTF-8) with BOM", systemImage: "checkmark")
                } else {
                    Text("Unicode (UTF-8) with BOM")
                }
            }
        }
    }

    @ViewBuilder
    private var lineEndingMenu: some View {
        Menu { lineEndingMenuChoices } label: {
            statusMenuLabel(document.lineEnding.label)
        }
    }

    @ViewBuilder
    private var lineEndingMenuChoices: some View {
        ForEach(LineEnding.allCases, id: \.self) { ending in
            Button {
                claimFocus()
                CommandActions.setLineEnding(ending)
            } label: {
                if document.lineEnding == ending {
                    Label("\(ending.label) (\(ending.description))", systemImage: "checkmark")
                } else {
                    Text("\(ending.label) (\(ending.description))")
                }
            }
        }
    }

    @ViewBuilder
    private var languageMenu: some View {
        Menu { languageMenuChoices } label: {
            statusMenuLabel(LanguageRegistry.displayName(for: state.languageIdentifier))
        }
    }

    @ViewBuilder
    private var languageMenuChoices: some View {
        ForEach(LanguageRegistry.all, id: \.identifier) { language in
            Button {
                claimFocus()
                CommandActions.setLanguage(language.identifier)
            } label: {
                if state.languageIdentifier == language.identifier {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    private func statusMenuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }

    private func claimFocus() {
        bus.scenes.claimFocus(state: state)
    }

    private static let statusEncodingChoices: [String.Encoding] = {
        String.sortedAvailableStringEncodings.compactMap { $0 }
    }()
}
