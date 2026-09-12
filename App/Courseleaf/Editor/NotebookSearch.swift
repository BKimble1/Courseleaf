import Foundation
import SwiftUI
import PDFKit
import DocumentCore
import PageGeometry
import Editing
import Workspace

// "Search in Notebook": the open document only, answered from what is already
// in memory or in the page's source PDF. Library-wide search (which also
// covers handwriting recognition records) lives in the catalog; this is the
// in-editor jump-to-a-page companion to it, so it never waits for indexing.

struct NotebookSearchHit: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case text, tape, problem, pdfText

        var title: String {
            switch self {
            case .text: return "Text box"
            case .tape: return "Tape"
            case .problem: return "Problem"
            case .pdfText: return "PDF text"
            }
        }

        var symbolName: String {
            switch self {
            case .text: return "textformat"
            case .tape: return "rectangle.fill"
            case .problem: return "function"
            case .pdfText: return "doc.text"
            }
        }

        var order: Int {
            switch self {
            case .problem: return 0
            case .text: return 1
            case .tape: return 2
            case .pdfText: return 3
            }
        }
    }

    var id: String
    var pageID: PageID
    var pageIndex: Int
    var kind: Kind
    var snippet: String
    var bounds: PageRect?
}

enum NotebookSearch {
    static let comparisonOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Matches in the document's own typed content. Pure, so it is testable
    /// without PDFKit or a live session.
    static func documentHits(query: String, snapshot: DocumentSnapshot, limit: Int = 200) -> [NotebookSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        var hits: [NotebookSearchHit] = []
        for (index, page) in snapshot.orderedPages.enumerated() {
            if hits.count >= limit { break }
            if let problem = page.problem {
                let fields: [String] = [problem.title, problem.sourceReference ?? "", problem.given ?? "", problem.find ?? ""]
                for (field, value) in fields.enumerated() where value.range(of: needle, options: comparisonOptions) != nil {
                    hits.append(NotebookSearchHit(id: "\(page.id)-problem-\(field)", pageID: page.id, pageIndex: index,
                                                  kind: .problem, snippet: snippet(of: value, around: needle),
                                                  bounds: problem.resultRegion))
                }
            }
            for object in page.objects {
                switch object.content {
                case .text(let content):
                    guard content.text.range(of: needle, options: comparisonOptions) != nil else { continue }
                    hits.append(NotebookSearchHit(id: "\(page.id)-\(object.id)", pageID: page.id, pageIndex: index,
                                                  kind: .text, snippet: snippet(of: content.text, around: needle),
                                                  bounds: object.bounds))
                case .tape(let content):
                    guard let label = content.label, label.range(of: needle, options: comparisonOptions) != nil else { continue }
                    hits.append(NotebookSearchHit(id: "\(page.id)-\(object.id)", pageID: page.id, pageIndex: index,
                                                  kind: .tape, snippet: snippet(of: label, around: needle),
                                                  bounds: object.bounds))
                case .image, .shape:
                    continue
                }
            }
        }
        return hits
    }

    /// Matches in the text layer of imported PDF pages, with bounds mapped from
    /// PDF user space into page space (§3) so the hit can be highlighted.
    @MainActor
    static func pdfHits(query: String, snapshot: DocumentSnapshot, loader: PageContentLoader, limit: Int = 200) async -> [NotebookSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        struct Placement {
            var pdfPageIndex: Int
            var pageIndex: Int
            var pageID: PageID
            var source: PDFPageSource
        }
        var byAsset: [AssetID: [Placement]] = [:]
        var assetOrder: [AssetID] = []
        for (index, page) in snapshot.orderedPages.enumerated() {
            guard case .pdf(let source) = page.background else { continue }
            if byAsset[source.assetID] == nil { assetOrder.append(source.assetID) }
            byAsset[source.assetID, default: []].append(
                Placement(pdfPageIndex: source.pageIndex, pageIndex: index, pageID: page.id, source: source))
        }
        var hits: [NotebookSearchHit] = []
        for assetID in assetOrder {
            if hits.count >= limit { break }
            guard let placements = byAsset[assetID], let document = await loader.pdfDocument(for: assetID) else { continue }
            guard !Task.isCancelled else { return hits }
            var seen = 0
            for selection in document.findString(needle, withOptions: .caseInsensitive) {
                guard hits.count < limit else { break }
                guard let pdfPage = selection.pages.first else { continue }
                let pdfIndex = document.index(for: pdfPage)
                guard let placement = placements.first(where: { $0.pdfPageIndex == pdfIndex }) else { continue }
                let userBounds = selection.bounds(for: pdfPage)
                let mapping = PageMapping(source: placement.source)
                var region: PageRect?
                if userBounds.width > 0, userBounds.height > 0 {
                    region = mapping.pageRect(fromPDFUser: PageRect(userBounds)).intersection(mapping.pageBounds)
                }
                let line = pdfPage.selectionForLine(at: CGPoint(x: userBounds.midX, y: userBounds.midY))?.string
                let text = (line ?? selection.string ?? needle).trimmingCharacters(in: .whitespacesAndNewlines)
                seen += 1
                hits.append(NotebookSearchHit(id: "\(placement.pageID)-pdf-\(seen)", pageID: placement.pageID,
                                              pageIndex: placement.pageIndex, kind: .pdfText,
                                              snippet: snippet(of: text, around: needle), bounds: region))
            }
        }
        return hits
    }

    /// A short excerpt centred on the match.
    static func snippet(of text: String, around needle: String, context: Int = 40) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = collapsed.range(of: needle, options: comparisonOptions) else {
            return String(collapsed.prefix(2 * context))
        }
        let lower = collapsed.index(range.lowerBound, offsetBy: -context, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let upper = collapsed.index(range.upperBound, offsetBy: context, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        var excerpt = String(collapsed[lower..<upper])
        if lower != collapsed.startIndex { excerpt = "…" + excerpt }
        if upper != collapsed.endIndex { excerpt += "…" }
        return excerpt
    }
}

// MARK: - View

struct NotebookSearchView: View {
    let session: any DocumentSessioning
    let loader: PageContentLoader?
    var onSelect: (NotebookSearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [NotebookSearchHit] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                } else if hits.isEmpty, hasSearched {
                    Text("No matches in this notebook.")
                        .foregroundStyle(.secondary)
                } else if hits.isEmpty {
                    Text("Search typed text, tape labels, Problem Pages and the text of imported PDFs. Handwriting is searched from the library screen once it has been recognized.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    Button {
                        onSelect(hit)
                        dismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: hit.kind.symbolName)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.snippet)
                                    .font(.body)
                                    .lineLimit(3)
                                Text("Page \(hit.pageIndex + 1) · \(hit.kind.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(hit.kind.title) on page \(hit.pageIndex + 1): \(hit.snippet)")
                    .accessibilityHint("Double tap to show this page")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search in Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find in this notebook")
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await runSearch()
            }
        }
    }

    @MainActor
    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            hits = []
            hasSearched = false
            isSearching = false
            return
        }
        isSearching = true
        let snapshot = session.editor.snapshot
        var results = NotebookSearch.documentHits(query: text, snapshot: snapshot)
        if let loader {
            results += await NotebookSearch.pdfHits(query: text, snapshot: snapshot, loader: loader)
        }
        guard !Task.isCancelled else { return }
        hits = results.sorted { ($0.pageIndex, $0.kind.order) < ($1.pageIndex, $1.kind.order) }
        hasSearched = true
        isSearching = false
    }
}
