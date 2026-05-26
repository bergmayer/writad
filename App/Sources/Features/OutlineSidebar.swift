import SwiftUI

/// Inline left-edge navigation sidebar. Shows the active document's
/// Markdown headings (H1–H6 with indent by level) for quick jumping.
/// Slides in from the leading edge when `EditorState.sidebarOpen`
/// flips. This is the single outline surface in the app —
/// "Show Outline" (⌥⌘O) opens this same sidebar; there is no
/// separate outline sheet anymore.
struct OutlineSidebar: View {

    @Bindable var state: EditorState
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 260)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .foregroundStyle(.secondary)
            Text("Outline")
                .font(.headline)
            Spacer()
            Button {
                AppStateBus.shared.scenes.claimFocus(state: state)
                CommandActions.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let entries = OutlineBuilder.build()
        let filtered = filter(entries)
        if entries.isEmpty {
            ContentUnavailableView(
                "No headings",
                systemImage: "list.bullet.indent",
                description: Text("Add Markdown headings (# Title) or fold-marker comments to populate the outline.")
            )
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            VStack(spacing: 0) {
                searchField
                Divider()
                List {
                    ForEach(filtered) { entry in
                        Button {
                            jump(to: entry)
                        } label: {
                            HStack(spacing: 6) {
                                Text(String(repeating: "  ", count: max(0, entry.level - 1)))
                                Text(entry.text)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("H\(entry.level)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter headings", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func filter(_ entries: [OutlineBuilder.Heading]) -> [OutlineBuilder.Heading] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.lowercased().contains(q) }
    }

    private func jump(to heading: OutlineBuilder.Heading) {
        guard let textView = state.textView else { return }
        textView.setSelection(NSRange(location: heading.lineStart, length: 0))
        textView.scrollSelectionToVisible()
    }
}
