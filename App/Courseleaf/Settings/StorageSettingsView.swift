import SwiftUI
import UniformTypeIdentifiers
import DocumentCore
import Workspace

/// Storage usage, backup and restore, and the rebuildable search index.
struct StorageSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var report: StorageReport? = nil
    @State private var isWorking = false
    @State private var statusMessage: String? = nil
    @State private var backupURL: URL? = nil
    @State private var backupReport: BackupReport? = nil
    @State private var restoreMode: RestoreMode = .addCopies
    @State private var isShowingRestorePicker = false
    @State private var restoreReport: RestoreReport? = nil
    @State private var progressMessage: String? = nil
    @State private var isConfirmingEmptyTrash = false

    var body: some View {
        List {
            Section("Usage") {
                if let report {
                    LabeledContent("Notebooks", value: DateText.bytes(report.documentBytes))
                    LabeledContent("Trash", value: DateText.bytes(report.trashBytes))
                    LabeledContent("Search index", value: DateText.bytes(report.catalogBytes))
                    LabeledContent("Previews", value: DateText.bytes(report.previewBytes))
                    if let available = report.availableBytes {
                        LabeledContent("Free on this iPad", value: DateText.bytes(available))
                    }
                } else {
                    Text("Reading…").detailTextStyle()
                }
            }

            Section {
                Button {
                    Task { await backUp() }
                } label: {
                    Label("Back Up Library…", systemImage: "arrow.up.doc")
                }
                .disabled(isWorking)
                if let backupURL, let backupReport {
                    Text("\(backupReport.documentCount) notebook\(backupReport.documentCount == 1 ? "" : "s"), \(DateText.bytes(backupReport.byteCount))\(backupReport.validated ? ", validated" : "")")
                        .detailTextStyle()
                    ShareLink(item: backupURL) {
                        Label("Save or Send the Backup…", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityHint("Choose where to keep the archive: Files, an external drive or a cloud folder")
                }
                if let last = env.settings.lastBackupAt {
                    LabeledContent("Last backup", value: DateText.modified(last))
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup is one validated Courseleaf archive holding every notebook. Keep it somewhere other than this iPad.")
            }

            Section {
                Picker("Restore as", selection: $restoreMode) {
                    Text("Copies (nothing existing is touched)").tag(RestoreMode.addCopies)
                    Text("Only notebooks missing from the library").tag(RestoreMode.restoreMissing)
                }
                .accessibilityLabel("Restore mode")
                Button {
                    isShowingRestorePicker = true
                } label: {
                    Label("Restore from Backup…", systemImage: "arrow.down.doc")
                }
                .disabled(isWorking)
                if let restoreReport {
                    Text("Restored \(restoreReport.restoredDocumentIDs.count), skipped \(restoreReport.skippedDocumentIDs.count), folders \(restoreReport.restoredFolderCount).")
                        .detailTextStyle()
                    ForEach(restoreReport.warnings, id: \.self) { warning in
                        Text(warning).font(Typography.caption).foregroundStyle(Palette.warning)
                    }
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("The archive is validated completely before anything is written. A failed restore never changes what you already have.")
            }

            Section {
                Button {
                    Task { await rebuildIndex() }
                } label: {
                    Label("Rebuild Search Index", systemImage: "arrow.clockwise")
                }
                .disabled(isWorking)
                if let reason = env.catalogUnavailableReason {
                    Text("The index is currently unavailable: \(reason)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.warning)
                }
            } header: {
                Text("Search Index")
            } footer: {
                Text("The index is derived from your notebooks. Rebuilding it never changes their contents.")
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingEmptyTrash = true
                } label: {
                    Label("Empty Trash", systemImage: "trash")
                }
                .disabled(isWorking)
            } header: {
                Text("Trash")
            } footer: {
                Text("Deleted notebooks stay in the trash until you empty it.")
            }

            if let progressMessage {
                Section { Label(progressMessage, systemImage: "hourglass").detailTextStyle() }
            }
            if let statusMessage {
                Section { Text(statusMessage).detailTextStyle() }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .confirmationDialog("Empty the trash?", isPresented: $isConfirmingEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { Task { await emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the trash is deleted permanently. This cannot be undone.")
        }
        .fileImporter(isPresented: $isShowingRestorePicker,
                      allowedContentTypes: [ImportSupport.archiveType],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await restore(from: url) } }
            case .failure(let error):
                env.present(error, title: "That backup could not be opened")
            }
        }
    }

    // MARK: Actions

    private func refresh() async {
        report = await env.perform("The storage report could not be read") { try await env.library.storageReport() }
        await env.refreshCatalogState()
    }

    private func backUp() async {
        isWorking = true
        progressMessage = "Preparing the backup…"
        defer { isWorking = false; progressMessage = nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseleafBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Courseleaf-\(stamp).courseleaf")
        let result = await env.perform("The backup could not be written") {
            try await env.library.backupLibrary(to: url) { progress in
                Task { @MainActor in progressMessage = progress.message }
            }
        }
        guard let result else { return }
        backupReport = result
        backupURL = result.archiveURL
        env.settings.lastBackupAt = Date()
        statusMessage = "Backup ready. Use Save or Send to keep it off this iPad."
        await refresh()
    }

    private func restore(from url: URL) async {
        isWorking = true
        progressMessage = "Validating the archive…"
        defer { isWorking = false; progressMessage = nil }
        let staged: (requests: [ImportRequest], staging: URL)
        do {
            staged = try SecurityScopedFileAccess.prepareForImport([ImportRequest(sourceURL: url, kind: .archive, isSecurityScoped: true)])
        } catch {
            env.present(error, title: "That backup could not be read")
            return
        }
        defer { SecurityScopedFileAccess.discardStaging(staged.staging) }
        guard let source = staged.requests.first?.sourceURL else { return }
        let mode = restoreMode
        let result = await env.perform("The restore did not finish") {
            try await env.library.restoreLibrary(from: source, mode: mode) { progress in
                Task { @MainActor in progressMessage = progress.message }
            }
        }
        guard let result else { return }
        restoreReport = result
        env.noteLibraryChanged()
        statusMessage = "Restore finished. Nothing that was already in your library was overwritten."
        await refresh()
    }

    private func rebuildIndex() async {
        isWorking = true
        progressMessage = "Rebuilding the search index…"
        defer { isWorking = false; progressMessage = nil }
        await env.perform("The search index could not be rebuilt") {
            try await env.library.rebuildCatalog { progress in
                Task { @MainActor in progressMessage = progress.message }
            }
        }
        await env.refreshCatalogState()
        statusMessage = "The search index was rebuilt from your notebooks."
        await refresh()
    }

    private func emptyTrash() async {
        isWorking = true
        defer { isWorking = false }
        await env.perform("The trash could not be emptied") { try await env.library.emptyTrash() }
        env.noteLibraryChanged()
        await refresh()
    }
}
