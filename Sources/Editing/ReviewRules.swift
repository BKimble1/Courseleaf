import Foundation
import DocumentCore

/// Pure rules for Problem Pages and the review queue. They produce values;
/// the editor applies them through commands so every change is undoable and
/// part of the snapshot.
public enum ReviewRules {

    // MARK: Problem status

    /// The next status when the student taps the status control: unfinished → check again → understood → unfinished.
    public static func cycleStatus(_ status: ProblemStatus) -> ProblemStatus {
        switch status {
        case .unfinished: return .checkAgain
        case .checkAgain: return .understood
        case .understood: return .unfinished
        }
    }

    // MARK: Review items

    /// A pending review item for a page or region, created at `now` with an `added` event.
    public static func makeReviewItem(pageID: PageID, region: PageRect? = nil, prompt: String? = nil,
                                      answerTapeID: ObjectID? = nil, now: Date) -> ReviewItem {
        ReviewItem(pageID: pageID, region: region?.standardized, prompt: normalized(prompt),
                   answerTapeID: answerTapeID, state: .pending, createdAt: now)
    }

    /// Records that the item's answer tape was revealed or hidden. Recorded by the
    /// editor when `setTapeRevealed` changes the state of the item's `answerTapeID`.
    public static func recordingReveal(_ item: ReviewItem, revealed: Bool, at: Date) -> ReviewItem {
        var result = item
        result.history.append(ReviewEvent(action: revealed ? .revealed : .hidden, at: at))
        return result
    }

    /// Marks the item reviewed: state `reviewed`, `lastReviewedAt = at`, plus a
    /// `markedReviewed` event. Reviewing an already reviewed item records another
    /// pass (the student repeated it).
    public static func markingReviewed(_ item: ReviewItem, at: Date) -> ReviewItem {
        var result = item
        result.state = .reviewed
        result.lastReviewedAt = at
        result.history.append(ReviewEvent(action: .markedReviewed, at: at))
        return result
    }

    /// Puts a reviewed item back in the queue with a `reopened` event. An item that
    /// is already pending is returned unchanged (no event).
    public static func reopening(_ item: ReviewItem, at: Date) -> ReviewItem {
        guard item.state == .reviewed else { return item }
        var result = item
        result.state = .pending
        result.history.append(ReviewEvent(action: .reopened, at: at))
        return result
    }

    /// Replaces the prompt, recording a `promptEdited` event when it actually changed.
    public static func editingPrompt(_ item: ReviewItem, prompt: String?, at: Date) -> ReviewItem {
        let new = normalized(prompt)
        guard new != item.prompt else { return item }
        var result = item
        result.prompt = new
        result.history.append(ReviewEvent(action: .promptEdited, at: at))
        return result
    }

    private static func normalized(_ prompt: String?) -> String? {
        guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p
    }

    // MARK: Queue listing

    /// Pending review items of a snapshot's *live* pages, ordered by page position,
    /// then creation time, then ID. Items of deleted (trashed) pages are kept in the
    /// document but hidden from the queue until the page is restored; purging the
    /// page is the moment to remove them (`itemsOfDeletedPages`).
    public static func pendingItems(in snapshot: DocumentSnapshot) -> [ReviewItem] {
        items(in: snapshot).filter { $0.state == .pending }
    }

    /// Every review item (any state) of the snapshot's live pages in queue order.
    public static func items(in snapshot: DocumentSnapshot) -> [ReviewItem] {
        var position: [PageID: Int] = [:]
        for (i, id) in snapshot.document.pageIDs.enumerated() where position[id] == nil { position[id] = i }
        return snapshot.document.reviewItems
            .filter { position[$0.pageID] != nil }
            .sorted { a, b in
                let pa = position[a.pageID]!, pb = position[b.pageID]!
                if pa != pb { return pa < pb }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            }
    }

    /// Review items (any state) of one page, in creation order.
    public static func items(in snapshot: DocumentSnapshot, forPage pageID: PageID) -> [ReviewItem] {
        snapshot.document.reviewItems.filter { $0.pageID == pageID }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
    }

    /// Items whose page is in `document.deletedPages` (hidden from the queue).
    public static func itemsOfDeletedPages(in snapshot: DocumentSnapshot) -> [ReviewItem] {
        let deleted = Set(snapshot.document.deletedPages.map(\.id))
        return snapshot.document.reviewItems.filter { deleted.contains($0.pageID) }
    }

    /// Number of pending items on live pages; what the library shows as the document's review badge.
    public static func pendingCount(in snapshot: DocumentSnapshot) -> Int { pendingItems(in: snapshot).count }
}
