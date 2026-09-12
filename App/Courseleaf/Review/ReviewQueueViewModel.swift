import Foundation
import Observation
import DocumentCore
import Editing
import Workspace

/// The manual review queue: pending items for one course or for everything.
/// It is a list the student built by hand — there is no scheduler and no due
/// dates (docs/PRODUCT_SPEC.md §3.4).
@MainActor
@Observable
final class ReviewQueueViewModel {
    private(set) var entries: [ReviewQueueEntry] = []
    private(set) var courses: [Folder] = []
    private(set) var isLoading = false
    /// nil means every course and every unfiled notebook.
    var selectedCourseID: FolderID?
    /// Reviewed items are hidden by default; the queue is about what is pending.
    var showsReviewed = false

    @ObservationIgnored private weak var env: AppEnvironment?

    func configure(env: AppEnvironment) {
        if self.env !== env { self.env = env }
    }

    func load() async {
        guard let env else { return }
        isLoading = true
        defer { isLoading = false }
        let manifest = await env.perform("The courses could not be read") { try await env.library.manifest() }
        courses = (manifest?.folders ?? []).filter(\.isCourse).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        entries = await env.perform("The review queue could not be read") {
            try await env.library.reviewQueue(courseID: selectedCourseID)
        } ?? []
    }

    var visibleEntries: [ReviewQueueEntry] {
        showsReviewed ? entries : entries.filter { $0.item.state == .pending }
    }

    var pendingCount: Int { entries.filter { $0.item.state == .pending }.count }

    // MARK: Actions

    func markReviewed(_ entry: ReviewQueueEntry) async {
        guard let env else { return }
        await env.perform("That item could not be marked as reviewed") {
            try await env.library.markReviewed(entry.item.id, in: entry.documentID)
        }
        await load()
    }

    func reopen(_ entry: ReviewQueueEntry) async {
        guard let env else { return }
        await env.perform("That item could not be reopened") {
            try await env.library.reopenReview(entry.item.id, in: entry.documentID)
        }
        await load()
    }

    /// Reveals or hides the answer tape linked to a review item. Items without
    /// a tape have nothing to reveal; the caller explains that.
    func setTapeRevealed(_ revealed: Bool, for entry: ReviewQueueEntry) async -> Bool {
        guard let env, let tapeID = entry.item.answerTapeID else { return false }
        do {
            let session = try await env.session(for: entry.documentID)
            try session.performGrouped(revealed ? "Reveal Answer" : "Hide Answer") {
                try session.apply(.setTapeRevealed(entry.item.pageID, tapeID, revealed))
            }
            try await session.flush()
            return true
        } catch {
            env.present(error, title: revealed ? "The answer could not be revealed" : "The answer could not be covered")
            return false
        }
    }

    /// Current revealed state of the item's answer tape, read from the document.
    func isTapeRevealed(_ entry: ReviewQueueEntry) async -> Bool? {
        guard let env, let tapeID = entry.item.answerTapeID else { return nil }
        guard let session = try? await env.session(for: entry.documentID) else { return nil }
        guard let page = session.editor.page(entry.item.pageID), let object = page.object(tapeID),
              case .tape(let content) = object.content else { return nil }
        return content.isRevealed
    }
}
