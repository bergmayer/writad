import SwiftUI

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

    /// Refreshed on each appear — the user may have deleted a draft
    /// in another window or saved one out of the recovery pool.
    @State private var templates: [TemplateRecord] = []
    @State private var drafts: [DraftRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                openExistingSection
                templatesSection
                draftsSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear(perform: refresh)
    }

    private func refresh() {
        templates = TemplatesStore.shared.loadAll()
        drafts = DraftsStore.shared.loadAll()
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
                            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                                .font(.body.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("Untitled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
        let when = draft.modified.formatted(date: .abbreviated, time: .shortened)
        let suffix = draft.metadata?.sourceDisplay == nil ? "" : " · was open file"
        return "\(size) · \(when)\(suffix)"
    }

    // MARK: Open existing

    @ViewBuilder
    private var openExistingSection: some View {
        Button(action: onPickOpenFile) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open File…")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("Browse the Files app for an existing document.")
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
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
