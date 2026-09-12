import SwiftUI
import UniformTypeIdentifiers
import DocumentCore
import Workspace

/// The library's content column: notebooks in the selected scope as a grid or
/// a list, with creation, import and per-notebook actions.
struct LibraryContentView: View {
    let selection: AppRouter.SidebarSelection

    @Environment(AppEnvironment.self) private var env
    @State private var model = LibraryViewModel()
    @State private var renameTarget: DocumentSummary? = nil
    @State private var renameText = ""
    @State private var moveTarget: DocumentSummary? = nil
    @State private var coverTarget: DocumentSummary? = nil
    @State private var isShowingFileImporter = false
    @State private var pickedURLs: [URL] = []
    @State private var isShowingImportDestination = false
    @State private var importSummary: String? = nil

    private var scope: LibraryScope { selection.libraryScope ?? .folder(nil) }

    private var folder: Folder? {
        guard case .folder(let id) = selection, let id, let manifest = model.manifest else { return nil }
        return manifest.folder(id)
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .task(id: taskID) { await reload() }
            .onChange(of: env.router.quickCaptureRequests) { _, _ in Task { await quickCapture() } }
            .sheet(isPresented: newNotebookBinding) {
                NewNotebookSheet(folderID: selection.destinationFolderID) { id in
                    env.router.openNotebook(id)
                }
            }
            .sheet(item: $moveTarget) { document in
                FolderPickerView(title: "Move \(document.title)", currentFolderID: document.folderID) { folderID in
                    Task { await model.move(document, toFolder: folderID); await reload() }
                }
            }
            .sheet(item: $coverTarget) { document in
                CoverPickerSheet(title: document.title, cover: document.cover) { cover in
                    Task { await model.setCover(document, cover); await reload() }
                }
            }
            .sheet(isPresented: $isShowingImportDestination) {
                ImportDestinationSheet(urls: pickedURLs,
                                       defaultFolderID: selection.destinationFolderID,
                                       showsMigrationNote: model.containsPDF(pickedURLs)) { destination in
                    Task { await runImport(destination: destination) }
                }
            }
            .fileImporter(isPresented: $isShowingFileImporter,
                          allowedContentTypes: ImportSupport.importableTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    pickedURLs = urls
                    isShowingImportDestination = !urls.isEmpty
                case .failure(let error):
                    env.present(error, title: "Those files could not be opened")
                }
            }
            .alert("Rename Notebook", isPresented: Binding(get: { renameTarget != nil },
                                                           set: { if !$0 { renameTarget = nil } })) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Rename") {
                    if let document = renameTarget {
                        let title = renameText
                        Task { await model.rename(document, to: title); await reload() }
                    }
                    renameTarget = nil
                }
            }
            .alert("Imported", isPresented: Binding(get: { importSummary != nil },
                                                    set: { if !$0 { importSummary = nil } })) {
                Button("OK") { importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if case .inbox = selection { inboxNote }
                if let progress = model.importProgress { importProgressView(progress) }
                if !model.folders.isEmpty { folderSection }
                if model.documents.isEmpty {
                    emptyState
                } else if model.presentation == .grid {
                    grid
                } else {
                    list
                }
            }
            .padding(20)
        }
        .background(Palette.windowBackground)
        .overlay(alignment: .bottom) { quickCaptureButton }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 18)], alignment: .leading, spacing: 22) {
            ForEach(model.sortedDocuments) { document in
                NotebookCard(document: document) { action in perform(action, on: document) }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.sortedDocuments) { document in
                NotebookRow(document: document) { action in perform(action, on: document) }
                    .padding(.vertical, 8)
                Divider()
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 4)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders").font(Typography.sectionTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(model.folders) { summary in
                    Button {
                        env.router.sidebar = .folder(summary.folder.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: summary.folder.isCourse ? "graduationcap.fill" : "folder.fill")
                                .foregroundStyle(Color(Palette.tones(for: summary.folder.color).base))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.folder.name).cardTitleStyle()
                                Text("\(summary.documentCount) notebook\(summary.documentCount == 1 ? "" : "s")")
                                    .detailTextStyle()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(summary.folder.name), \(summary.documentCount) notebooks")
                    .accessibilityHint("Double tap to open the folder")
                }
            }
        }
    }

    private var inboxNote: some View {
        Text("Quick notes land here until you file them. Use “File This Note…” on a note to move it into a course or folder.")
            .detailTextStyle()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(Palette.tertiaryText)
            Text(emptyTitle).font(Typography.sectionTitle)
            Text(emptyMessage).detailTextStyle().multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyTitle: String {
        switch selection {
        case .recents: return "Nothing opened yet"
        case .favorites: return "No favorites yet"
        case .inbox: return "No quick notes"
        default: return "No notebooks here"
        }
    }

    private var emptyMessage: String {
        switch selection {
        case .recents: return "Notebooks you open show up here."
        case .favorites: return "Mark a notebook as a favorite to find it quickly."
        case .inbox: return "Quick Note creates a note in one tap. It stays here until you file it."
        default: return "Create a notebook, or import a PDF, image or Courseleaf archive."
        }
    }

    private func importProgressView(_ progress: ImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.message).detailTextStyle()
            ProgressView(value: Double(progress.completedUnits), total: Double(max(progress.totalUnits, 1)))
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing")
        .accessibilityValue(progress.message)
    }

    private var quickCaptureButton: some View {
        Button {
            Task { await quickCapture() }
        } label: {
            Label("Quick Note", systemImage: "square.and.pencil")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.accent, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(20)
        .handedAligned(leftHanded: env.settings.leftHanded)
        .accessibilityLabel("Quick note")
        .accessibilityHint("Creates a note with your default paper and opens it straight away")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: HandedLayout.primaryPlacement(leftHanded: env.settings.leftHanded)) {
            if let folder, folder.isCourse {
                NavigationLink {
                    ReviewQueueView(courseID: folder.id)
                } label: {
                    Label("Review Queue", systemImage: "checkmark.circle")
                }
            }
            Button {
                env.router.showSearch(scope: searchScope)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)

            Button {
                isShowingFileImporter = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .accessibilityHint("Import a PDF, PNG, JPEG or Courseleaf archive")

            Button {
                env.router.isShowingNewNotebook = true
            } label: {
                Label("New Notebook", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        ToolbarItemGroup(placement: HandedLayout.secondaryPlacement(leftHanded: env.settings.leftHanded)) {
            Picker("View", selection: Binding(get: { model.presentation }, set: { model.presentation = $0 })) {
                ForEach(LibraryViewModel.Presentation.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Layout")
            .accessibilityValue(model.presentation.title)

            Menu {
                Picker("Sort By", selection: Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })) {
                    ForEach(LibraryViewModel.SortOrder.allCases) { order in
                        Label(order.title, systemImage: order.symbol).tag(order)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort")
            .accessibilityValue(model.sortOrder.title)
        }
    }

    // MARK: Actions

    private var title: String {
        if let folder { return folder.name }
        return selection.title
    }

    private var taskID: String { "\(env.libraryRevision)-\(String(describing: selection))" }

    private var searchScope: SearchScope {
        if case .folder(let id) = selection, let id { return .folder(id) }
        return .library
    }

    private var newNotebookBinding: Binding<Bool> {
        Binding(get: { env.router.isShowingNewNotebook }, set: { env.router.isShowingNewNotebook = $0 })
    }

    private func reload() async {
        model.configure(env: env)
        await model.load(scope: scope)
    }

    private func perform(_ action: NotebookAction, on document: DocumentSummary) {
        switch action {
        case .open:
            if document.needsNewerApp {
                env.present(title: "This notebook needs a newer app",
                            message: "It was made with a newer version of Courseleaf. Update the app to open it. Nothing was changed.")
            } else {
                env.router.openNotebook(document.id)
            }
        case .rename:
            renameText = document.title
            renameTarget = document
        case .move, .fileNote:
            moveTarget = document
        case .duplicate:
            Task { await model.duplicate(document); await reload() }
        case .toggleFavorite:
            Task { await model.setFavorite(document, !document.isFavorite); await reload() }
        case .changeCover:
            coverTarget = document
        case .delete:
            Task { await model.delete(document); await reload() }
        }
    }

    private func quickCapture() async {
        await reload()
        guard let id = await model.createQuickNote(template: env.settings.defaultTemplate) else { return }
        env.router.openNotebook(id)
    }

    private func runImport(destination: ImportDestination) async {
        let urls = pickedURLs
        pickedURLs = []
        guard let result = await model.importFiles(urls: urls, destination: destination) else { return }
        await reload()
        var lines: [String] = []
        if !result.createdDocumentIDs.isEmpty {
            lines.append("Created \(result.createdDocumentIDs.count) notebook\(result.createdDocumentIDs.count == 1 ? "" : "s").")
        }
        if !result.insertedPageIDs.isEmpty {
            lines.append("Inserted \(result.insertedPageIDs.count) page\(result.insertedPageIDs.count == 1 ? "" : "s").")
        }
        lines += result.warnings
        lines.append("Your original files were not changed.")
        importSummary = lines.joined(separator: "\n")
        if let first = result.createdDocumentIDs.first, result.createdDocumentIDs.count == 1 {
            env.router.openNotebook(first)
        }
    }
}
