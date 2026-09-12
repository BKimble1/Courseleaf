import SwiftUI
import DocumentCore
import Workspace

/// Picks a destination folder (or the library root) for a move or an import.
struct FolderPickerView: View {
    let title: String
    let currentFolderID: FolderID?
    var onPick: (FolderID?) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: LibraryManifest? = nil
    @State private var selected: FolderID? = nil
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(name: "All Notebooks (no folder)", symbol: "books.vertical", id: nil, isCourse: false, depth: 0)
                }
                if let manifest, !manifest.folders.isEmpty {
                    Section("Folders") {
                        ForEach(flattened(manifest), id: \.folder.id) { entry in
                            row(name: entry.folder.name, symbol: entry.folder.isCourse ? "graduationcap.fill" : "folder",
                                id: entry.folder.id, isCourse: entry.folder.isCourse, depth: entry.depth)
                        }
                    }
                } else {
                    Text("No folders yet. Create one in the sidebar.").detailTextStyle()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Here") { onPick(selected); dismiss() }
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                selected = currentFolderID
                manifest = await env.perform("The folders could not be read") { try await env.library.manifest() }
            }
        }
    }

    private struct Entry {
        var folder: Folder
        var depth: Int
    }

    private func flattened(_ manifest: LibraryManifest, parent: FolderID? = nil, depth: Int = 0) -> [Entry] {
        manifest.folders
            .filter { $0.parentID == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { folder -> [Entry] in
                [Entry(folder: folder, depth: depth)] + flattened(manifest, parent: folder.id, depth: depth + 1)
            }
    }

    private func row(name: String, symbol: String, id: FolderID?, isCourse: Bool, depth: Int) -> some View {
        Button {
            selected = id
        } label: {
            HStack {
                Image(systemName: symbol).foregroundStyle(Palette.accent)
                Text(name)
                if isCourse { Text("Course").badgeStyle() }
                Spacer()
                if selected == id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected == id ? [.isButton, .isSelected] : .isButton)
    }
}
