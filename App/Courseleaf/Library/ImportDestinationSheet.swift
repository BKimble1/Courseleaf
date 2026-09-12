import SwiftUI
import DocumentCore
import Workspace

/// Where imported files should go: a new notebook in a folder, or inserted
/// into an existing notebook after a chosen page. PDF imports also show the
/// migration note (docs/MIGRATION_FROM_GOODNOTES.md), because flattened
/// handwriting from another app is not editable here.
struct ImportDestinationSheet: View {
    let urls: [URL]
    let defaultFolderID: FolderID?
    let showsMigrationNote: Bool
    var onConfirm: (ImportDestination) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case newNotebook, insert
        var id: String { rawValue }
        var title: String { self == .newNotebook ? "New notebook" : "Insert into a notebook" }
    }

    @State private var mode: Mode = .newNotebook
    @State private var folderID: FolderID? = nil
    @State private var documents: [DocumentSummary] = []
    @State private var targetDocumentID: DocumentID? = nil
    @State private var afterPageIndex: Int = 0
    @State private var isShowingFolderPicker = false
    @State private var folderName = "All Notebooks"
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Files") {
                    ForEach(urls, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: symbol(for: url))
                            .accessibilityLabel(url.lastPathComponent)
                    }
                }

                Section("Destination") {
                    Picker("Destination", selection: $mode) {
                        ForEach(Mode.allCases) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Import destination")

                    if mode == .newNotebook {
                        Button {
                            isShowingFolderPicker = true
                        } label: {
                            LabeledContent("Folder", value: folderName)
                        }
                        .accessibilityHint("Choose the folder the new notebook lands in")
                    } else {
                        if documents.isEmpty {
                            Text("There are no notebooks to insert into yet.").detailTextStyle()
                        } else {
                            Picker("Notebook", selection: $targetDocumentID) {
                                ForEach(documents) { document in
                                    Text(document.title).tag(Optional(document.id))
                                }
                            }
                            .accessibilityLabel("Notebook to insert into")
                            if let target = documents.first(where: { $0.id == targetDocumentID }), target.pageCount > 0 {
                                Stepper(value: $afterPageIndex, in: 0...max(target.pageCount - 1, 0)) {
                                    Text("Insert after page \(afterPageIndex + 1) of \(target.pageCount)")
                                }
                                .accessibilityLabel("Insert position")
                                .accessibilityValue("After page \(afterPageIndex + 1)")
                            }
                        }
                    }
                }

                if showsMigrationNote {
                    Section("Bringing notes from another app") {
                        Text("Everything you can see on the exported pages is kept: handwriting, typed text, images and the original document. Page sizes and order are preserved.")
                        Text("Handwriting in an exported PDF is a picture of the ink. You cannot select, move, recolor or erase those old strokes, and the eraser will not affect them. Anything you write here is fully editable.")
                        Text("Keep your original files and backups from your previous app. Courseleaf does not read other apps' own file formats, so the PDFs are the only copy it can use. Your original files are never changed.")
                    }
                    .font(Typography.detail)
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { confirm() }
                        .disabled(mode == .insert && targetDocumentID == nil)
                }
            }
            .sheet(isPresented: $isShowingFolderPicker) {
                FolderPickerView(title: "Import Into", currentFolderID: folderID) { picked in
                    folderID = picked
                    Task { await refreshFolderName() }
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                folderID = defaultFolderID
                await refreshFolderName()
                documents = await env.perform("The notebooks could not be read") {
                    try await env.library.documents(in: .folder(nil))
                } ?? []
                if targetDocumentID == nil { targetDocumentID = documents.first?.id }
            }
        }
    }

    private func confirm() {
        let destination: ImportDestination
        switch mode {
        case .newNotebook:
            destination = .newNotebook(folderID: folderID, title: nil)
        case .insert:
            guard let targetDocumentID else { return }
            destination = .insert(documentID: targetDocumentID, afterPageIndex: afterPageIndex)
        }
        dismiss()
        onConfirm(destination)
    }

    private func refreshFolderName() async {
        guard let folderID else { folderName = "All Notebooks"; return }
        let manifest = await env.perform("The folders could not be read") { try await env.library.manifest() }
        folderName = manifest?.folder(folderID)?.name ?? "All Notebooks"
    }

    private func symbol(for url: URL) -> String {
        switch ImportSupport.detectKind(of: url) {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .archive: return "shippingbox"
        case .auto: return "doc"
        }
    }
}
