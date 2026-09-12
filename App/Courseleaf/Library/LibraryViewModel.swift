import Foundation
import Observation
import SwiftUI
import DocumentCore
import Workspace

/// Drives the library listing: what is in the selected scope, how it is sorted
/// and every action a notebook or folder offers. Every call into the library is
/// async and may throw; failures become alerts, never crashes.
@MainActor
@Observable
final class LibraryViewModel {
    enum SortOrder: String, CaseIterable, Identifiable {
        case modified, created, title, pageCount

        var id: String { rawValue }

        var title: String {
            switch self {
            case .modified: return "Last Modified"
            case .created: return "Date Created"
            case .title: return "Title"
            case .pageCount: return "Page Count"
            }
        }

        var symbol: String {
            switch self {
            case .modified: return "clock"
            case .created: return "calendar"
            case .title: return "textformat"
            case .pageCount: return "doc.on.doc"
            }
        }
    }

    enum Presentation: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
        var title: String { self == .grid ? "Grid" : "List" }
        var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    private(set) var documents: [DocumentSummary] = []
    private(set) var folders: [FolderSummary] = []
    private(set) var manifest: LibraryManifest?
    private(set) var isLoading = false
    var sortOrder: SortOrder = .modified
    var presentation: Presentation = .grid
    /// Progress of a running import, nil when none is running.
    var importProgress: ImportProgress?

    @ObservationIgnored private weak var env: AppEnvironment?

    func configure(env: AppEnvironment) {
        if self.env !== env { self.env = env }
    }

    private var library: (any LibraryServicing)? { env?.library }

    // MARK: Loading

    func load(scope: LibraryScope) async {
        guard let env, let library else { return }
        isLoading = true
        defer { isLoading = false }
        documents = await env.perform("The library could not be read") {
            try await library.documents(in: scope)
        } ?? []
        if case .folder(let folderID) = scope {
            folders = await env.perform("The folders could not be read") {
                try await library.folders(in: folderID)
            } ?? []
        } else {
            folders = []
        }
        manifest = await env.perform("The library could not be read") {
            try await library.manifest()
        }
    }

    /// Documents in the order the student chose.
    var sortedDocuments: [DocumentSummary] {
        switch sortOrder {
        case .modified: return documents.sorted { $0.modifiedAt > $1.modifiedAt }
        case .created: return documents.sorted { $0.createdAt > $1.createdAt }
        case .title: return documents.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .pageCount: return documents.sorted { $0.pageCount > $1.pageCount }
        }
    }

    // MARK: Notebooks

    func createNotebook(title: String, folderID: FolderID?, template: PaperTemplate, pageSize: PageSize,
                        cover: CoverStyle, pageCount: Int = 1) async -> DocumentID? {
        guard let env, let library else { return nil }
        let id = await env.perform("The notebook could not be created") {
            try await library.createNotebook(title: title, folderID: folderID, template: template,
                                             pageSize: pageSize, cover: cover, pageCount: max(1, pageCount))
        }
        if id != nil { env.noteLibraryChanged() }
        return id
    }

    func createQuickNote(template: PaperTemplate) async -> DocumentID? {
        guard let env, let library else { return nil }
        let id = await env.perform("The quick note could not be created") {
            try await library.createQuickNote(template: template)
        }
        if id != nil { env.noteLibraryChanged() }
        return id
    }

    func rename(_ document: DocumentSummary, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let env, let library, !trimmed.isEmpty else { return }
        await env.perform("The notebook could not be renamed") { try await library.rename(document.id, to: trimmed) }
        env.noteLibraryChanged()
    }

    func move(_ document: DocumentSummary, toFolder folderID: FolderID?) async {
        guard let env, let library else { return }
        await env.perform("The notebook could not be moved") { try await library.move(document.id, toFolder: folderID) }
        env.noteLibraryChanged()
    }

    @discardableResult
    func duplicate(_ document: DocumentSummary) async -> DocumentID? {
        guard let env, let library else { return nil }
        let id = await env.perform("The notebook could not be duplicated") { try await library.duplicate(document.id) }
        env.noteLibraryChanged()
        return id
    }

    func setFavorite(_ document: DocumentSummary, _ isFavorite: Bool) async {
        guard let env, let library else { return }
        await env.perform("That could not be changed") { try await library.setFavorite(document.id, isFavorite) }
        env.noteLibraryChanged()
    }

    func setCover(_ document: DocumentSummary, _ cover: CoverStyle) async {
        guard let env, let library else { return }
        await env.perform("The cover could not be changed") { try await library.setCover(document.id, cover) }
        env.noteLibraryChanged()
    }

    func delete(_ document: DocumentSummary) async {
        guard let env, let library else { return }
        await env.closeSession(document.id)
        await env.perform("The notebook could not be moved to the trash") { try await library.delete(document.id) }
        env.noteLibraryChanged()
    }

    // MARK: Folders and courses

    @discardableResult
    func createFolder(name: String, parentID: FolderID?, isCourse: Bool) async -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let env, let library, !trimmed.isEmpty else { return nil }
        let folder = await env.perform(isCourse ? "The course could not be created" : "The folder could not be created") {
            try await library.createFolder(name: trimmed, parentID: parentID, isCourse: isCourse)
        }
        env.noteLibraryChanged()
        return folder
    }

    func rename(_ folder: Folder, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let env, let library, !trimmed.isEmpty else { return }
        var updated = folder
        updated.name = trimmed
        await env.perform("The folder could not be renamed") { try await library.updateFolder(updated) }
        env.noteLibraryChanged()
    }

    func deleteFolder(_ folder: Folder) async {
        guard let env, let library else { return }
        await env.perform("The folder could not be moved to the trash") { try await library.deleteFolder(folder.id) }
        env.noteLibraryChanged()
    }

    // MARK: Import

    /// Stages the picked files (security-scoped access ends with the picker),
    /// then imports them. A failure leaves the library untouched.
    @discardableResult
    func importFiles(urls: [URL], destination: ImportDestination) async -> ImportResult? {
        guard let env, let library, !urls.isEmpty else { return nil }
        importProgress = ImportProgress(completedUnits: 0, totalUnits: urls.count + 1, message: "Preparing…")
        defer { importProgress = nil }
        let requests = ImportSupport.requests(forPickedURLs: urls)
        let staged: (requests: [ImportRequest], staging: URL)
        do {
            staged = try SecurityScopedFileAccess.prepareForImport(requests)
        } catch {
            env.present(error, title: "Those files could not be read")
            return nil
        }
        defer { SecurityScopedFileAccess.discardStaging(staged.staging) }
        let result = await env.perform("The import did not finish") {
            try await library.importFiles(staged.requests, destination: destination) { progress in
                Task { @MainActor [weak self] in self?.importProgress = progress }
            }
        }
        env.noteLibraryChanged()
        return result
    }

    /// True when at least one picked file is a PDF, so the migration note is shown.
    func containsPDF(_ urls: [URL]) -> Bool {
        urls.contains { ImportSupport.detectKind(of: $0) == .pdf }
    }
}
