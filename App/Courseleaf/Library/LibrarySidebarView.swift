import SwiftUI
import DocumentCore
import Workspace

/// One node of the course/folder tree.
struct FolderNode: Identifiable, Hashable {
    var folder: Folder
    var children: [FolderNode]?
    var id: FolderID { folder.id }

    /// Builds the tree under `parent` from a library manifest.
    static func tree(from manifest: LibraryManifest, parent: FolderID? = nil) -> [FolderNode] {
        manifest.folders
            .filter { $0.parentID == parent }
            .sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { folder in
                let children = tree(from: manifest, parent: folder.id)
                return FolderNode(folder: folder, children: children.isEmpty ? nil : children)
            }
    }
}

/// The library sidebar: scopes, the course/folder tree, the review queue and
/// the trash.
struct LibrarySidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = LibraryViewModel()
    @State private var nodes: [FolderNode] = []
    @State private var newFolderParent: FolderID? = nil
    @State private var isCreatingCourse = false
    @State private var isNamingFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: Folder? = nil
    @State private var renameText = ""

    var body: some View {
        // `List` takes an optional selection binding; the router always has one.
        let selection = Binding<AppRouter.SidebarSelection?>(
            get: { env.router.sidebar },
            set: { value in if let value { env.router.sidebar = value; env.router.path = [] } })

        return List(selection: selection) {
            Section("Library") {
                row(.recents, title: "Recents", symbol: "clock")
                row(.favorites, title: "Favorites", symbol: "star")
                row(.inbox, title: "Inbox", symbol: "tray", hint: "Quick notes you have not filed yet")
                row(.folder(nil), title: "All Notebooks", symbol: "books.vertical")
            }

            Section("Courses and Folders") {
                if nodes.isEmpty {
                    Text("No folders yet")
                        .detailTextStyle()
                        .accessibilityHint("Use New Folder or New Course below")
                }
                OutlineGroup(nodes, children: \.children) { node in
                    folderRow(node.folder)
                }
            }

            Section("Study") {
                row(.review, title: "Review Queue", symbol: "checkmark.circle",
                    hint: "Pages and regions you marked for another look")
            }

            Section {
                row(.trash, title: "Trash", symbol: "trash",
                    hint: "Deleted notebooks and folders you can restore")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Courseleaf")
        .toolbar { toolbarContent }
        .task(id: env.libraryRevision) { await reload() }
        .alert("New \(isCreatingCourse ? "Course" : "Folder")", isPresented: $isNamingFolder) {
            TextField(isCreatingCourse ? "Course name" : "Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Create") {
                let name = folderName
                let parent = newFolderParent
                let isCourse = isCreatingCourse
                folderName = ""
                Task {
                    await model.createFolder(name: name, parentID: parent, isCourse: isCourse)
                    await reload()
                }
            }
        } message: {
            Text(isCreatingCourse
                 ? "A course folder owns a review queue. Notebooks and folders inside it feed that queue."
                 : "Folders group notebooks. They can be nested.")
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil },
                                                     set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingFolder = nil }
            Button("Rename") {
                if let folder = renamingFolder {
                    let name = renameText
                    Task { await model.rename(folder, to: name); await reload() }
                }
                renamingFolder = nil
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    newFolderParent = env.router.sidebar.destinationFolderID
                    isCreatingCourse = false
                    isNamingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    newFolderParent = env.router.sidebar.destinationFolderID
                    isCreatingCourse = true
                    isNamingFolder = true
                } label: {
                    Label("New Course", systemImage: "graduationcap")
                }
                Divider()
                Button {
                    env.router.isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Label("Library Options", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Library options")
            .accessibilityHint("Create a folder or course, or open settings")
        }
    }

    private func row(_ selection: AppRouter.SidebarSelection, title: String, symbol: String, hint: String? = nil) -> some View {
        Label(title, systemImage: symbol)
            .tag(selection)
            .accessibilityLabel(title)
            .accessibilityHint(hint ?? "Shows \(title)")
    }

    private func folderRow(_ folder: Folder) -> some View {
        Label {
            Text(folder.name)
        } icon: {
            Image(systemName: folder.isCourse ? "graduationcap.fill" : "folder")
                .foregroundStyle(Color(Palette.tones(for: folder.color).base))
        }
        .tag(AppRouter.SidebarSelection.folder(folder.id))
        .accessibilityLabel(folder.isCourse ? "\(folder.name), course" : folder.name)
        .contextMenu {
            Button {
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                newFolderParent = folder.id
                isCreatingCourse = false
                isNamingFolder = true
            } label: {
                Label("New Folder Inside", systemImage: "folder.badge.plus")
            }
            Button {
                env.router.sidebar = .folder(folder.id)
                env.router.path = []
            } label: {
                Label(folder.isCourse ? "Open Course" : "Open Folder", systemImage: "arrow.forward")
            }
            Divider()
            Button(role: .destructive) {
                Task { await model.deleteFolder(folder); await reload() }
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    private func reload() async {
        model.configure(env: env)
        await model.load(scope: .folder(nil))
        if let manifest = model.manifest {
            nodes = FolderNode.tree(from: manifest)
        }
    }
}
