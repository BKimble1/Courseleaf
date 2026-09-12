import Foundation
import Dispatch
import DocumentCore

/// Injectable waiting primitive so `SaveScheduler` timing runs against a
/// `ManualClock` in tests without real delays. Returning early is allowed:
/// the scheduler always re-checks its deadlines against the clock.
public protocol Sleeper: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

/// Real waiting via `Task.sleep`.
public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
    }
}

/// Test sleeper: every `sleep` suspends until `wake()` (or cancellation).
public final class ManualSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var _requested: [TimeInterval] = []

    public init() {}

    /// Intervals requested so far, in order.
    public var requestedIntervals: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _requested }
    public var sleepingCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    public func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                _requested.append(interval)
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let cancelled = waiters.filter { $0.id == id }
            waiters.removeAll { $0.id == id }
            lock.unlock()
            for w in cancelled { w.continuation.resume(throwing: CancellationError()) }
        }
    }

    /// Resumes every sleeper; each re-evaluates its deadline against the clock.
    public func wake() {
        lock.lock()
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for w in resumed { w.continuation.resume() }
    }

    /// Waits (real time, polling) until at least `count` tasks are sleeping. Returns false on timeout.
    @discardableResult
    public func waitUntilSleeping(count: Int = 1, timeout: TimeInterval = 5) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while sleepingCount < count {
            if DispatchTime.now().uptimeNanoseconds > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
}

/// Coalesces edits into commits: a commit starts at most `debounce` (300 ms)
/// after the last edit and no later than `maxDelay` (1 s) after the first
/// uncommitted edit; `flush()` commits immediately and returns after the
/// durable commit. Commits are serialized. `SaveStatus` transitions are
/// reported through `onStatusChange` and `statusUpdates`; `.saved` is set only
/// after the commit closure returned, i.e. after the manifest rename and the
/// directory sync. A failed commit reports `.failed` and keeps the edits
/// pending so the next edit or flush retries.
public actor SaveScheduler {
    /// Performs one durable commit of everything pending in the owner's
    /// editor. Return nil when there was nothing to write. On throw the
    /// owner must keep its pending changes so the retry can commit them.
    public typealias CommitOperation = @Sendable () async throws -> CommitReceipt?

    public let clock: any Clock
    public let sleeper: any Sleeper
    public let debounce: TimeInterval
    public let maxDelay: TimeInterval
    private let commitOperation: CommitOperation
    private let onStatusChange: (@Sendable (SaveStatus) -> Void)?
    private let streamContinuation: AsyncStream<SaveStatus>.Continuation
    /// Every status transition, in order. Finishes when `shutdown()` is called.
    public nonisolated let statusUpdates: AsyncStream<SaveStatus>

    public private(set) var status: SaveStatus
    /// Edits noted since the last successful commit.
    public private(set) var pendingEditCount = 0
    /// Latency of every successful commit, in order.
    public private(set) var latencies: [TimeInterval] = []
    public private(set) var commitCount = 0
    public private(set) var failureCount = 0
    public var lastLatency: TimeInterval? { latencies.last }

    private var firstEditAt: Date?
    private var lastEditAt: Date?
    private var timerTask: Task<Void, Never>?
    private var commitTask: Task<Void, Error>?
    private var isShutDown = false

    public init(clock: any Clock = SystemClock(), sleeper: any Sleeper = TaskSleeper(), debounce: TimeInterval = 0.3, maxDelay: TimeInterval = 1.0,
                initialStatus: SaveStatus? = nil, onStatusChange: (@Sendable (SaveStatus) -> Void)? = nil,
                commit: @escaping CommitOperation) {
        self.clock = clock; self.sleeper = sleeper
        self.debounce = max(0, debounce); self.maxDelay = max(self.debounce, maxDelay)
        self.commitOperation = commit; self.onStatusChange = onStatusChange
        self.status = initialStatus ?? .saved(at: clock.now(), latency: 0)
        var continuation: AsyncStream<SaveStatus>.Continuation!
        self.statusUpdates = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.streamContinuation = continuation
    }

    private func setStatus(_ new: SaveStatus) {
        status = new
        streamContinuation.yield(new)
        onStatusChange?(new)
    }

    public var hasPendingEdits: Bool { pendingEditCount > 0 }
    public var isCommitting: Bool { commitTask != nil }

    /// Records one edit and (re)starts the coalescing timer.
    public func noteEdit() {
        guard !isShutDown else { return }
        let now = clock.now()
        pendingEditCount += 1
        if firstEditAt == nil { firstEditAt = now }
        lastEditAt = now
        setStatus(.unsaved(pendingChanges: pendingEditCount))
        if timerTask == nil { startTimer() }
    }

    private func startTimer() {
        timerTask = Task { [weak self] in await self?.runTimer() }
    }

    private func runTimer() async {
        while !Task.isCancelled {
            guard let first = firstEditAt, let last = lastEditAt else { break }
            let deadline = min(last.addingTimeInterval(debounce), first.addingTimeInterval(maxDelay))
            let wait = deadline.timeIntervalSince(clock.now())
            if wait <= 0 { break }
            do { try await sleeper.sleep(for: wait) } catch { break }
        }
        if Task.isCancelled { return }
        timerTask = nil
        try? await performCommit()
    }

    /// Commits everything pending now and returns after the durable commit;
    /// rethrows the commit error (the edits stay pending for a later retry).
    public func flush() async throws {
        timerTask?.cancel()
        timerTask = nil
        try await performCommit()
    }

    /// Cancels the timer; a later `flush()` still commits. Ends `statusUpdates`.
    public func shutdown() {
        isShutDown = true
        timerTask?.cancel()
        timerTask = nil
        streamContinuation.finish()
    }

    /// Serializes commits: a caller that finds one running waits for it, then
    /// commits whatever is still pending (possibly nothing).
    private func performCommit() async throws {
        while let running = commitTask { _ = try? await running.value }
        guard pendingEditCount > 0 else { return }
        let task = Task { try await self.commitBody() }
        commitTask = task
        try await task.value
    }

    private func commitBody() async throws {
        // `commitTask` is cleared here, inside the actor, so a waiter in
        // `performCommit` never spins on an already finished task.
        defer { commitTask = nil }
        let countAtStart = pendingEditCount
        let windowFirst = firstEditAt
        firstEditAt = nil
        lastEditAt = nil
        let startWall = clock.now()
        setStatus(.saving)
        do {
            let receipt = try await commitOperation()
            pendingEditCount = max(0, pendingEditCount - countAtStart)
            let finished = clock.now()
            // Latency is measured with the injected clock (wall time in the app, deterministic in tests).
            let latency = max(finished.timeIntervalSince(startWall), receipt?.latency ?? 0, 0)
            latencies.append(latency)
            commitCount += 1
            setStatus(.saved(at: finished, latency: latency))
            if pendingEditCount > 0 {
                if firstEditAt == nil { firstEditAt = finished; lastEditAt = firstEditAt }
                if timerTask == nil && !isShutDown { startTimer() }
            }
        } catch {
            // Keep every edit pending; the earliest uncommitted edit still bounds the next deadline.
            if let windowFirst { firstEditAt = firstEditAt.map { min($0, windowFirst) } ?? windowFirst }
            if lastEditAt == nil { lastEditAt = firstEditAt }
            failureCount += 1
            let retryable = (error as? PersistenceError)?.isRetryable ?? true
            let message = (error as? PersistenceError)?.description ?? "\(error)"
            setStatus(.failed(message: message, retryable: retryable))
            throw error
        }
    }
}
