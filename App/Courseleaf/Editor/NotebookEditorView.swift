import Foundation
import SwiftUI
import Observation
import DocumentCore
import Editing
import Workspace

// SwiftUI entry point for the notebook editor. The page surface itself is the
// UIKit `NotebookEditorViewController` (PencilKit, PDFKit and the virtualized
// page pool all need UIKit); this view supplies the navigation chrome around
// it and owns the sheets the shell provides.

/// Observable bridge between the SwiftUI chrome and the UIKit editor.
/// Deliberately not actor-annotated so a `View` initializer can create it.
@Observable
final class NotebookEditorChrome {
    var currentPageID: PageID?
    var currentPageIndex = 0
    var pageCount = 1
    var isReadingMode = false
    var isShowingSearch = false
    var isShowingProblemInspector = false
    var isShowingExport = false

    @ObservationIgnored weak var controller: NotebookEditorViewController?
}

struct NotebookEditorView: View {
    private let session: any DocumentSessioning
    private let initialPageID: PageID?
    private let initialHighlight: PageRect?
    private let appEnvironment: AppEnvironment
    @State private var chrome = NotebookEditorChrome()

    init(session: any DocumentSessioning, initialPageID: PageID?, initialHighlight: PageRect? = nil,
         environment: AppEnvironment) {
        self.session = session
        self.initialPageID = initialPageID
        self.initialHighlight = initialHighlight
        self.appEnvironment = environment
    }

    var body: some View {
        // Input and gesture settings the editor needs, in one value the shell owns.
        let settings = appEnvironment.settings.editorInput
        let readingMode = chrome.isReadingMode
        let pageID = chrome.currentPageID ?? session.editor.snapshot.document.pageIDs.first

        return EditorHost(session: session,
                          initialPageID: initialPageID,
                          initialHighlight: initialHighlight,
                          settings: settings,
                          isReadingMode: readingMode,
                          chrome: chrome,
                          appEnvironment: appEnvironment)
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        chrome.controller?.presentPageNavigator()
                    } label: {
                        Label("Pages", systemImage: "square.grid.2x2")
                    }
                    .accessibilityLabel("Pages, bookmarks and outline")

                    Button {
                        chrome.isReadingMode.toggle()
                    } label: {
                        Label("Reading Mode", systemImage: readingMode ? "book.fill" : "book")
                    }
                    .accessibilityLabel("Reading mode")
                    .accessibilityAddTraits(readingMode ? .isSelected : [])

                    Button {
                        chrome.isShowingSearch = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityLabel("Search in notebook")

                    Button {
                        chrome.isShowingProblemInspector = true
                    } label: {
                        Label("Problem Inspector", systemImage: "list.bullet.rectangle")
                    }

                    Button {
                        chrome.isShowingExport = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $chrome.isShowingSearch) {
                NotebookSearchView(session: session, loader: chrome.controller?.loader) { hit in
                    chrome.isShowingSearch = false
                    chrome.controller?.revealSearchHit(pageID: hit.pageID, region: hit.bounds)
                }
            }
            .sheet(isPresented: $chrome.isShowingProblemInspector) {
                if let pageID {
                    ProblemInspectorView(session: session, pageID: pageID)
                }
            }
            .sheet(isPresented: $chrome.isShowingExport) {
                if let pageID {
                    ExportSheet(session: session, currentPageID: pageID) { [chrome, session] in
                        // Export reads the document, so the document has to be
                        // what is on screen first. If the editor is already
                        // gone there is nothing in a view to finish, but the
                        // document still has to be made durable — reporting
                        // success without saving would be the worse failure.
                        if let controller = chrome.controller {
                            return await controller.prepareForDocumentSnapshot()
                        }
                        do { try await session.flush(); return nil } catch { return error }
                    }
                }
            }
    }
}

// MARK: - UIKit bridge

struct EditorHost: UIViewControllerRepresentable {
    let session: any DocumentSessioning
    let initialPageID: PageID?
    let initialHighlight: PageRect?
    let settings: EditorInputSettings
    let isReadingMode: Bool
    let chrome: NotebookEditorChrome
    let appEnvironment: AppEnvironment

    func makeUIViewController(context: Context) -> NotebookEditorViewController {
        let controller = NotebookEditorViewController(session: session, initialPageID: initialPageID,
                                                      inputSettings: settings, initialHighlight: initialHighlight)
        let chrome = self.chrome
        chrome.controller = controller
        // After a committed stroke the page's text is stale; hand it to the
        // app's background recognition queue (docs/ARCHITECTURE.md §9).
        let environment = appEnvironment
        let documentID = session.documentID
        controller.onPageNeedsRecognition = { pageID in
            environment.notePagesChanged([pageID], in: documentID)
        }
        // Hop out of the current layout pass before touching observable state.
        controller.onCurrentPageChange = { pageID, index in
            DispatchQueue.main.async {
                chrome.currentPageID = pageID
                chrome.currentPageIndex = index
                chrome.pageCount = chrome.controller?.pageIDs.count ?? 1
            }
        }
        controller.onSaveFailure = { error in
            environment.present(error, title: "This notebook could not be saved")
        }
        controller.onScrollDirectionChange = { isHorizontal in
            environment.settings.horizontalPaging = isHorizontal
        }
        controller.isHorizontalPaging = appEnvironment.settings.horizontalPaging
        controller.onReadingModeChange = { value in
            DispatchQueue.main.async {
                if chrome.isReadingMode != value { chrome.isReadingMode = value }
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: NotebookEditorViewController, context: Context) {
        chrome.controller = controller
        controller.inputSettings = settings
        controller.isReadingMode = isReadingMode
    }

    /// SwiftUI's own teardown hook, and the main-actor-safe place to give the
    /// session's callbacks back.
    static func dismantleUIViewController(_ controller: NotebookEditorViewController, coordinator: ()) {
        controller.detachFromSession()
    }
}
