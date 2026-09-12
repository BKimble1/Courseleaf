import SwiftUI
import DocumentCore
import Editing
import Workspace

/// The screen behind an opened notebook: it opens the session (async, and may
/// fail), then hands it to the editor (`NotebookEditorView`, Editor/). The
/// session stays open in `AppEnvironment` until the notebook is closed, so
/// reopening it never builds a second editor over the same package.
struct NotebookScreen: View {
    let target: AppRouter.NotebookTarget

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var session: (any DocumentSessioning)? = nil
    @State private var summary: DocumentSummary? = nil
    @State private var loadError: String? = nil

    var body: some View {
        content
            .navigationTitle(summary?.title ?? "Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .onDisappear { Task { await flush() } }
    }

    @ViewBuilder
    private var content: some View {
        if let session {
            NotebookEditorView(session: session,
                               initialPageID: initialPageID(in: session),
                               environment: env)
        } else if let loadError {
            ContentUnavailableView {
                Label("This notebook could not be opened", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Back to Library") { dismiss() }
            }
        } else {
            ProgressView("Opening…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Opening the notebook")
        }
    }

    /// The page the caller asked for (a search hit, a review item); nil lets the
    /// editor restore the page the student was last on.
    private func initialPageID(in session: any DocumentSessioning) -> PageID? {
        guard let index = target.pageIndex else { return nil }
        let ids = session.editor.snapshot.document.pageIDs
        return ids.indices.contains(index) ? ids[index] : nil
    }

    private func load() async {
        guard session == nil else { return }
        do {
            let opened = try await env.session(for: target.documentID)
            session = opened
            summary = try? await env.library.document(target.documentID)
        } catch {
            loadError = AppErrorText.message(for: error)
        }
    }

    private func flush() async {
        guard let session else { return }
        do {
            try await session.flush()
        } catch {
            env.present(error, title: "This notebook could not be saved")
        }
        env.noteLibraryChanged()
    }
}
