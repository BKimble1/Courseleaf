import SwiftUI
import DocumentCore
import Editing
import Workspace

/// The Problem Inspector for one page: the problem's details, its result
/// region, and the review items that point at it. Every change is applied to
/// the open session as one undoable operation.
///
/// The editor injects `currentSelectionBounds` and `drawRegion`; without them
/// (previews, tests) the region actions explain what to do instead.
struct ProblemInspectorView: View {
    let session: any DocumentSessioning
    let pageID: PageID
    /// Bounds of what is selected on the page right now, in page points.
    var currentSelectionBounds: (() -> PageRect?)? = nil
    /// Lets the student drag a rectangle on the page; nil means "not available here".
    var drawRegion: ((@escaping (PageRect?) -> Void) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isProblemPage = false
    @State private var metadata = ProblemMetadata(title: "")
    @State private var prompt = ""
    @State private var coversResultWithTape = true
    @State private var reviewItems: [ReviewItem] = []
    @State private var message: String? = nil
    @State private var isConfirmingTurnOff = false

    /// The editor calls `ProblemInspectorView(session:pageID:)`; the extra
    /// closures are wired in by the notebook screen when the page is on screen.
    init(session: any DocumentSessioning,
         pageID: PageID,
         currentSelectionBounds: (() -> PageRect?)? = nil,
         drawRegion: ((@escaping (PageRect?) -> Void) -> Void)? = nil) {
        self.session = session
        self.pageID = pageID
        self.currentSelectionBounds = currentSelectionBounds
        self.drawRegion = drawRegion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Problem Page", isOn: Binding(get: { isProblemPage }, set: { setProblemPage($0) }))
                        .accessibilityHint("Adds a title, source, given, find, a result region and a status to this page")
                } footer: {
                    Text("A Problem Page is an ordinary page with a few extra fields you fill in yourself. Nothing is recognized or graded.")
                }

                if isProblemPage {
                    detailsSection
                    resultRegionSection
                    reviewSection
                    existingItemsSection
                }
            }
            .navigationTitle("Problem Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { applyMetadata(); dismiss() }
                        .disabled(!isProblemPage)
                }
            }
            .task { load() }
            .alert("Turn off Problem Page?", isPresented: $isConfirmingTurnOff) {
                Button("Cancel", role: .cancel) {}
                Button("Turn Off", role: .destructive) { clearProblem() }
            } message: {
                Text("The title, source, given, find, result region and status are removed. The page and everything drawn on it stay. You can undo this in the editor.")
            }
            .alert("Note", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: Sections

    private var detailsSection: some View {
        Section("Problem") {
            TextField("Title", text: Binding(get: { metadata.title }, set: { metadata.title = $0 }))
                .accessibilityLabel("Problem title")
            TextField("Source reference (book, sheet, question)",
                      text: Binding(get: { metadata.sourceReference ?? "" }, set: { metadata.sourceReference = $0.isEmpty ? nil : $0 }))
                .accessibilityLabel("Source reference")
            TextField("Given", text: Binding(get: { metadata.given ?? "" }, set: { metadata.given = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel("Given")
            TextField("Find", text: Binding(get: { metadata.find ?? "" }, set: { metadata.find = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel("Find")
            Picker("Status", selection: Binding(get: { metadata.status }, set: { status in
                metadata.status = status
                applyStatus(status)
            })) {
                ForEach(ProblemStatus.allCases, id: \.self) { status in
                    Text(ProblemStatusText.title(status)).tag(status)
                }
            }
            .accessibilityLabel("Status")
        }
    }

    private var resultRegionSection: some View {
        Section {
            if let region = metadata.resultRegion {
                LabeledContent("Region", value: regionDescription(region))
            } else {
                Text("No result region set yet.").detailTextStyle()
            }
            Button {
                useCurrentSelection()
            } label: {
                Label("Use Current Selection", systemImage: "selection.pin.in.out")
            }
            .accessibilityHint("Uses what is selected on the page as the result region")
            Button {
                startDrawingRegion()
            } label: {
                Label("Draw Region on the Page", systemImage: "rectangle.dashed")
            }
            .accessibilityHint("Drag a rectangle around the result on the page")
            if metadata.resultRegion != nil {
                Button(role: .destructive) {
                    metadata.resultRegion = nil
                    applyMetadata()
                } label: {
                    Label("Clear Region", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("Result Region")
        } footer: {
            Text("The result region is the part of the page holding your answer. It is what a tape covers and what a review item points at.")
        }
    }

    private var reviewSection: some View {
        Section {
            TextField("Prompt (optional), e.g. “Which test settles convergence here?”", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityLabel("Review prompt")
            Toggle("Cover the result with tape", isOn: $coversResultWithTape)
                .disabled(metadata.resultRegion == nil)
                .accessibilityHint(metadata.resultRegion == nil
                                   ? "Set a result region first"
                                   : "Adds an opaque tape over the result so you can recall it before checking")
            Button {
                addToReviewQueue()
            } label: {
                Label("Add to Review Queue", systemImage: "plus.circle")
            }
        } header: {
            Text("Review")
        } footer: {
            Text("The review queue is a manual list you build yourself. It has no schedule and nothing is ever due.")
        }
    }

    private var existingItemsSection: some View {
        Section("Review Items on This Page") {
            if reviewItems.isEmpty {
                Text("None yet.").detailTextStyle()
            }
            ForEach(reviewItems, id: \.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.prompt ?? (item.region == nil ? "Whole page" : "Region of the page"))
                        .font(Typography.body)
                    Text("\(item.state == .pending ? "Pending" : "Reviewed") · added \(DateText.short(item.createdAt))\(item.answerTapeID != nil ? " · has answer tape" : "")")
                        .detailTextStyle()
                }
                .accessibilityElement(children: .combine)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        removeReviewItem(item)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: Loading and mutations

    private func load() {
        let page = session.editor.page(pageID)
        if let problem = page?.problem {
            isProblemPage = true
            metadata = problem
        } else {
            isProblemPage = false
            metadata = ProblemMetadata(title: "")
        }
        coversResultWithTape = metadata.resultRegion != nil
        refreshReviewItems()
    }

    private func refreshReviewItems() {
        reviewItems = ReviewRules.items(in: session.editor.snapshot, forPage: pageID)
    }

    private func setProblemPage(_ on: Bool) {
        if on {
            isProblemPage = true
            if metadata.title.isEmpty { metadata.title = defaultTitle() }
            applyMetadata()
        } else {
            isConfirmingTurnOff = true
        }
    }

    private func defaultTitle() -> String {
        if let index = session.editor.snapshot.pageIndex(pageID) { return "Problem on page \(index + 1)" }
        return "Problem"
    }

    private func applyMetadata() {
        guard isProblemPage else { return }
        var value = metadata
        if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.title = defaultTitle() }
        perform("Edit Problem") { try session.apply(.setProblem(pageID, value)) }
        metadata = value
    }

    private func applyStatus(_ status: ProblemStatus) {
        guard isProblemPage, session.editor.page(pageID)?.problem != nil else { applyMetadata(); return }
        perform("Set Problem Status") { try session.apply(.setProblemStatus(pageID, status)) }
    }

    private func clearProblem() {
        isProblemPage = false
        metadata = ProblemMetadata(title: "")
        perform("Turn Off Problem Page") { try session.apply(.setProblem(pageID, nil)) }
    }

    private func useCurrentSelection() {
        guard let bounds = currentSelectionBounds?() else {
            message = "Nothing is selected on the page. Pick the lasso, select the result, then use this again."
            return
        }
        metadata.resultRegion = bounds
        applyMetadata()
    }

    private func startDrawingRegion() {
        guard let drawRegion else {
            message = "Drawing a region needs the page in view. Close this panel, select the result with the lasso, then use “Use Current Selection”."
            return
        }
        dismiss()
        drawRegion { rect in
            guard let rect else { return }
            var value = metadata
            value.resultRegion = rect.standardized
            if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.title = defaultTitle() }
            perform("Set Result Region") { try session.apply(.setProblem(pageID, value)) }
        }
    }

    private func addToReviewQueue() {
        let now = Date()
        let region = metadata.resultRegion
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsTape = coversResultWithTape && region != nil
        perform("Add to Review Queue") {
            var tapeID: ObjectID?
            if wantsTape, let region {
                let tape = CanvasObject(frame: region.standardized, content: .tape(TapeContent()), createdAt: now)
                try session.apply(.addObject(pageID, tape, at: nil))
                tapeID = tape.id
            }
            let item = ReviewRules.makeReviewItem(pageID: pageID, region: region,
                                                  prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
                                                  answerTapeID: tapeID, now: now)
            try session.apply(.addReviewItem(item))
        }
        prompt = ""
        refreshReviewItems()
    }

    private func removeReviewItem(_ item: ReviewItem) {
        perform("Remove Review Item") { try session.apply(.removeReviewItem(item.id)) }
        refreshReviewItems()
    }

    /// One undo step per user action.
    private func perform(_ name: String, _ body: () throws -> Void) {
        do {
            try session.performGrouped(name, body)
        } catch {
            message = AppErrorText.message(for: error)
        }
    }

    private func regionDescription(_ region: PageRect) -> String {
        let r = region.standardized
        return String(format: "%.0f × %.0f pt at (%.0f, %.0f)", r.width, r.height, r.minX, r.minY)
    }
}
