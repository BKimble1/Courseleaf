import SwiftUI
import DocumentCore
import Workspace

/// Creates a notebook: title, paper (with a live preview), page size and cover.
/// The defaults come from Settings, so one tap on Create is enough.
struct NewNotebookSheet: View {
    let folderID: FolderID?
    var onCreated: (DocumentID) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model = LibraryViewModel()
    @State private var title = ""
    @State private var paperKind: PaperKind = .lined
    @State private var pageSize: PageSizeChoice = .letter
    @State private var cover = CoverStyle.default
    @State private var pageCount = 1
    @State private var isCreating = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled Notebook", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .accessibilityLabel("Notebook title")
                }

                Section("Paper") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(PaperKind.allCases, id: \.self) { kind in
                                Button {
                                    paperKind = kind
                                } label: {
                                    PaperKindOption(kind: kind, pageSize: pageSize.pageSize, isSelected: kind == paperKind)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Text(PaperKindNames.detail(paperKind)).detailTextStyle()
                }

                Section("Page Size") {
                    Picker("Page size", selection: $pageSize) {
                        ForEach(PageSizeChoice.allCases) { size in
                            Text("\(size.title) (\(size.detail))").tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityLabel("Page size")
                }

                Section("Cover") {
                    CoverView(style: cover, title: title.isEmpty ? "Untitled Notebook" : title)
                        .frame(width: 120, height: 156)
                        .frame(maxWidth: .infinity, alignment: .center)
                    NavigationLink {
                        CoverPickerList(cover: $cover)
                    } label: {
                        LabeledContent("Style", value: "\(Palette.name(for: cover.palette)) · \(Palette.name(for: cover.pattern))")
                    }
                    Toggle("Show the title on the cover", isOn: Binding(get: { cover.showsTitle },
                                                                       set: { cover.showsTitle = $0 }))
                }

                Section("Pages") {
                    Stepper(value: $pageCount, in: 1...50) {
                        Text("Start with \(pageCount) page\(pageCount == 1 ? "" : "s")")
                    }
                    .accessibilityLabel("Starting page count")
                    .accessibilityValue("\(pageCount)")
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(isCreating)
                }
            }
            .onAppear {
                model.configure(env: env)
                paperKind = env.settings.defaultPaperKind
                pageSize = env.settings.defaultPageSize
                titleFocused = true
            }
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Notebook" : title
        guard let id = await model.createNotebook(title: finalTitle,
                                                  folderID: folderID,
                                                  template: .preset(paperKind),
                                                  pageSize: pageSize.pageSize,
                                                  cover: cover,
                                                  pageCount: pageCount) else { return }
        dismiss()
        onCreated(id)
    }
}

/// Cover chooser as a pushable list (used inside the New Notebook form).
struct CoverPickerList: View {
    @Binding var cover: CoverStyle

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 90), spacing: 12)], spacing: 14) {
                ForEach(CoverArt.allStyles, id: \.self) { style in
                    Button {
                        cover = CoverStyle(palette: style.palette, pattern: style.pattern, showsTitle: cover.showsTitle)
                    } label: {
                        CoverSwatch(style: style, isSelected: style.palette == cover.palette && style.pattern == cover.pattern)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Palette.windowBackground)
        .navigationTitle("Cover")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Cover chooser as a sheet (used by the library context menu).
struct CoverPickerSheet: View {
    let title: String
    @State var cover: CoverStyle
    var onPick: (CoverStyle) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CoverView(style: cover, title: title)
                    .frame(width: 140, height: 182)
                CoverPickerList(cover: $cover)
            }
            .navigationTitle("Change Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Cover") { onPick(cover); dismiss() }
                }
            }
        }
    }
}
