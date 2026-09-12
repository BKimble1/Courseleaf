import Foundation
import Observation
import DocumentCore
import Workspace

/// Where the student is: the selected sidebar item, what the detail column
/// shows, and which shell sheet is open. Screens read and write this instead
/// of passing bindings down through every view.
@MainActor
@Observable
final class AppRouter {
    /// One row of the library sidebar.
    enum SidebarSelection: Hashable {
        case recents
        case favorites
        case inbox
        /// The library root ("All Notebooks") or one folder/course.
        case folder(FolderID?)
        case review
        case trash

        var libraryScope: LibraryScope? {
            switch self {
            case .recents: return .recents
            case .favorites: return .favorites
            case .inbox: return .inbox
            case .folder(let id): return .folder(id)
            case .trash: return .trash
            case .review: return nil
            }
        }

        var title: String {
            switch self {
            case .recents: return "Recents"
            case .favorites: return "Favorites"
            case .inbox: return "Inbox"
            case .folder(let id): return id == nil ? "All Notebooks" : "Folder"
            case .review: return "Review Queue"
            case .trash: return "Trash"
            }
        }

        /// The folder a new notebook or import lands in for this selection.
        var destinationFolderID: FolderID? {
            if case .folder(let id) = self { return id }
            return nil
        }
    }

    /// A page to open in the editor.
    struct NotebookTarget: Hashable {
        var documentID: DocumentID
        /// Page to show; nil restores the notebook's last viewed page.
        var pageIndex: Int?
        /// A region to highlight once the page is shown (a search hit or review region).
        var highlight: PageRect?

        init(documentID: DocumentID, pageIndex: Int? = nil, highlight: PageRect? = nil) {
            self.documentID = documentID
            self.pageIndex = pageIndex
            self.highlight = highlight
        }
    }

    enum Route: Hashable {
        case notebook(NotebookTarget)
    }

    var sidebar: SidebarSelection = .recents
    /// Detail-column navigation stack (the editor is pushed onto it).
    var path: [Route] = []

    // Shell sheets.
    var isShowingSettings = false
    var isShowingSearch = false
    var isShowingNewNotebook = false
    var isShowingImporter = false
    var isShowingOnboarding = false
    /// Search scoped to the notebook that is open, when there is one.
    var searchScope: SearchScope = .library
    /// Incremented when a quick note is requested (menu or keyboard); the
    /// library screen creates the note and opens it.
    private(set) var quickCaptureRequests = 0

    func requestQuickCapture() { quickCaptureRequests &+= 1 }

    /// Opens a notebook in the detail column, replacing any notebook already shown.
    func openNotebook(_ documentID: DocumentID, pageIndex: Int? = nil, highlight: PageRect? = nil) {
        let target = NotebookTarget(documentID: documentID, pageIndex: pageIndex, highlight: highlight)
        path = [.notebook(target)]
    }

    /// The notebook currently open in the detail column, if any.
    var openNotebookID: DocumentID? {
        for route in path.reversed() {
            if case .notebook(let target) = route { return target.documentID }
        }
        return nil
    }

    func closeNotebook() {
        path.removeAll { route in
            if case .notebook = route { return true }
            return false
        }
    }

    func showSearch(scope: SearchScope) {
        searchScope = scope
        isShowingSearch = true
    }
}
