import XCTest
import DocumentCore
@testable import Editing

final class ReviewRulesTests: XCTestCase {

    func testCycleStatusVisitsEveryStatusInOrder() {
        XCTAssertEqual(ReviewRules.cycleStatus(.unfinished), .checkAgain)
        XCTAssertEqual(ReviewRules.cycleStatus(.checkAgain), .understood)
        XCTAssertEqual(ReviewRules.cycleStatus(.understood), .unfinished)
        var status = ProblemStatus.unfinished
        var seen: [ProblemStatus] = []
        for _ in ProblemStatus.allCases { seen.append(status); status = ReviewRules.cycleStatus(status) }
        XCTAssertEqual(Set(seen), Set(ProblemStatus.allCases))
        XCTAssertEqual(status, .unfinished)
    }

    func testMakeReviewItemNormalizesRegionAndPrompt() {
        let now = EditingFixture.start
        let pageID = PageID()
        let item = ReviewRules.makeReviewItem(pageID: pageID, region: PageRect(x: 100, y: 100, width: -50, height: -20), prompt: "   ", now: now)
        XCTAssertEqual(item.pageID, pageID)
        XCTAssertEqual(item.region, PageRect(x: 50, y: 80, width: 50, height: 20))
        XCTAssertNil(item.prompt, "blank prompts are stored as nil")
        XCTAssertNil(item.answerTapeID)
        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(item.createdAt, now)
        XCTAssertNil(item.lastReviewedAt)
        XCTAssertEqual(item.history, [ReviewEvent(action: .added, at: now)])
        let whole = ReviewRules.makeReviewItem(pageID: pageID, now: now)
        XCTAssertNil(whole.region)
        XCTAssertNotEqual(whole.id, item.id)
    }

    func testEventRecordingRules() {
        let t0 = EditingFixture.start
        let item = ReviewRules.makeReviewItem(pageID: PageID(), prompt: "p", answerTapeID: ObjectID(), now: t0)

        let revealed = ReviewRules.recordingReveal(item, revealed: true, at: t0.addingTimeInterval(1))
        XCTAssertEqual(revealed.history.map(\.action), [.added, .revealed])
        XCTAssertEqual(revealed.state, .pending)
        let hidden = ReviewRules.recordingReveal(revealed, revealed: false, at: t0.addingTimeInterval(2))
        XCTAssertEqual(hidden.history.map(\.action), [.added, .revealed, .hidden])
        XCTAssertEqual(hidden.history.last?.at, t0.addingTimeInterval(2))

        let reviewed = ReviewRules.markingReviewed(hidden, at: t0.addingTimeInterval(3))
        XCTAssertEqual(reviewed.state, .reviewed)
        XCTAssertEqual(reviewed.lastReviewedAt, t0.addingTimeInterval(3))
        XCTAssertEqual(reviewed.history.last, ReviewEvent(action: .markedReviewed, at: t0.addingTimeInterval(3)))
        let again = ReviewRules.markingReviewed(reviewed, at: t0.addingTimeInterval(4))
        XCTAssertEqual(again.lastReviewedAt, t0.addingTimeInterval(4), "a repeated pass is recorded")
        XCTAssertEqual(again.history.filter { $0.action == .markedReviewed }.count, 2)

        XCTAssertEqual(ReviewRules.reopening(hidden, at: t0.addingTimeInterval(5)), hidden, "reopening a pending item is a no-op")
        let reopened = ReviewRules.reopening(again, at: t0.addingTimeInterval(5))
        XCTAssertEqual(reopened.state, .pending)
        XCTAssertEqual(reopened.lastReviewedAt, t0.addingTimeInterval(4), "last review time is kept")
        XCTAssertEqual(reopened.history.last, ReviewEvent(action: .reopened, at: t0.addingTimeInterval(5)))

        XCTAssertEqual(ReviewRules.editingPrompt(reopened, prompt: " p ", at: t0.addingTimeInterval(6)), reopened, "unchanged prompt: no event")
        let edited = ReviewRules.editingPrompt(reopened, prompt: "q", at: t0.addingTimeInterval(6))
        XCTAssertEqual(edited.prompt, "q")
        XCTAssertEqual(edited.history.last, ReviewEvent(action: .promptEdited, at: t0.addingTimeInterval(6)))
        let cleared = ReviewRules.editingPrompt(edited, prompt: "", at: t0.addingTimeInterval(7))
        XCTAssertNil(cleared.prompt)
        XCTAssertEqual(cleared.history.count, edited.history.count + 1)
    }

    func testQueueListingOrdersByPageThenCreationAndHidesDeletedPages() {
        var snap = EditingFixture.snapshot(pageCount: 3)
        let ids = snap.document.pageIDs
        let t0 = EditingFixture.start
        let p2a = ReviewRules.makeReviewItem(pageID: ids[2], now: t0.addingTimeInterval(5))
        let p2b = ReviewRules.makeReviewItem(pageID: ids[2], now: t0.addingTimeInterval(1))
        let p0 = ReviewRules.makeReviewItem(pageID: ids[0], now: t0.addingTimeInterval(9))
        let p1 = ReviewRules.makeReviewItem(pageID: ids[1], now: t0)
        let done = ReviewRules.markingReviewed(ReviewRules.makeReviewItem(pageID: ids[1], now: t0.addingTimeInterval(0.5)), at: t0.addingTimeInterval(2))
        snap.document.reviewItems = [p2a, done, p0, p2b, p1]

        XCTAssertEqual(ReviewRules.items(in: snap).map(\.id), [p0.id, p1.id, done.id, p2b.id, p2a.id])
        XCTAssertEqual(ReviewRules.pendingItems(in: snap).map(\.id), [p0.id, p1.id, p2b.id, p2a.id])
        XCTAssertEqual(ReviewRules.pendingCount(in: snap), 4)
        XCTAssertEqual(ReviewRules.items(in: snap, forPage: ids[2]).map(\.id), [p2b.id, p2a.id])
        XCTAssertTrue(ReviewRules.itemsOfDeletedPages(in: snap).isEmpty)

        // Move page 2 to the front: its items lead the queue.
        snap.document.pageIDs = [ids[2], ids[0], ids[1]]
        XCTAssertEqual(ReviewRules.pendingItems(in: snap).map(\.id), [p2b.id, p2a.id, p0.id, p1.id])

        // Delete page 2 (as the editor does): items are hidden but retained.
        let deleted = snap.pages.removeValue(forKey: ids[2])!
        snap.document.pageIDs = [ids[0], ids[1]]
        snap.document.deletedPages = [DeletedPage(page: deleted, originalIndex: 0, deletedAt: t0)]
        XCTAssertEqual(ReviewRules.pendingItems(in: snap).map(\.id), [p0.id, p1.id])
        XCTAssertEqual(Set(ReviewRules.itemsOfDeletedPages(in: snap).map(\.id)), [p2a.id, p2b.id])
        XCTAssertEqual(snap.document.reviewItems.count, 5)
        XCTAssertTrue(snap.validate().isEmpty, "\(snap.validate())")
    }
}
