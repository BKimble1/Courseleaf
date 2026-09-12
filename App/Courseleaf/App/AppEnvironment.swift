import Foundation
import Observation
import SwiftUI
import DocumentCore
import Editing
import Workspace

/// Everything the screens share, created once in `CourseleafApp` and injected
/// with `.environment`. There is no app-wide mutable singleton
/// (docs/ARCHITECTURE.md §1): the library service is an actor, the settings and
/// entitlement stores are `@Observable` main-actor objects, and this object owns
/// them all.
@MainActor
@Observable
final class AppEnvironment {
    /// Managed library root: Application Support/Courseleaf/Library.
    let rootURL: URL
    /// The concrete service. Screens may use it through `LibraryServicing`.
    let libraryService: LibraryService
    let settings: SettingsStore
    let entitlements: any EntitlementStore
    /// Navigation state shared by the library, search and review screens.
    let router: AppRouter

    /// Alert shown by the root view when a service call failed.
    var alert: AppAlert?
    /// Bumped after any library mutation so open listings reload.
    private(set) var libraryRevision: Int = 0
    /// True once the library (and its catalog) opened successfully at least once.
    private(set) var didOpenLibrary = false
    /// Set when the search index is unavailable, so screens can say so plainly.
    private(set) var catalogUnavailableReason: String?

    /// Open editing sessions by document, so reopening a notebook does not
    /// build a second editor over the same package.
    @ObservationIgnored private var sessions: [DocumentID: any DocumentSessioning] = [:]
    /// One background recognition queue per open session (docs/ARCHITECTURE.md §9).
    @ObservationIgnored private var recognitionQueues: [DocumentID: RecognitionQueue] = [:]

    /// `LibraryServicing` view of the service, which is all the screens need.
    var library: any LibraryServicing { libraryService }

    /// Defaults are `nil` rather than main-actor isolated expressions: a
    /// default argument is evaluated in a nonisolated context, so it may not
    /// call a main-actor initializer.
    init(rootURL: URL? = nil,
         settings: SettingsStore? = nil,
         entitlements: (any EntitlementStore)? = nil,
         pdfInspector: (any PDFInspecting)? = nil,
         imageInspector: (any ImageInspecting)? = nil,
         clock: any Clock = SystemClock()) {
        let rootURL = rootURL ?? UITestLaunch.libraryRoot() ?? AppEnvironment.defaultLibraryRoot()
        self.rootURL = rootURL
        self.settings = settings ?? SettingsStore()
        self.entitlements = entitlements ?? StoreKitEntitlementStore()
        self.router = AppRouter()
        // Creating the directory here keeps the failure visible at launch
        // rather than at the first save; the service also creates its layout.
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.libraryService = LibraryService(rootURL: rootURL,
                                             pdfInspector: pdfInspector ?? PDFKitInspector(),
                                             imageInspector: imageInspector ?? ImageIOInspector(),
                                             clock: clock)
    }

    /// Application Support/Courseleaf/Library, created if missing.
    /// `nonisolated` so it can be called before the environment exists.
    nonisolated static func defaultLibraryRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Courseleaf", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Opens the library (creating its layout and catalog). Safe to call twice.
    func prepare() async {
        do {
            try await libraryService.open()
            didOpenLibrary = true
            catalogUnavailableReason = await libraryService.catalogUnavailableReason
        } catch {
            present(error, title: "Your library could not be opened")
        }
    }

    /// Flushes every open document; called when the app resigns active.
    func flushOpenDocuments() async {
        for (_, session) in sessions {
            do { try await session.flush() } catch { present(error, title: "A notebook could not be saved") }
        }
    }

    /// Closes every session and the library (app shutting down).
    func shutdown() async {
        for id in Array(recognitionQueues.keys) {
            await recognitionQueues[id]?.cancelAll()
        }
        recognitionQueues.removeAll()
        for id in Array(sessions.keys) {
            await libraryService.closeSession(id)
        }
        sessions.removeAll()
        await libraryService.close()
    }

    // MARK: - Sessions

    /// The open session for a document, opening it (and its recognition queue)
    /// on first use.
    func session(for id: DocumentID) async throws -> any DocumentSessioning {
        if let existing = sessions[id] { return existing }
        let session = try await libraryService.openSession(id)
        sessions[id] = session
        await startRecognition(for: session)
        return session
    }

    /// The already-open session, without opening one.
    func openSession(_ id: DocumentID) -> (any DocumentSessioning)? { sessions[id] }

    var openDocumentIDs: [DocumentID] { Array(sessions.keys) }

    /// Flushes and releases a session and its recognition queue.
    func closeSession(_ id: DocumentID) async {
        if let queue = recognitionQueues.removeValue(forKey: id) { await queue.cancelAll() }
        guard sessions.removeValue(forKey: id) != nil else { return }
        await libraryService.closeSession(id)
        noteLibraryChanged()
    }

    /// Queues every page whose text has not been indexed yet, and keeps
    /// indexing pages as they change. The editor installs its own `onChange`
    /// handler later and chains to this one, so both run.
    private func startRecognition(for session: any DocumentSessioning) async {
        let queue = RecognitionQueue(session: session)
        recognitionQueues[session.documentID] = queue
        let documentID = session.documentID
        session.onChange = { [weak self] changes in
            self?.notePagesChanged(changes.changedPageIDs, in: documentID)
        }
        let pending = await session.pagesNeedingRecognition()
        if !pending.isEmpty { await queue.enqueue(pending) }
    }

    /// Called by the editor after a page changed, so its text is re-indexed.
    func notePagesChanged(_ pageIDs: Set<PageID>, in documentID: DocumentID) {
        guard let queue = recognitionQueues[documentID], !pageIDs.isEmpty else { return }
        let ids = Array(pageIDs)
        Task { await queue.enqueue(ids) }
    }

    /// Pauses background recognition (app backgrounded) or resumes it.
    func setRecognitionPaused(_ paused: Bool) {
        let queues = Array(recognitionQueues.values)
        Task {
            for queue in queues {
                if paused { await queue.pause() } else { await queue.resume() }
            }
        }
    }

    // MARK: - Change notification and errors

    /// Tells every listing to reload after a library mutation.
    func noteLibraryChanged() { libraryRevision &+= 1 }

    func present(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: AppErrorText.message(for: error), isRetryable: AppErrorText.isRetryable(error))
    }

    func present(title: String, message: String) {
        alert = AppAlert(title: title, message: message)
    }

    /// Runs a library call, surfacing any failure as an alert. Returns nil when
    /// it failed, so callers can skip their follow-up work.
    @discardableResult
    func perform<T>(_ failureTitle: String, _ body: () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch {
            present(error, title: failureTitle)
            return nil
        }
    }

    /// Refreshes `catalogUnavailableReason` (Settings and Search show it).
    func refreshCatalogState() async {
        catalogUnavailableReason = await libraryService.catalogUnavailableReason
    }
}


// MARK: - UI test launch mode

/// `-CourseleafUITest` puts the app on a throwaway library in a temporary
/// directory and opens one notebook, so a UI test drives the real screens
/// without ever touching a student's files. Nothing else changes: the same
/// views, the same editor, the same stores.
enum UITestLaunch {
    static let argument = "-CourseleafUITest"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// A fresh library root per launch, so a test never inherits the last run's
    /// state and never writes into Application Support.
    static func libraryRoot() -> URL? {
        guard isActive else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseleafUITest", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension AppEnvironment {
    /// Creates and opens one notebook when launched for UI testing, so a test
    /// starts in the editor instead of driving the library first.
    func openUITestNotebookIfNeeded() async {
        guard UITestLaunch.isActive else { return }
        settings.hasSeenOnboarding = true
        guard router.openNotebookID == nil else { return }
        guard let id = try? await library.createNotebook(title: "UI Test Notebook", folderID: nil,
                                                         template: .preset(.lined), pageSize: .letter,
                                                         cover: .default, pageCount: 3) else { return }
        noteLibraryChanged()
        router.openNotebook(id)
    }
}
