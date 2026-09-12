import SwiftUI
import DocumentCore
import Workspace

/// Search across the library, a folder or the open notebook.
struct SearchView: View {
    let initialScope: SearchScope

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model = SearchViewModel()
    @State private var scopeChoice: ScopeChoice = .library

    enum ScopeChoice: String, CaseIterable, Identifiable {
        case library, folder, notebook
        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: return "Library"
            case .folder: return "This folder"
            case .notebook: return "This notebook"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Search in", selection: $scopeChoice) {
                    ForEach(availableChoices) { choice in Text(choice.title).tag(choice) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityLabel("Search scope")
                .onChange(of: scopeChoice) { _, _ in
                    model.scope = scope(for: scopeChoice)
                    model.search()
                }

                List {
                    if let reason = model.unavailableReason {
                        Section {
                            Text("The search index is unavailable: \(reason)")
                                .detailTextStyle()
                            Text("Your notebooks are not affected. You can rebuild the index in Settings › Storage.")
                                .detailTextStyle()
                        }
                    }

                    if model.notYetIndexedCount > 0 || model.failedCount > 0 || model.isIndexing {
                        Section {
                            if model.notYetIndexedCount > 0 {
                                Label("\(model.notYetIndexedCount) page\(model.notYetIndexedCount == 1 ? "" : "s") not yet indexed",
                                      systemImage: "clock.arrow.circlepath")
                                    .detailTextStyle()
                            }
                            if model.failedCount > 0 {
                                Label("\(model.failedCount) page\(model.failedCount == 1 ? "" : "s") failed to index",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(Palette.warning)
                            }
                            if model.isIndexing {
                                Label("Indexing is still running in the background", systemImage: "arrow.triangle.2.circlepath")
                                    .detailTextStyle()
                            }
                        }
                    }

                    if model.groups.isEmpty {
                        Section { emptyState }
                    }

                    ForEach(model.groups) { group in
                        Section(group.documentTitle) {
                            ForEach(group.hits) { hit in
                                Button {
                                    open(hit)
                                } label: {
                                    SearchHitRow(hit: hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: Binding(get: { model.query }, set: { model.query = $0; model.search() }),
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Titles, typed text, PDF text and handwriting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                model.configure(env: env)
                model.scope = initialScope
                scopeChoice = choice(for: initialScope)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            Text("Searching…").detailTextStyle()
        } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Type to search").font(Typography.sectionTitle)
                Text("Titles and typed text are indexed as you write. PDF text and handwriting are indexed in the background, on this iPad.")
                    .detailTextStyle()
            }
        } else if model.hasSearched && model.notYetIndexedCount > 0 && model.groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No matches yet").font(Typography.sectionTitle)
                Text("\(model.notYetIndexedCount) page\(model.notYetIndexedCount == 1 ? "" : "s") in this scope have not been indexed yet, so there may be more to find once recognition finishes.")
                    .detailTextStyle()
            }
        } else if model.hasSearched {
            VStack(alignment: .leading, spacing: 6) {
                Text("No matches").font(Typography.sectionTitle)
                Text("Nothing in this scope matches “\(model.query)”. Everything here has been indexed.")
                    .detailTextStyle()
            }
        }
    }

    private var availableChoices: [ScopeChoice] {
        var choices: [ScopeChoice] = [.library]
        if case .folder = env.router.sidebar { choices.append(.folder) }
        if env.router.openNotebookID != nil { choices.append(.notebook) }
        return choices
    }

    private func scope(for choice: ScopeChoice) -> SearchScope {
        switch choice {
        case .library:
            return .library
        case .folder:
            if case .folder(let id) = env.router.sidebar, let id { return .folder(id) }
            return .library
        case .notebook:
            if let id = env.router.openNotebookID { return .document(id) }
            return .library
        }
    }

    private func choice(for scope: SearchScope) -> ScopeChoice {
        switch scope {
        case .library: return .library
        case .folder: return .folder
        case .document: return .notebook
        }
    }

    private func open(_ hit: SearchHit) {
        dismiss()
        env.router.openNotebook(hit.documentID, pageIndex: hit.pageIndex, highlight: hit.bounds)
    }
}

/// One hit: the snippet, the page and what kind of text matched.
struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(SearchKindText.title(hit.kind)).badgeStyle(tint)
                Text("Page \(hit.pageIndex + 1)").detailTextStyle()
            }
            Text(hit.snippet.isEmpty ? "(no preview)" : hit.snippet)
                .font(Typography.body)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SearchKindText.title(hit.kind)) match on page \(hit.pageIndex + 1): \(hit.snippet)")
        .accessibilityHint(SearchKindText.hint(hit.kind) + ". Double tap to open the page.")
    }

    private var tint: Color {
        switch hit.kind {
        case .title: return Palette.accent
        case .typed: return Palette.success
        case .pdfText: return Palette.secondaryText
        case .recognized: return Palette.warning
        }
    }
}
