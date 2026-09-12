import SwiftUI
import DocumentCore
import Editing
import Workspace

/// One review item: what to recall, the answer cover (when the student added
/// one), and the actions — reveal/hide, mark reviewed, reopen, open the page.
struct ReviewDetailView: View {
    let entry: ReviewQueueEntry
    let model: ReviewQueueViewModel

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var isRevealed: Bool? = nil
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("Prompt") {
                    Text(entry.item.prompt ?? "No prompt was added. Open the page and try to recall the result before checking it.")
                        .font(Typography.body)
                }

                Section("Where") {
                    LabeledContent("Notebook", value: entry.documentTitle)
                    LabeledContent("Page", value: "\(entry.pageIndex + 1)")
                    if let problemTitle = entry.problemTitle {
                        LabeledContent("Problem", value: problemTitle)
                    }
                    if let status = entry.problemStatus {
                        LabeledContent("Status", value: ProblemStatusText.title(status))
                    }
                    if let course = entry.courseName {
                        LabeledContent("Course", value: course)
                    }
                    LabeledContent("Added", value: DateText.modified(entry.item.createdAt))
                    if let reviewed = entry.item.lastReviewedAt {
                        LabeledContent("Last reviewed", value: DateText.modified(reviewed))
                    }
                    LabeledContent("Covers", value: entry.item.region == nil ? "The whole page" : "A region of the page")
                }

                Section("Answer") {
                    if entry.item.answerTapeID != nil {
                        Button {
                            Task { await toggleReveal() }
                        } label: {
                            Label(isRevealed == true ? "Hide the Answer Again" : "Reveal the Answer",
                                  systemImage: isRevealed == true ? "eye.slash" : "eye")
                        }
                        .disabled(isWorking)
                        .accessibilityHint(isRevealed == true
                                           ? "Covers the result with its tape again"
                                           : "Lifts the tape covering the result on the page")
                        Text(isRevealed == true
                             ? "The tape is lifted on the page, so the result is visible in the notebook too."
                             : "The result is covered by tape on the page. Recall it first, then reveal.")
                            .detailTextStyle()
                    } else {
                        Text("This item has no answer tape, so there is nothing to reveal. Open the page to check your work, or add a tape over the result in the Problem Inspector.")
                            .detailTextStyle()
                    }
                }

                Section {
                    Button {
                        openPage()
                    } label: {
                        Label("Open the Page", systemImage: "arrow.forward.square")
                    }
                    if entry.item.state == .pending {
                        Button {
                            Task { isWorking = true; await model.markReviewed(entry); isWorking = false; dismiss() }
                        } label: {
                            Label("Mark Reviewed", systemImage: "checkmark.circle")
                        }
                        .disabled(isWorking)
                    } else {
                        Button {
                            Task { isWorking = true; await model.reopen(entry); isWorking = false; dismiss() }
                        } label: {
                            Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isWorking)
                    }
                } footer: {
                    Text("Marking an item reviewed just takes it off this list. Nothing is scheduled and nothing is ever due.")
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                model.configure(env: env)
                isRevealed = await model.isTapeRevealed(entry)
            }
        }
    }

    private func toggleReveal() async {
        isWorking = true
        defer { isWorking = false }
        let target = !(isRevealed ?? false)
        if await model.setTapeRevealed(target, for: entry) {
            isRevealed = target
        }
    }

    private func openPage() {
        dismiss()
        env.router.openNotebook(entry.documentID, pageIndex: entry.pageIndex, highlight: entry.item.region)
    }
}
