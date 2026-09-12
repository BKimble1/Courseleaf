import SwiftUI
import DocumentCore
import Workspace

/// Deleted notebooks and folders, with restore, delete permanently and empty.
struct TrashView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var entries: [TrashSummary] = []
    @State private var isLoading = false
    @State private var purgeTarget: TrashSummary? = nil
    @State private var isConfirmingEmpty = false

    var body: some View {
        List {
            Section {
                Text("Deleted notebooks and folders stay here until you empty the trash. Nothing is removed from disk before that.")
                    .detailTextStyle()
            }
            if entries.isEmpty && !isLoading {
                Text("The trash is empty.").detailTextStyle()
            }
            ForEach(entries) { summary in
                row(summary)
            }
        }
        .navigationTitle("Trash")
        .toolbar {
            ToolbarItem(placement: HandedLayout.primaryPlacement(leftHanded: env.settings.leftHanded)) {
                Button(role: .destructive) {
                    isConfirmingEmpty = true
                } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
                .disabled(entries.isEmpty)
                .accessibilityHint("Permanently removes everything in the trash")
            }
        }
        .task(id: env.libraryRevision) { await reload() }
        .confirmationDialog("Empty the trash?", isPresented: $isConfirmingEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { Task { await emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the trash is deleted permanently. This cannot be undone.")
        }
        .confirmationDialog("Delete permanently?",
                            isPresented: Binding(get: { purgeTarget != nil }, set: { if !$0 { purgeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let target = purgeTarget { Task { await purge(target) } }
                purgeTarget = nil
            }
            Button("Cancel", role: .cancel) { purgeTarget = nil }
        } message: {
            Text("\(purgeTarget?.entry.title ?? "This item") is removed from this iPad and cannot be recovered.")
        }
    }

    private func row(_ summary: TrashSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: summary.entry))
                .foregroundStyle(Palette.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.entry.title).cardTitleStyle()
                Text("Deleted \(DateText.modified(summary.entry.deletedAt))\(detail(for: summary.entry))")
                    .detailTextStyle()
            }
            Spacer(minLength: 8)
            Button("Restore") { Task { await restore(summary) } }
                .buttonStyle(.bordered)
                .accessibilityHint("Puts it back where it was")
            Button(role: .destructive) {
                purgeTarget = summary
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete permanently")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.entry.title), deleted \(DateText.modified(summary.entry.deletedAt))")
    }

    private func icon(for entry: TrashEntry) -> String {
        switch entry.item {
        case .document: return "book.closed"
        case .folder: return "folder"
        }
    }

    private func detail(for entry: TrashEntry) -> String {
        switch entry.item {
        case .document: return ""
        case .folder(_, let documentIDs):
            return documentIDs.isEmpty ? " · folder" : " · folder with \(documentIDs.count) notebook\(documentIDs.count == 1 ? "" : "s")"
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        entries = await env.perform("The trash could not be read") { try await env.library.trashEntries() } ?? []
    }

    private func restore(_ summary: TrashSummary) async {
        await env.perform("That could not be restored") { try await env.library.restore(trashEntryID: summary.entry.id) }
        env.noteLibraryChanged()
        await reload()
    }

    private func purge(_ summary: TrashSummary) async {
        await env.perform("That could not be deleted") { try await env.library.purge(trashEntryID: summary.entry.id) }
        env.noteLibraryChanged()
        await reload()
    }

    private func emptyTrash() async {
        await env.perform("The trash could not be emptied") { try await env.library.emptyTrash() }
        env.noteLibraryChanged()
        await reload()
    }
}
