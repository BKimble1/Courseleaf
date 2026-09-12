import Foundation
import Observation
import DocumentCore
import Workspace

/// Runs searches and keeps the index state visible, so "no matches" is never
/// confused with "not indexed yet" (docs/PRODUCT_SPEC.md §3.5).
@MainActor
@Observable
final class SearchViewModel {
    struct Group: Identifiable {
        var documentID: DocumentID
        var documentTitle: String
        var hits: [SearchHit]
        var id: DocumentID { documentID }
    }

    var query: String = ""
    var scope: SearchScope = .library
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var unavailableReason: String?
    /// True once a search has run, so the empty state can tell the two cases apart.
    private(set) var hasSearched = false

    @ObservationIgnored private weak var env: AppEnvironment?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func configure(env: AppEnvironment) {
        if self.env !== env { self.env = env }
    }

    /// Groups hits by notebook, keeping the service's ordering.
    var groups: [Group] {
        guard let results else { return [] }
        var order: [DocumentID] = []
        var byDocument: [DocumentID: Group] = [:]
        for hit in results.hits {
            if byDocument[hit.documentID] == nil {
                order.append(hit.documentID)
                byDocument[hit.documentID] = Group(documentID: hit.documentID, documentTitle: hit.documentTitle, hits: [])
            }
            byDocument[hit.documentID]?.hits.append(hit)
        }
        return order.compactMap { byDocument[$0] }
    }

    var notYetIndexedCount: Int { results?.notYetIndexedPageCount ?? 0 }
    var failedCount: Int { results?.failedPageCount ?? 0 }
    var isIndexing: Bool { results?.isIndexingInProgress ?? false }

    /// Debounced search; an empty query clears the results.
    func search(debounceMilliseconds: Int = 250) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = nil
            hasSearched = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.run(text)
        }
    }

    private func run(_ text: String) async {
        guard let env else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await env.library.search(text, scope: scope)
            unavailableReason = nil
        } catch let error as WorkspaceError {
            if case .catalogUnavailable(let reason) = error {
                results = nil
                unavailableReason = reason
            } else {
                env.present(error, title: "The search could not be run")
            }
        } catch {
            env.present(error, title: "The search could not be run")
        }
        hasSearched = true
    }
}

enum SearchKindText {
    static func title(_ kind: SearchRecordKind) -> String {
        switch kind {
        case .title: return "Title"
        case .typed: return "Typed"
        case .pdfText: return "PDF text"
        case .recognized: return "Handwriting"
        }
    }

    static func hint(_ kind: SearchRecordKind) -> String {
        switch kind {
        case .title: return "Matched the notebook title"
        case .typed: return "Matched text you typed in a text box"
        case .pdfText: return "Matched real text in an imported PDF"
        case .recognized: return "Matched on-device handwriting recognition, which is best effort"
        }
    }
}
