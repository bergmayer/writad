import SwiftUI
import UniformTypeIdentifiers

/// Horizontal Safari-style tab strip shown above the editor when a
/// window has more than one tab. Pinned tabs render as compact
/// favicon-style chips on the left; unpinned tabs follow with full
/// filenames. Long-press a tab for the context menu (close / pin /
/// close others / close to the right); drag a tab to reorder it
/// within its half of the strip. The trailing area carries the
/// new-tab `+` button (long-press for recently-closed) and the
/// Show-All-Tabs grid button.
struct TabBarView: View {
    @Bindable var session: EditorSession

    /// Leading inset that keeps the leftmost tab clear of iPad's
    /// stoplight (close / minimize / resize) chrome at the top-left
    /// of the window. Matches the inset `WindowToolbar` uses.
    private let stoplightInset: CGFloat = 70

    var body: some View {
        tabStrip
            .padding(.leading, stoplightInset)
            .padding(.trailing, 8)
            .padding(.top, 6)
            // No bottom padding — active tab's background merges
            // straight into the document area below.
            .frame(height: 44)
        // Inactive tabs sit on a distinct strip; the active tab uses
        // `systemBackground` so its bottom edge merges into the
        // editor below with no visible seam.
        .background(Color(.secondarySystemBackground))
        // Strip-level drop destination: drops on empty space (not on
        // a specific pill) append the dragged tab to this window.
        // Drops on a specific pill still go through that pill's own
        // dropDestination first.
        .dropDestination(for: String.self) { items, _ -> Bool in
            return adoptDroppedTab(items: items)
        }
    }

    /// Cross-window adopt: drag a tab from another window and drop
    /// on this strip's blank area → migrate it here. Same-window
    /// drops on blank area are no-ops (use the pill drop to reorder).
    private func adoptDroppedTab(items: [String]) -> Bool {
        guard let raw = items.first,
              let uuid = UUID(uuidString: raw)
        else { return false }
        guard !session.tabs.contains(where: { $0.id == uuid }),
              let source = AppStateBus.shared.scenes.session(containing: uuid),
              source !== session,
              let tab = source.detachTab(uuid)
        else { return false }
        session.attachTab(tab)
        return true
    }

    @ViewBuilder
    private var tabStrip: some View {
        // Safari-style equal-width tabs: unpinned pills share the
        // available width evenly; pinned pills stay compact (fixed
        // size). `+` and Show-All-Tabs sit at the trailing end at
        // their natural widths.
        HStack(spacing: 2) {
            ForEach(session.tabs) { tab in
                draggablePill(for: tab)
                    .frame(maxWidth: tab.isPinned ? nil : .infinity)
            }
            plusButton
            showAllTabsButton
        }
    }

    @ViewBuilder
    private func draggablePill(for tab: TabModel) -> some View {
        TabPillView(
            tab: tab,
            isActive: tab.id == session.selectedTabID,
            // Always closeable — the last close spawns a launcher
            // tab in place rather than emptying the session.
            isCloseable: true,
            onSelect: { session.selectedTabID = tab.id },
            onClose:  { CommandActions.requestCloseTab(tab.id, in: session) },
            onPin:    { session.togglePinned(tab.id) }
        )
        .id(tab.id)
        .draggable(tab.id.uuidString) {
            TabDragPreview(label: tabLabel(tab))
        }
        .dropDestination(for: String.self) { items, _ -> Bool in
            return handleDrop(items: items, onto: tab.id)
        }
    }

    private func handleDrop(items: [String], onto tabID: UUID) -> Bool {
        guard let raw = items.first,
              let uuid = UUID(uuidString: raw),
              let toIdx = session.tabs.firstIndex(where: { $0.id == tabID })
        else { return false }
        // Same-session: just reorder. Cross-session: detach from
        // source, attach here at the drop location.
        if session.tabs.contains(where: { $0.id == uuid }) {
            session.moveTab(id: uuid, to: toIdx)
        } else if let source = AppStateBus.shared.scenes.session(containing: uuid),
                  source !== session,
                  let tab = source.detachTab(uuid) {
            session.attachTab(tab)
            session.moveTab(id: uuid, to: toIdx)
        }
        return true
    }

    @ViewBuilder
    private var plusButton: some View {
        // Tap → new tab. Long-press → recently-closed list (Safari
        // parity). Implemented as a Menu with a `primaryAction` tap
        // handler so both gestures work without extra plumbing.
        Menu {
            if session.recentlyClosed.isEmpty {
                Text("No Recently Closed Tabs")
            } else {
                Section("Recently Closed") {
                    ForEach(session.recentlyClosed) { record in
                        Button {
                            AppStateBus.shared.scenes.claimFocus(session: session)
                            CommandActions.reopenClosedTab(record)
                        } label: {
                            Label(record.displayName, systemImage: record.fileURL == nil ? "doc.text" : "doc")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
        } primaryAction: {
            // Route through CommandActions so the user-initiated
            // new tab also surfaces the drafts-recovery sheet
            // (max 6 drafts, newest pushes oldest out) — same
            // recovery entry point as ⌘T and ⌘N.
            AppStateBus.shared.scenes.claimFocus(session: session)
            CommandActions.newTab()
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("New Tab")
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var showAllTabsButton: some View {
        Button {
            AppStateBus.shared.scenes.claimFocus(session: session)
            CommandActions.showTabSwitcher()
        } label: {
            Image(systemName: "square.on.square")
                .font(.system(size: 12, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                // 44pt frame to match HIG touch-target sizing so the
                // long-press gesture is easy to land. Icon stays at
                // 12pt visually.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("Show All Tabs")
        .accessibilityLabel("Show All Tabs")
        // Long-press surfaces the multi-tab management menu. Same
        // entries as the iPhone status-bar overview button.
        .contextMenu { TabOverviewContextMenu(session: session) }
    }

    private func tabLabel(_ tab: TabModel) -> String {
        tab.document.fileURL?.lastPathComponent ?? "Untitled"
    }
}

// MARK: - Drag preview

private struct TabDragPreview: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: .capsule)
    }
}

// MARK: - Pill

private struct TabPillView: View {
    @Bindable var tab: TabModel
    let isActive: Bool
    let isCloseable: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onPin: () -> Void

    var body: some View {
        pillContent
            .contentShape(.rect)
            .onTapGesture { onSelect() }
            .contextMenu { contextMenu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var pillContent: some View {
        if tab.isPinned {
            pinnedChip
        } else {
            fullPill
        }
    }

    /// Pinned tab: compact favicon-style chip. No filename text, no
    /// close button — matches Safari's pinned-tab footprint. Long-
    /// press for the context menu to unpin / close.
    @ViewBuilder
    private var pinnedChip: some View {
        Image(systemName: pinnedIconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .frame(width: 36, height: 36)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background { pillBackground }
    }

    @ViewBuilder
    private var fullPill: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            // Spacer pushes the close X to the trailing edge so the
            // pill's background actually fills the equal-width slot
            // its parent gives it. Without this, the HStack would
            // collapse to its content width.
            Spacer(minLength: 0)
            if isCloseable {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Tab")
            }
        }
        .padding(.horizontal, 14)
        // Top padding > bottom so the active tab visually "lifts"
        // out of the bar into the document area below.
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background { pillBackground }
    }

    private var pillBackground: some View {
        // Active tab carries the document's background colour up
        // to the top edge with rounded upper corners; inactive
        // tabs are lighter chips on the bar's strip.
        UnevenRoundedRectangle(
            topLeadingRadius: 8,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 8,
            style: .continuous
        )
        .fill(isActive
              ? Color(.systemBackground)
              : Color(.tertiarySystemBackground))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onPin()
        } label: {
            Label(tab.isPinned ? "Unpin Tab" : "Pin Tab",
                  systemImage: tab.isPinned ? "pin.slash" : "pin")
        }
        if DeviceIdiom.supportsMultipleWindows {
            Button {
                CommandActions.moveTab(tab.id, toNewWindow: true)
            } label: {
                Label("Move Tab to New Window", systemImage: "macwindow.badge.plus")
            }
        }
        Divider()
        Button(role: .destructive, action: onClose) {
            Label("Close This Tab", systemImage: "xmark")
        }
    }

    private var label: String {
        switch tab.kind {
        case .fileBrowser: return "New Tab"
        case .launcher:    return "New"
        case .editor:
            let base = tab.document.displayName
            // Only show the unsaved-dot for genuinely dirty buffers.
            // A brand-new Untitled tab shouldn't claim edits it
            // doesn't have.
            return tab.document.isDirty ? "● \(base)" : base
        }
    }

    private var accessibilityLabel: String {
        let pinned = tab.isPinned ? "Pinned tab. " : ""
        return pinned + label
    }

    /// Pinned-chip glyph: favicon-equivalent. Browser tabs show a
    /// folder; URL-backed editor tabs show a document; unsaved
    /// scratches show a pin.
    private var pinnedIconName: String {
        switch tab.kind {
        case .fileBrowser: return "folder.fill"
        case .launcher:    return "rectangle.stack.badge.plus"
        case .editor:
            return tab.document.fileURL == nil ? "pin.fill" : "doc.text.fill"
        }
    }
}
