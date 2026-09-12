import SwiftUI
import UIKit
import DocumentCore
import Editing
import Workspace

/// Export and print the open notebook. The editor calls
/// `ExportSheet(session:currentPageID:)`.
///
/// PDF keeps the source document's vectors and text and rasterizes ink; PNG
/// writes one image per page; the Courseleaf archive keeps full editing
/// fidelity. Tape (answer covers) is drawn according to the chosen policy.
struct ExportSheet: View {
    let session: any DocumentSessioning
    let currentPageID: PageID?
    /// Finishes everything the editor is still holding in its views and makes
    /// the document durable, then reports what stopped it. `session.flush()`
    /// alone is not enough: a stroke that has not left its `PKCanvasView` and a
    /// word still in a `UITextView` are not in the snapshot an exporter reads.
    ///
    /// Deliberately not optional and without a default. An export that skips
    /// this reads a document that is not what is on screen, and a parameter
    /// that can be left out is a parameter that will be.
    let prepare: () async -> Error?

    // Written out because the synthesised memberwise initialiser takes the
    // access level of its least visible property, and every `@State` here is
    // private — so it is not callable from the view that presents this sheet.
    init(session: any DocumentSessioning, currentPageID: PageID?,
         prepare: @escaping () async -> Error?) {
        self.session = session
        self.currentPageID = currentPageID
        self.prepare = prepare
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case pdf, png, archive
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pdf: return "PDF"
            case .png: return "PNG images"
            case .archive: return "Courseleaf archive"
            }
        }
        var detail: String {
            switch self {
            case .pdf: return "A presentation copy. Text from imported PDFs stays searchable; handwriting is rasterized. Links, outlines and form fields are not kept."
            case .png: return "One image per page at 144 dpi. Everything is pixels."
            case .archive: return "Everything, exactly as it is here, so it can be imported again with full editing."
            }
        }
    }

    enum PageRange: String, CaseIterable, Identifiable {
        case all, current, selection
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All pages"
            case .current: return "Current page"
            case .selection: return "A range of pages"
            }
        }
    }

    @State private var format: Format = .pdf
    @State private var range: PageRange = .all
    @State private var tape: TapeExportPolicy = .asShown
    @State private var firstPage = 1
    @State private var lastPage = 1
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var producedURLs: [URL] = []
    @State private var failure: String? = nil

    private var pageCount: Int { session.editor.snapshot.document.pageIDs.count }

    private var documentTitle: String { session.editor.snapshot.document.title }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.inline)
                    .accessibilityLabel("Export format")
                    Text(format.detail).detailTextStyle()
                }

                Section("Pages") {
                    if format == .archive {
                        Text("An archive always holds the whole notebook.").detailTextStyle()
                    } else {
                        Picker("Pages", selection: $range) {
                            ForEach(PageRange.allCases) { option in Text(option.title).tag(option) }
                        }
                        .accessibilityLabel("Pages to export")
                        if range == .selection {
                            Stepper(value: $firstPage, in: 1...max(pageCount, 1)) { Text("From page \(firstPage)") }
                                .accessibilityLabel("First page")
                            Stepper(value: $lastPage, in: 1...max(pageCount, 1)) { Text("To page \(lastPage)") }
                                .accessibilityLabel("Last page")
                        }
                    }
                }

                Section {
                    Picker("Tape", selection: $tape) {
                        Text("As shown on the page").tag(TapeExportPolicy.asShown)
                        Text("Cover every answer").tag(TapeExportPolicy.coverAll)
                        Text("Reveal every answer").tag(TapeExportPolicy.revealAll)
                    }
                    .accessibilityLabel("Answer tape")
                } header: {
                    Text("Answer Tape")
                } footer: {
                    Text("Tape hides an answer for recall practice. Choose whether the exported copy keeps it covered.")
                }

                if isWorking {
                    Section {
                        ProgressView(value: progress)
                        Text("Exporting…").detailTextStyle()
                    }
                }

                if !producedURLs.isEmpty {
                    Section("Ready") {
                        ForEach(producedURLs, id: \.self) { url in
                            Text(url.lastPathComponent).detailTextStyle()
                        }
                        ShareLink(items: producedURLs) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityHint("Send the exported file to another app, Files or a printer")
                        if format == .pdf, let url = producedURLs.first {
                            Button {
                                Task { await printPDF(url) }
                            } label: {
                                Label("Print…", systemImage: "printer")
                            }
                        }
                    }
                }

                if let failure {
                    Section("Export failed") {
                        Text(failure).foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { Task { await export() } }
                        .disabled(isWorking)
                }
            }
            .onAppear {
                if let currentPageID, let index = session.editor.snapshot.pageIndex(currentPageID) {
                    firstPage = index + 1
                    lastPage = index + 1
                } else {
                    lastPage = max(pageCount, 1)
                }
            }
        }
    }

    // MARK: Export

    private func selectedPageIDs() -> [PageID]? {
        let ids = session.editor.snapshot.document.pageIDs
        switch range {
        case .all:
            return nil
        case .current:
            if let currentPageID { return [currentPageID] }
            return ids.first.map { [$0] }
        case .selection:
            let lower = max(min(firstPage, lastPage), 1) - 1
            let upper = min(max(firstPage, lastPage), ids.count) - 1
            guard lower <= upper, ids.indices.contains(lower), ids.indices.contains(upper) else { return nil }
            return Array(ids[lower...upper])
        }
    }

    /// True when "a range of pages" names a range this notebook does not have.
    private var isPageRangeInvalid: Bool {
        guard range == .selection else { return false }
        return selectedPageIDs() == nil
    }

    private func export() async {
        guard !isPageRangeInvalid else {
            failure = "Pages \(firstPage) to \(lastPage) are not in this notebook. Choose a range inside 1 to \(session.editor.document.pageIDs.count)."
            return
        }
        isWorking = true
        progress = 0
        failure = nil
        producedURLs = []
        defer { isWorking = false }
        do {
            if let error = await prepare() { throw error }
            let directory = try makeExportDirectory()
            let stem = safeStem(documentTitle)
            switch format {
            case .pdf:
                let url = directory.appendingPathComponent("\(stem).pdf")
                let options = ExportOptions(format: .pdf, pageIDs: selectedPageIDs(), tape: tape)
                try await PDFExporter(session: session).export(options: options, to: url) { value in
                    Task { @MainActor in progress = value }
                }
                producedURLs = [url]
            case .png:
                let options = ExportOptions(format: .png, pageIDs: selectedPageIDs(), tape: tape)
                let urls = try await ImageExporter(session: session).export(options: options, into: directory, stem: stem) { value in
                    Task { @MainActor in progress = value }
                }
                producedURLs = urls
            case .archive:
                let url = directory.appendingPathComponent("\(stem).courseleaf")
                try await env.library.exportArchive(documentIDs: [session.documentID], to: url) { value in
                    Task { @MainActor in
                        progress = value.totalUnits > 0 ? Double(value.completedUnits) / Double(value.totalUnits) : 0
                    }
                }
                producedURLs = [url]
            }
            progress = 1
        } catch {
            failure = AppErrorText.message(for: error)
        }
    }

    private func printPDF(_ url: URL) async {
        guard let window = Self.keyWindow() else {
            failure = "The print panel could not be shown."
            return
        }
        let anchor = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
        do {
            _ = try await PrintCoordinator.print(pdfAt: url, from: .view(window, rect: anchor), jobName: documentTitle)
        } catch {
            failure = AppErrorText.message(for: error)
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func makeExportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseleafExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func safeStem(_ title: String) -> String {
        let allowed = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.isEmpty ? "Notebook" : String(allowed.prefix(60))
    }
}
