import SwiftUI
import UIKit

/// Document-shell launcher rendered as a tab's content. Every blank
/// tab/window starts here — the user must either pick a template,
/// resume an unsaved draft, or import an existing file. There is no
/// "blank document" path that skips this surface, which is exactly
/// the point: the user always has a way to recover work and a way
/// to seed a new buffer with structure.
struct NewDocumentLauncherView: View {

    let onPickTemplate: (TemplateRecord) -> Void
    let onPickDraft: (DraftRecord) -> Void
    let onPickOpenFile: () -> Void
    /// Seeds a fresh editor tab with the system pasteboard contents.
    /// Disabled when the pasteboard has no string payload.
    let onPickClipboard: (String) -> Void
    /// Closes this launcher surface without picking anything. The
    /// scene routes it to the same close path as ⌘W — if this is
    /// the only tab the window stays open with another launcher
    /// taking its place.
    let onCancel: () -> Void
    /// `false` when this launcher is filling the window's empty
    /// state (no real tabs left) — there's nothing meaningful to
    /// cancel back to, so the Cancel chip is hidden.
    let showsCancel: Bool

    /// Refreshed on each appear — the user may have deleted a draft
    /// in another window or saved one out of the recovery pool.
    @State private var templates: [TemplateRecord] = []
    @State private var drafts: [DraftRecord] = []
    /// Snapshot of `UIPasteboard.general.hasStrings` at refresh time
    /// so the "From Clipboard" row can disable itself when there's
    /// nothing to paste.
    @State private var hasClipboardText: Bool = false

    var body: some View {
        // Outer wash sets the chrome backdrop; the actual launcher
        // floats as a centered card with its own padding so the
        // surface feels contained within the tab rather than
        // taking over the whole pane.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                openExistingSection
                templatesSection
                draftsSection
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Tab")
                    .font(.title2.weight(.semibold))
                Text("Pick a template, resume a draft, or open an existing file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if showsCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func refresh() {
        templates = TemplatesStore.shared.loadAll()
        drafts = DraftsStore.shared.loadAll()
        hasClipboardText = UIPasteboard.general.hasStrings
    }

    // MARK: Templates

    @ViewBuilder
    private var templatesSection: some View {
        sectionHeader("Templates", systemImage: "doc.badge.plus")
        if templates.isEmpty {
            emptyCard(
                "No templates yet",
                detail: "Drop files into the Documents/Templates folder via Files.app to add your own."
            )
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                spacing: 12
            ) {
                ForEach(templates) { template in
                    Button {
                        onPickTemplate(template)
                    } label: {
                        templateCard(template)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func templateCard(_ template: TemplateRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: template.symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(template.url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
    }

    // MARK: Drafts

    @ViewBuilder
    private var draftsSection: some View {
        sectionHeader("Unsaved Drafts", systemImage: "doc.badge.clock")
        if drafts.isEmpty {
            emptyCard(
                "Nothing to recover",
                detail: "Unsaved buffers from earlier sessions show up here so you can pick one up where you left off."
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    draftRow(draft)
                    if index < drafts.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func draftRow(_ draft: DraftRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                onPickDraft(draft)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: draft.metadata?.sourceDisplay == nil
                          ? "doc.badge.clock"
                          : "arrow.uturn.backward.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        if let display = draft.metadata?.sourceDisplay {
                            Text(display)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            // Untitled drafts have no filename to lead
                            // with; the saved timestamp doubles as a
                            // de-facto name so two same-day drafts are
                            // distinguishable in the launcher list.
                            Text(untitledTitle(for: draft))
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(metadataLine(for: draft))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                DraftsStore.shared.discard(draft.url)
                drafts.removeAll { $0.id == draft.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard draft")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func metadataLine(for draft: DraftRecord) -> String {
        let size = draft.bytes.formatted(.byteCount(style: .file))
        // URL-backed drafts keep the timestamp here; Untitled rows
        // have already promoted it into the title so we drop the
        // duplicate to keep the row scannable.
        if draft.metadata?.sourceDisplay == nil {
            return size
        }
        let when = draft.modified.formatted(date: .abbreviated, time: .shortened)
        return "\(size) · \(when) · was open file"
    }

    private func untitledTitle(for draft: DraftRecord) -> String {
        let when = draft.modified.formatted(date: .abbreviated, time: .shortened)
        return "Untitled — \(when)"
    }

    // MARK: Open existing

    @ViewBuilder
    private var openExistingSection: some View {
        VStack(spacing: 0) {
            openFileRow
            Divider().padding(.leading, 54)
            clipboardRow
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var openFileRow: some View {
        Button(action: onPickOpenFile) {
            actionRow(
                symbol: "folder",
                title: "Open File…",
                detail: "Browse the Files app for an existing document.",
                enabled: true
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var clipboardRow: some View {
        Button {
            // Read live at tap time — `hasClipboardText` only gates
            // the row's enabled state; the actual bytes may differ
            // if another app copied something between refresh and
            // the user's tap.
            guard let text = UIPasteboard.general.string,
                  !text.isEmpty else { return }
            onPickClipboard(text)
        } label: {
            actionRow(
                symbol: "doc.on.clipboard",
                title: "From Clipboard",
                detail: hasClipboardText
                    ? "Start a tab seeded with the current clipboard text."
                    : "Copy text in any app, then come back here.",
                enabled: hasClipboardText
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasClipboardText)
    }

    @ViewBuilder
    private func actionRow(symbol: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: Shared chrome

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    @ViewBuilder
    private func emptyCard(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
