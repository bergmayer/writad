import SwiftUI

/// Launch-time recovery for unsaved buffers. Recovered tabs come
/// back Untitled + dirty so the "edited" subtitle stays on.
/// "Keep" leaves the draft on disk for the next session; "Discard"
/// deletes it.
struct DraftsRecoverySheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [DraftRecord] = []
    @State private var confirmingDeleteAll: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    ContentUnavailableView(
                        "No drafts to recover",
                        systemImage: "doc.badge.clock",
                        description: Text("Untitled drafts from previous sessions show up here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(drafts) { draft in
                                row(for: draft)
                            }
                        } footer: {
                            Text("Drafts are kept until you save the buffer to a real file or tap Discard. Tap a row to open it as a new Untitled tab with the bytes already loaded.")
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Recover Unsaved Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep") { dismiss() }
                }
                if !drafts.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open All") {
                            let toOpen = drafts
                            dismiss()
                            Task { @MainActor in
                                try? await Task.sleep(for: Timing.paletteHandoff)
                                for draft in toOpen {
                                    CommandActions.recoverDraft(draft)
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", role: .destructive) {
                            confirmingDeleteAll = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all \(drafts.count) draft\(drafts.count == 1 ? "" : "s")?",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    for draft in drafts {
                        DraftsStore.shared.discard(draft.url)
                    }
                    drafts.removeAll()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Deleted drafts cannot be recovered.")
            }
            .onAppear { drafts = DraftsStore.shared.loadAll() }
        }
    }

    @ViewBuilder
    private func row(for draft: DraftRecord) -> some View {
        HStack(spacing: 10) {
            Button {
                let target = draft
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: Timing.paletteHandoff)
                    CommandActions.recoverDraft(target)
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        // URL-backed drafts lead with the source path
                        // — "Notes / ideas.md" reads better than the
                        // first 80 chars of the buffer. Untitled
                        // drafts flip back to preview-on-top.
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
                                .lineLimit(2)
                        }
                        Text("\(draft.bytes.formatted(.byteCount(style: .file))) · \(draft.modified.formatted(date: .abbreviated, time: .shortened))\(draft.metadata?.sourceDisplay == nil ? "" : " · was open file")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // Explicit × is more discoverable than swipe (especially
            // on iPad). No per-row confirm — if the user thought
            // the draft was valuable they'd have tapped Recover.
            // Bulk Delete All gates behind a confirmation dialog.
            Button {
                DraftsStore.shared.discard(draft.url)
                drafts.removeAll { $0.id == draft.id }
                if drafts.isEmpty { dismiss() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard draft")
        }
        .swipeActions {
            Button("Discard", role: .destructive) {
                DraftsStore.shared.discard(draft.url)
                drafts.removeAll { $0.id == draft.id }
                if drafts.isEmpty { dismiss() }
            }
        }
    }
}
