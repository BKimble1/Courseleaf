import SwiftUI
import DocumentCore

/// Three screens, shown once: what this app is, Problem Pages and the review
/// queue, and where the files live. No account, no sign-in, nothing to skip
/// past except this.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page: Identifiable {
        var id: Int
        var symbol: String
        var title: String
        var body: [String]
    }

    private var pages: [Page] {
        [
            Page(id: 0, symbol: "pencil.and.outline", title: "A notebook for coursework",
                 body: [
                    "Write with Apple Pencil on paper you choose, or on top of lecture PDFs and photos of a whiteboard.",
                    "Notebooks live in folders and courses. Everything you write stays editable: strokes are strokes, not pictures.",
                 ]),
            Page(id: 1, symbol: "list.clipboard", title: "Problem Pages and review",
                 body: [
                    "Turn any page into a Problem Page: a title, the source, what is given, what to find, and the region holding your result.",
                    "Cover that result with tape, add the page to your review queue, and come back later to recall it before you check.",
                    "The queue is a manual list you build yourself. There is no scheduler, and nothing is ever due.",
                 ]),
            Page(id: 2, symbol: "iphone.and.arrow.forward", title: "Your files stay on this iPad",
                 body: [
                    "There is no account and no sync service. Notebooks are ordinary packages in this app's folder on this iPad.",
                    "Handwriting recognition and PDF text extraction run on the device, only to make search work.",
                    "Back up whenever you like with Settings › Storage › Back up library, and keep the archive somewhere else.",
                 ]),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages) { item in
                    VStack(spacing: 18) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(Typography.screenTitle)
                            .multilineTextAlignment(.center)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(item.body.enumerated()), id: \.offset) { _, line in
                                Text(line).font(Typography.body)
                            }
                        }
                        .frame(maxWidth: 520)
                    }
                    .padding(40)
                    .tag(item.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(item.title)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack {
                Button("Skip") { finish() }
                    .accessibilityHint("Closes the welcome screens")
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Writing") { finish() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .background(Palette.windowBackground)
    }

    private func finish() {
        env.settings.hasSeenOnboarding = true
        dismiss()
    }
}
