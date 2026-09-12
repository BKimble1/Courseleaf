import SwiftUI
import DocumentCore
import Workspace

/// The review queue screen: a course picker and the pending items.
struct ReviewQueueView: View {
    /// nil shows every course plus unfiled notebooks.
    let courseID: FolderID?

    @Environment(AppEnvironment.self) private var env
    @State private var model = ReviewQueueViewModel()
    @State private var detailEntry: ReviewQueueEntry? = nil

    var body: some View {
        List {
            Section {
                Picker("Course", selection: Binding(get: { model.selectedCourseID },
                                                    set: { value in
                                                        model.selectedCourseID = value
                                                        Task { await model.load() }
                                                    })) {
                    Text("All courses and unfiled notebooks").tag(FolderID?.none)
                    ForEach(model.courses, id: \.id) { course in
                        Text(course.name).tag(Optional(course.id))
                    }
                }
                .accessibilityLabel("Course")

                Toggle("Show items already reviewed", isOn: Binding(get: { model.showsReviewed },
                                                                    set: { model.showsReviewed = $0 }))
            } header: {
                Text("Scope")
            } footer: {
                Text("This is a manual list: pages and regions you marked yourself, oldest first. It is not spaced repetition and nothing is ever “due”.")
            }

            Section {
                if model.visibleEntries.isEmpty {
                    Text(model.isLoading ? "Loading…" : "Nothing to review. Add a page or a region from the Problem Inspector or the lasso menu.")
                        .detailTextStyle()
                }
                ForEach(model.visibleEntries) { entry in
                    Button {
                        detailEntry = entry
                    } label: {
                        ReviewEntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if entry.item.state == .pending {
                            Button("Reviewed") { Task { await model.markReviewed(entry) } }
                                .tint(Palette.success)
                        } else {
                            Button("Reopen") { Task { await model.reopen(entry) } }
                                .tint(Palette.accent)
                        }
                    }
                }
            } header: {
                Text("\(model.pendingCount) pending")
            }
        }
        .navigationTitle("Review Queue")
        .task(id: env.libraryRevision) {
            model.configure(env: env)
            if model.selectedCourseID == nil, let courseID { model.selectedCourseID = courseID }
            await model.load()
        }
        .sheet(item: $detailEntry) { entry in
            ReviewDetailView(entry: entry, model: model)
        }
    }
}

/// One row of the queue: prompt, problem title, notebook and page.
struct ReviewEntryRow: View {
    let entry: ReviewQueueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.item.prompt ?? entry.problemTitle ?? "Review this page")
                    .cardTitleStyle()
                if entry.item.state == .reviewed {
                    Text("Reviewed").badgeStyle(Palette.success)
                }
                if let status = entry.problemStatus {
                    Text(ProblemStatusText.title(status)).badgeStyle(ProblemStatusText.tint(status))
                }
            }
            Text(subtitle).detailTextStyle()
            Text("Added \(DateText.short(entry.item.createdAt))")
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to review this item")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let problemTitle = entry.problemTitle, entry.item.prompt != nil { parts.append(problemTitle) }
        parts.append(entry.documentTitle)
        parts.append("page \(entry.pageIndex + 1)")
        if let course = entry.courseName { parts.append(course) }
        if entry.item.region != nil { parts.append("region") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        "\(entry.item.prompt ?? entry.problemTitle ?? "Review this page"), \(subtitle)"
    }
}

enum ProblemStatusText {
    static func title(_ status: ProblemStatus) -> String {
        switch status {
        case .unfinished: return "Unfinished"
        case .checkAgain: return "Check again"
        case .understood: return "Understood"
        }
    }

    static func tint(_ status: ProblemStatus) -> Color {
        switch status {
        case .unfinished: return Palette.secondaryText
        case .checkAgain: return Palette.warning
        case .understood: return Palette.success
        }
    }
}
