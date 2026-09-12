import XCTest
import DocumentCore
@testable import Persistence

final class SaveSchedulerTests: XCTestCase {
    let now = Support.now

    /// Records every commit's clock time and can be made to fail or block.
    final class CommitProbe: @unchecked Sendable {
        let lock = NSLock()
        var commitTimes: [Date] = []
        var failuresRemaining = 0
        var gate: CheckedContinuation<Void, Never>?
        var blocks = false
        func record(_ date: Date) { lock.lock(); commitTimes.append(date); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return commitTimes.count }
        func takeFailure() -> Bool { lock.lock(); defer { lock.unlock() }; if failuresRemaining > 0 { failuresRemaining -= 1; return true }; return false }
        func waitAtGate() async { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.lock(); gate = c; lock.unlock() } }
        func openGate() { lock.lock(); let g = gate; gate = nil; lock.unlock(); g?.resume() }
    }

    final class StatusLog: @unchecked Sendable {
        let lock = NSLock()
        var entries: [SaveStatus] = []
        func append(_ s: SaveStatus) { lock.lock(); entries.append(s); lock.unlock() }
        var all: [SaveStatus] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    /// Waits (real time) until the scheduler's timer is parked in the manual sleeper.
    private func expectSleeping(_ sleeper: ManualSleeper, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let sleeping = await sleeper.waitUntilSleeping()
        XCTAssertTrue(sleeping, "timer did not start sleeping \(message)", file: file, line: line)
    }

    /// `ManualClock` accumulates `Date` arithmetic, so times are compared within a microsecond.
    private let tolerance: TimeInterval = 1e-6

    private func assertDates(_ actual: [Date], _ expected: [Date], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual) vs \(expected)", file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a.timeIntervalSince(e), 0, accuracy: tolerance, file: file, line: line) }
    }

    private func assertStatus(_ actual: SaveStatus?, _ expected: SaveStatus, file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (.saved(let at, let latency)?, .saved(let expectedAt, let expectedLatency)):
            XCTAssertEqual(at.timeIntervalSince(expectedAt), 0, accuracy: tolerance, file: file, line: line)
            XCTAssertEqual(latency, expectedLatency, accuracy: tolerance, file: file, line: line)
        default:
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func assertStatuses(_ actual: [SaveStatus], _ expected: [SaveStatus], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual) vs \(expected)", file: file, line: line)
        for (a, e) in zip(actual, expected) { assertStatus(a, e, file: file, line: line) }
    }

    private func makeScheduler(clock: ManualClock, sleeper: ManualSleeper, probe: CommitProbe, log: StatusLog) -> SaveScheduler {
        SaveScheduler(clock: clock, sleeper: sleeper, onStatusChange: { log.append($0) }) {
            if probe.blocks { await probe.waitAtGate() }
            if probe.takeFailure() { throw PersistenceError.diskFull }
            probe.record(clock.now())
            return nil
        }
    }

    func testCommitFollowsLastEditByDebounceInterval() async throws {
        let clock = ManualClock(start: now), sleeper = ManualSleeper(), probe = CommitProbe(), log = StatusLog()
        let scheduler = makeScheduler(clock: clock, sleeper: sleeper, probe: probe, log: log)
        await scheduler.noteEdit()
        await expectSleeping(sleeper)
        XCTAssertEqual(sleeper.requestedIntervals.last!, 0.3, accuracy: tolerance)
        let statusAfterEdit = await scheduler.status
        XCTAssertEqual(statusAfterEdit, .unsaved(pendingChanges: 1))

        clock.advance(by: 0.2)
        await scheduler.noteEdit()
        sleeper.wake()
        await expectSleeping(sleeper)
        XCTAssertEqual(probe.count, 0, "nothing committed yet: 0.3 s have not passed since the last edit")
        XCTAssertEqual(sleeper.requestedIntervals.last!, 0.3, accuracy: tolerance)

        clock.advance(by: 0.25)   // t = 0.45: still inside the debounce window
        sleeper.wake()
        await expectSleeping(sleeper)
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(sleeper.requestedIntervals.last!, 0.05, accuracy: tolerance)

        clock.advance(by: 0.05)   // t = 0.5 = last edit + 0.3
        sleeper.wake()
        await waitUntil("commit") { probe.count == 1 }
        assertDates(probe.commitTimes, [now.addingTimeInterval(0.5)])
        await waitUntil("saved status") { await scheduler.status.isDurable }
        assertStatuses(log.all, [.unsaved(pendingChanges: 1), .unsaved(pendingChanges: 2), .saving, .saved(at: now.addingTimeInterval(0.5), latency: 0)])
        let pending = await scheduler.pendingEditCount
        XCTAssertEqual(pending, 0)
        await scheduler.shutdown()
    }

    func testCommitHappensNoLaterThanOneSecondAfterFirstEdit() async throws {
        let clock = ManualClock(start: now), sleeper = ManualSleeper(), probe = CommitProbe(), log = StatusLog()
        let scheduler = makeScheduler(clock: clock, sleeper: sleeper, probe: probe, log: log)
        await scheduler.noteEdit()               // t = 0
        await expectSleeping(sleeper)
        for step in 1...4 {                      // edits at 0.2, 0.4, 0.6, 0.8: each within 0.3 s of the previous
            clock.advance(by: 0.2)
            await scheduler.noteEdit()
            sleeper.wake()
            await expectSleeping(sleeper, "step \(step)")
            XCTAssertEqual(probe.count, 0, "step \(step): debounce keeps extending")
        }
        XCTAssertEqual(sleeper.requestedIntervals.last!, 0.2, accuracy: tolerance, "deadline is capped at first edit + 1 s")
        clock.advance(by: 0.2)                   // t = 1.0
        sleeper.wake()
        await waitUntil("commit") { probe.count == 1 }
        assertDates(probe.commitTimes, [now.addingTimeInterval(1.0)])
        await waitUntil("saved") { await scheduler.status.isDurable }
        assertStatus(log.all.last, .saved(at: now.addingTimeInterval(1.0), latency: 0))
        await scheduler.shutdown()
    }

    func testFlushCommitsImmediatelyAndSavedIsReportedOnlyAfterCommitReturns() async throws {
        let clock = ManualClock(start: now), sleeper = ManualSleeper(), probe = CommitProbe(), log = StatusLog()
        let scheduler = makeScheduler(clock: clock, sleeper: sleeper, probe: probe, log: log)
        probe.blocks = true
        await scheduler.noteEdit()
        await expectSleeping(sleeper)
        let flush = Task { try await scheduler.flush() }
        await waitUntil("saving") { await scheduler.status == .saving }
        XCTAssertEqual(sleeper.sleepingCount, 0, "flush cancels the timer")
        XCTAssertEqual(probe.count, 0)
        let mid = await scheduler.status
        XCTAssertEqual(mid, .saving, "not saved while the commit is still running")
        clock.advance(by: 0.04)
        probe.openGate()
        try await flush.value
        let final = await scheduler.status
        assertStatus(final, .saved(at: now.addingTimeInterval(0.04), latency: 0.04))
        assertStatuses(log.all, [.unsaved(pendingChanges: 1), .saving, .saved(at: now.addingTimeInterval(0.04), latency: 0.04)])
        XCTAssertEqual(probe.count, 1)
        let lastLatency = await scheduler.lastLatency
        XCTAssertEqual(lastLatency ?? -1, 0.04, accuracy: tolerance)
        // Flushing with nothing pending is a no-op.
        try await scheduler.flush()
        XCTAssertEqual(probe.count, 1)
        await scheduler.shutdown()
    }

    func testFailureReportsFailedKeepsEditsPendingAndLaterFlushRetries() async throws {
        let clock = ManualClock(start: now), sleeper = ManualSleeper(), probe = CommitProbe(), log = StatusLog()
        let scheduler = makeScheduler(clock: clock, sleeper: sleeper, probe: probe, log: log)
        probe.failuresRemaining = 1
        await scheduler.noteEdit()
        await scheduler.noteEdit()
        do { try await scheduler.flush(); XCTFail("expected failure") }
        catch let error as PersistenceError { XCTAssertEqual(error, .diskFull) }
        let failed = await scheduler.status
        XCTAssertEqual(failed, .failed(message: PersistenceError.diskFull.description, retryable: true))
        let pendingAfterFailure = await scheduler.pendingEditCount
        XCTAssertEqual(pendingAfterFailure, 2, "edits stay pending for the retry")
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(sleeper.sleepingCount, 0, "no automatic retry loop")

        clock.advance(by: 5)
        try await scheduler.flush()
        XCTAssertEqual(probe.count, 1)
        let pendingAfterRetry = await scheduler.pendingEditCount
        XCTAssertEqual(pendingAfterRetry, 0)
        assertStatuses(log.all, [.unsaved(pendingChanges: 1), .unsaved(pendingChanges: 2), .saving,
                                 .failed(message: PersistenceError.diskFull.description, retryable: true),
                                 .saving, .saved(at: now.addingTimeInterval(5), latency: 0)])
        // Edits after a failure restart the timer and the timer-driven commit succeeds too.
        probe.failuresRemaining = 1
        await scheduler.noteEdit()
        do { try await scheduler.flush() } catch {}
        await scheduler.noteEdit()
        await expectSleeping(sleeper)
        clock.advance(by: 1)
        sleeper.wake()
        await waitUntil("retry commit") { probe.count == 2 }
        let pendingAfterTimer = await scheduler.pendingEditCount
        XCTAssertEqual(pendingAfterTimer, 0)
        await scheduler.shutdown()
    }

    func testEditsDuringACommitRemainPendingAndStatusStreamDelivers() async throws {
        let clock = ManualClock(start: now), sleeper = ManualSleeper(), probe = CommitProbe(), log = StatusLog()
        let scheduler = makeScheduler(clock: clock, sleeper: sleeper, probe: probe, log: log)
        let stream = scheduler.statusUpdates
        let collector = Task { var out: [SaveStatus] = []; for await s in stream { out.append(s) }; return out }
        probe.blocks = true
        await scheduler.noteEdit()
        let flush = Task { try await scheduler.flush() }
        await waitUntil("saving") { await scheduler.status == .saving }
        await scheduler.noteEdit()                 // arrives while the commit runs
        probe.openGate()
        try await flush.value
        let pendingMidCommit = await scheduler.pendingEditCount
        XCTAssertEqual(pendingMidCommit, 1)
        let statusAfterFlush = await scheduler.status
        assertStatus(statusAfterFlush, .saved(at: now, latency: 0))
        await expectSleeping(sleeper, "a timer was started for the edit that arrived mid-commit")
        probe.blocks = false
        clock.advance(by: 1)
        sleeper.wake()
        await waitUntil("second commit") { probe.count == 2 }
        await scheduler.shutdown()
        let delivered = await collector.value
        XCTAssertEqual(delivered, log.all)
        XCTAssertEqual(delivered.filter { $0 == .saving }.count, 2)
    }
}
