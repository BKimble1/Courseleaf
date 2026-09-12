import Foundation
import DocumentCore
import Workspace

/// UI-facing state of one page in the queue.
enum RecognitionPageState: Hashable, Sendable {
    /// Waiting for the debounce window (edits are still coming in).
    case debouncing
    case queued
    case recognizing
    case indexed(recordCount: Int)
    case failed(String)
    case cancelled
}

struct RecognitionQueueStatus: Hashable, Sendable {
    var isPaused: Bool
    var activePageID: PageID?
    var queuedCount: Int
    var states: [PageID: RecognitionPageState]
}

/// Background recognition for one open document (docs/ARCHITECTURE.md §9).
///
/// - `enqueue(_:)` debounces per page (2 s by default) and de-duplicates: a
///   page edited ten times in a row is recognized once, after the edits stop.
/// - One page is processed at a time on a utility-priority task: PDF text
///   extraction (`.pdfText`) for PDF pages, then Vision recognition
///   (`.recognized`). Results go to `recordSearchRecords(_:for:kind:state:)`
///   with `.indexed`, failures with `.failed`; the page is marked `.queued`
///   while waiting so search can say "not yet indexed".
/// - `pause()` (app backgrounded) finishes nothing new until `resume()`;
///   `cancelAll()` drops every pending page and cancels the running one.
actor RecognitionQueue {
    typealias Recognizer = @Sendable (PageID) async throws -> [SearchRecord]
    /// nil means "this page has no PDF text layer to index" (template/image pages).
    typealias PDFExtractor = @Sendable (PageID) async throws -> [SearchRecord]?
    typealias Recorder = @Sendable (_ records: [SearchRecord], _ pageID: PageID, _ kind: SearchRecordKind, _ state: IndexingState) async -> Void

    private let extractPDFText: PDFExtractor
    private let recognizeInk: Recognizer
    private let record: Recorder
    private let debounce: Duration
    private let priority: TaskPriority

    private var debounceTasks: [PageID: Task<Void, Never>] = [:]
    private var ready: [PageID] = []
    private var readySet: Set<PageID> = []
    private var states: [PageID: RecognitionPageState] = [:]
    private var worker: Task<Void, Never>?
    private var activePageID: PageID?
    private(set) var isPaused = false
    /// Observed by the UI (called on the actor; hop to the main actor in the closure).
    var onStateChange: (@Sendable (PageID, RecognitionPageState) -> Void)?

    /// Production wiring: the session's PDF extractor and Vision recognizer.
    init(session: any DocumentSessioning, debounce: Duration = .seconds(2), priority: TaskPriority = .utility) {
        let sourceBox = SessionContentSource(session: session)
        let extractor = PDFTextExtractor(source: sourceBox)
        let recognizer = VisionTextRecognizer(source: sourceBox)
        self.init(
            extractPDFText: { try await extractor.records(for: $0) },
            recognizeInk: { try await recognizer.records(for: $0) },
            record: { records, pageID, kind, state in
                await session.recordSearchRecords(records, for: pageID, kind: kind, state: state)
            },
            debounce: debounce, priority: priority)
    }

    /// Injectable wiring (tests): `extractPDFText` may return `[]` for non-PDF pages.
    init(extractPDFText: @escaping PDFExtractor, recognizeInk: @escaping Recognizer, record: @escaping Recorder,
         debounce: Duration = .seconds(2), priority: TaskPriority = .utility) {
        self.extractPDFText = extractPDFText
        self.recognizeInk = recognizeInk
        self.record = record
        self.debounce = debounce
        self.priority = priority
    }

    // MARK: Enqueue

    func enqueue(_ pageID: PageID) {
        debounceTasks[pageID]?.cancel()
        setState(pageID, .debouncing)
        let delay = debounce
        debounceTasks[pageID] = Task(priority: priority) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.debounceElapsed(pageID)
        }
    }

    func enqueue(_ pageIDs: [PageID]) { for id in pageIDs { enqueue(id) } }

    private func debounceElapsed(_ pageID: PageID) async {
        debounceTasks[pageID] = nil
        if !readySet.contains(pageID) {
            ready.append(pageID)
            readySet.insert(pageID)
        }
        setState(pageID, .queued)
        await record([], pageID, .recognized, .queued)
        startWorkerIfNeeded()
    }

    // MARK: Control

    func pause() {
        isPaused = true
        worker?.cancel()
    }

    func resume() {
        isPaused = false
        startWorkerIfNeeded()
    }

    func cancelAll() {
        for task in debounceTasks.values { task.cancel() }
        for pageID in debounceTasks.keys { setState(pageID, .cancelled) }
        debounceTasks.removeAll()
        for pageID in ready { setState(pageID, .cancelled) }
        ready.removeAll()
        readySet.removeAll()
        worker?.cancel()
    }

    func state(of pageID: PageID) -> RecognitionPageState? { states[pageID] }

    var status: RecognitionQueueStatus {
        RecognitionQueueStatus(isPaused: isPaused, activePageID: activePageID, queuedCount: ready.count + debounceTasks.count, states: states)
    }

    /// Waits until the queue is idle (tests and explicit flushes).
    func drain() async {
        while worker != nil || !debounceTasks.isEmpty || !ready.isEmpty {
            if isPaused { return }
            if let worker { await worker.value } else { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    // MARK: Worker

    private func startWorkerIfNeeded() {
        guard !isPaused, worker == nil, !ready.isEmpty else { return }
        worker = Task(priority: priority) { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while !isPaused, !Task.isCancelled, let pageID = ready.first {
            ready.removeFirst()
            readySet.remove(pageID)
            activePageID = pageID
            setState(pageID, .recognizing)
            await process(pageID)
            activePageID = nil
        }
        worker = nil
        if !isPaused && !ready.isEmpty { startWorkerIfNeeded() }
    }

    private func process(_ pageID: PageID) async {
        do {
            let pdfRecords = try await extractPDFText(pageID)
            try Task.checkCancellation()
            if let pdfRecords {
                await record(pdfRecords, pageID, .pdfText, .indexed)
            } else {
                await record([], pageID, .pdfText, .notApplicable)
            }
            let inkRecords = try await recognizeInk(pageID)
            try Task.checkCancellation()
            await record(inkRecords, pageID, .recognized, .indexed)
            setState(pageID, .indexed(recordCount: (pdfRecords?.count ?? 0) + inkRecords.count))
        } catch is CancellationError {
            await interrupted(pageID)
        } catch RecognitionError.cancelled {
            await interrupted(pageID)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            await record([], pageID, .recognized, .failed)
            setState(pageID, .failed(message))
        }
    }

    /// A page interrupted by `pause()` goes back to the front of the queue; one
    /// dropped by `cancelAll()` is reported as not indexed.
    private func interrupted(_ pageID: PageID) async {
        if isPaused, !readySet.contains(pageID) {
            ready.insert(pageID, at: 0)
            readySet.insert(pageID)
            setState(pageID, .queued)
            await record([], pageID, .recognized, .queued)
        } else {
            await record([], pageID, .recognized, .notIndexed)
            setState(pageID, .cancelled)
        }
    }

    private func setState(_ pageID: PageID, _ state: RecognitionPageState) {
        states[pageID] = state
        onStateChange?(pageID, state)
    }
}
