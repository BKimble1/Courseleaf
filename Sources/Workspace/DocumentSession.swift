import Foundation
import DocumentCore
import Editing
import Persistence
import Catalog

/// One open document (docs/ARCHITECTURE.md sections 6, 7 and 9): the
/// `DocumentEditor`, a `SaveScheduler` that coalesces edits into commits of
/// the editor's pending `ChangeSet` through `DocumentPackageStore.commit`,
/// the published `SaveStatus`, in-memory service of not-yet-committed assets,
/// and the per-document search-index calls into the catalog.
///
/// Main-actor bound because the editor is driven by UI events. Commits run on
/// the package store actor; the main actor is only used to snapshot the
/// editor state at the start of a commit and to adopt the assigned revision
/// identifiers when it succeeded.
@MainActor
public final class DocumentSession: DocumentSessioning {
    public let documentID: DocumentID
    public let editor: DocumentEditor
    public private(set) var saveStatus: SaveStatus
    public var onSaveStatusChange: ((SaveStatus) -> Void)?
    public var onChange: ((ChangeSet) -> Void)?

    /// The package this session writes. Exposed for tooling (export, tests); never commit through it directly.
    public let packageStore: DocumentPackageStore
    /// Recovery information from opening the package.
    public let recoveryReport: RecoveryReport
    public private(set) var isClosed = false
    /// Successful, non-no-op commits so far.
    public private(set) var commitCount = 0
    /// Latency of the last successful commit, from the injected clock.
    public private(set) var lastCommitLatency: TimeInterval?
    /// Pages whose recognition has been reported as `queued` and not yet finished.
    public private(set) var queuedRecognitionPages: Set<PageID> = []
    /// Pending assets registered and not yet durable, served from memory by `assetData`.
    public var pendingAssetCount: Int { pendingAssetData.count }

    /// Replaced by the library service when the catalog is rebuilt while the session is open.
    var catalog: CatalogDatabase?
    /// Called (on the main actor) once the session closed; the library service drops its reference.
    var onClosed: (() -> Void)?

    private let scheduler: SaveScheduler
    private let statusHop = SerialHop()
    private var pendingAssetData: [AssetID: Data] = [:]
    /// Changes taken from the editor whose commit has not succeeded yet (kept across a failed commit for the retry).
    private var uncommitted: ChangeSet = .empty
    private var schedulerQueue: Task<Void, Never>?

    init(documentID: DocumentID, snapshot: DocumentSnapshot, recoveryReport: RecoveryReport, packageStore: DocumentPackageStore,
         catalog: CatalogDatabase?, clock: any Clock, sleeper: any Sleeper, debounce: TimeInterval, maxDelay: TimeInterval) {
        self.documentID = documentID
        self.editor = DocumentEditor(snapshot: snapshot, clock: clock)
        self.packageStore = packageStore
        self.recoveryReport = recoveryReport
        self.catalog = catalog
        self.saveStatus = .saved(at: clock.now(), latency: 0)
        let box = SessionBox()
        let hop = statusHop
        self.scheduler = SaveScheduler(clock: clock, sleeper: sleeper, debounce: debounce, maxDelay: maxDelay,
                                       initialStatus: saveStatus,
                                       onStatusChange: { status in
                                           hop.enqueue { await box.session?.publish(status) }
                                       },
                                       commit: {
                                           guard let session = box.session else { return nil }
                                           return try await session.performCommit()
                                       })
        box.session = self
    }

    // MARK: Editing

    public func apply(_ command: EditCommand) throws {
        try ensureOpen()
        let changes = try editor.apply(command)
        noteChange(changes)
    }

    public func undo() {
        guard !isClosed, let changes = editor.undo() else { return }
        noteChange(changes)
    }

    public func redo() {
        guard !isClosed, let changes = editor.redo() else { return }
        noteChange(changes)
    }

    public var canUndo: Bool { editor.canUndo }
    public var canRedo: Bool { editor.canRedo }

    public func performGrouped(_ name: String, _ body: () throws -> Void) rethrows {
        try editor.performGrouped(name, body)
    }

    /// Non-undoable filing change routed through the open editor so the next commit keeps it.
    public func setFolderID(_ folderID: FolderID?) throws {
        try ensureOpen()
        editor.setFolderID(folderID)
        noteChange(ChangeSet(documentChanged: true))
    }

    /// Non-undoable view state; persisted with the next commit.
    public func setLastViewedPageIndex(_ index: Int) {
        guard !isClosed else { return }
        editor.setLastViewedPageIndex(index)
        noteChange(ChangeSet(documentChanged: true))
    }

    public func addAsset(_ asset: PendingAsset) {
        guard !isClosed else { return }
        pendingAssetData[asset.asset.id] = asset.data
        editor.registerPendingAsset(asset)
        noteChange(ChangeSet(newAssets: [asset]))
    }

    public func assetData(_ id: AssetID) async throws -> Data? {
        if let data = pendingAssetData[id] { return data }
        do { return try await packageStore.assetData(id) } catch { throw WorkspaceError.storage("\(error)") }
    }

    public func assetURL(_ id: AssetID) async -> URL? {
        if pendingAssetData[id] != nil { return nil }
        return await packageStore.assetURL(id)
    }

    // MARK: Saving

    public func flush() async throws {
        await schedulerQueue?.value
        do {
            try await scheduler.flush()
        } catch {
            await statusHop.drain()
            throw WorkspaceError.storage((error as? PersistenceError)?.description ?? "\(error)")
        }
        await statusHop.drain()
    }

    /// Why the last `close()` did not close. Cleared by a successful close.
    public private(set) var closeFailure: WorkspaceError?

    /// Flushes and releases the session.
    ///
    /// A failed final save does **not** close it. Shutting the scheduler down
    /// with edits still in it would throw away work that is still recoverable —
    /// the scheduler keeps a failed commit's changes pending precisely so a
    /// retry can succeed — so the session stays open and `closeFailure` says
    /// what happened. Callers that must proceed regardless use
    /// `forceClose()` and take the loss knowingly.
    public func close() async {
        guard !isClosed else { return }
        do {
            try await flush()
        } catch {
            closeFailure = (error as? WorkspaceError) ?? .storage("\(error)")
            return
        }
        closeFailure = nil
        await finishClosing()
    }

    /// Closes even though the final save failed. Only for teardown paths that
    /// have nowhere left to put the work (the library itself is closing).
    public func forceClose() async {
        guard !isClosed else { return }
        try? await flush()
        await finishClosing()
    }

    private func finishClosing() async {
        isClosed = true
        await scheduler.shutdown()
        await statusHop.drain()
        onClosed?()
        onClosed = nil
    }

    // MARK: Search index

    public func recordSearchRecords(_ records: [SearchRecord], for pageID: PageID, kind: SearchRecordKind, state: IndexingState) async {
        if state == .queued { queuedRecognitionPages.insert(pageID) } else { queuedRecognitionPages.remove(pageID) }
        guard let catalog else { return }
        let scoped = records.map { record -> SearchRecord in var r = record; r.documentID = documentID; return r }
        try? await catalog.setSearchRecords(scoped, pageID: pageID, kind: kind, state: state)
    }

    public func indexStatus(for pageID: PageID) async -> PageIndexStatus? {
        guard let catalog else { return nil }
        return try? await catalog.indexStatus(pageID: pageID)
    }

    public func pagesNeedingRecognition() async -> [PageID] {
        guard let catalog else { return [] }
        return (try? await catalog.pagesNeedingRecognition(documentID: documentID)) ?? []
    }

    // MARK: - Private

    private func ensureOpen() throws {
        if isClosed { throw WorkspaceError.storage("The document session is closed.") }
    }

    private func noteChange(_ changes: ChangeSet) {
        onChange?(changes)
        let previous = schedulerQueue
        let scheduler = self.scheduler
        schedulerQueue = Task { await previous?.value; await scheduler.noteEdit() }
    }

    private func publish(_ status: SaveStatus) {
        saveStatus = status
        onSaveStatusChange?(status)
    }

    /// One durable commit of everything pending. Runs on the main actor only
    /// long enough to take the editor's pending changes and snapshot; the
    /// write itself happens on the package store actor.
    func performCommit() async throws -> CommitReceipt? {
        uncommitted.merge(editor.takePendingChanges())
        let snapshot = editor.snapshot
        let changes = uncommitted
        let receipt = try await packageStore.commit(snapshot: snapshot, changes: changes)
        uncommitted = .empty
        editor.adoptCommittedRevisions(from: receipt.snapshot, pagesWritten: receipt.pagesWritten)
        for id in receipt.assetsWritten { pendingAssetData[id] = nil }
        for id in receipt.assetsReused { pendingAssetData[id] = nil }
        if !receipt.isNoOp {
            commitCount += 1
            lastCommitLatency = receipt.latency
            if let catalog { try? await catalog.upsertDocument(receipt.snapshot) }
        }
        return receipt
    }
}

/// Weak back-reference handed to the scheduler's closures before `self` is fully initialized.
private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _session: DocumentSession?
    var session: DocumentSession? {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); _session = newValue; lock.unlock() }
    }
}

/// Serializes asynchronous hops so callbacks arrive in the order they were
/// enqueued and a caller can wait until everything enqueued so far ran.
final class SerialHop: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = last
        last = Task { await previous?.value; await operation() }
        lock.unlock()
    }

    func drain() async {
        await pending()?.value
    }

    private func pending() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}
