import Foundation
import UniformTypeIdentifiers
import UIKit
import Workspace

/// File-type detection and drag-and-drop helpers for the app's importers
/// (`fileImporter`, `onDrop`, "Open in"). Produces `ImportRequest`s for
/// `LibraryServicing.importFiles`.
enum ImportSupport {
    /// The app's own archive type, declared in `App/project.yml` (`UTExportedTypeDeclarations`).
    static let archiveType: UTType = UTType(exportedAs: "dev.courseleaf.archive", conformingTo: .data)
    /// Types accepted by the Files picker and as drop payloads.
    static var importableTypes: [UTType] { [.pdf, .png, .jpeg, archiveType] }
    /// Identifiers checked on an `NSItemProvider`, most specific first.
    static var importableTypeIdentifiers: [String] { importableTypes.map(\.identifier) }

    // MARK: Kind detection

    /// Kind from the file extension alone (nil when the extension says nothing).
    static func kind(forExtension ext: String) -> ImportKind? {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg": return .image
        case "courseleaf": return .archive
        default: return nil
        }
    }

    /// Kind from magic bytes: `%PDF-` (within the first 1 KiB), the PNG
    /// signature, a JPEG SOI marker, or a ZIP local header (our archive container).
    static func kind(forMagicBytes data: Data) -> ImportKind? {
        let bytes = [UInt8](data.prefix(1024))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .image }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .image }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .archive }
        if data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        return nil
    }

    /// Extension first, magic bytes second (reads at most 1 KiB of the file). `.auto`
    /// when neither identifies the file; Workspace then reports it as unsupported.
    static func detectKind(of url: URL) -> ImportKind {
        if let byExtension = kind(forExtension: url.pathExtension) { return byExtension }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .auto }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024) else { return .auto }
        return kind(forMagicBytes: head) ?? .auto
    }

    // MARK: Requests

    /// Requests for URLs returned by `fileImporter`/`UIDocumentPickerViewController` (security scoped).
    static func requests(forPickedURLs urls: [URL]) -> [ImportRequest] {
        urls.map { ImportRequest(sourceURL: $0, kind: detectKind(of: $0), isSecurityScoped: true) }
    }

    /// Request for a URL delivered by "Open in" (`onOpenURL`); such URLs are security scoped too.
    static func request(forOpenedURL url: URL) -> ImportRequest {
        ImportRequest(sourceURL: url, kind: detectKind(of: url), isSecurityScoped: true)
    }

    // MARK: Drag and drop

    /// Whether at least one provider carries an importable payload.
    static func canHandle(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in importableTypeIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) } }
    }

    /// The first importable type a provider offers.
    static func importableType(of provider: NSItemProvider) -> UTType? {
        importableTypes.first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    /// Copies every importable drop payload into `stagingDirectory` (the file
    /// representation is only valid inside the load callback, so it must be
    /// copied) and returns plain, non-scoped requests. Providers that fail to
    /// load are skipped and reported in `failures`.
    static func loadRequests(from providers: [NSItemProvider], stagingDirectory: URL) async -> (requests: [ImportRequest], failures: [String]) {
        var requests: [ImportRequest] = []
        var failures: [String] = []
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        for provider in providers {
            guard let type = importableType(of: provider) else { continue }
            do {
                let url = try await stagedFile(from: provider, type: type, into: stagingDirectory)
                requests.append(ImportRequest(sourceURL: url, kind: detectKind(of: url), isSecurityScoped: false))
            } catch {
                failures.append(provider.suggestedName ?? type.localizedDescription ?? type.identifier)
            }
        }
        return (requests, failures)
    }

    private static func stagedFile(from provider: NSItemProvider, type: UTType, into directory: URL) async throws -> URL {
        let ext = type.preferredFilenameExtension ?? (type == archiveType ? "courseleaf" : "bin")
        let baseName = (provider.suggestedName?.isEmpty == false ? provider.suggestedName! : "dropped")
        let stem = (baseName as NSString).deletingPathExtension
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(stem).\(ext)")
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    guard let url else { continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile)); return }
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            // Some sources (Photos, pasteboards) only offer data representations.
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    guard let data else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)); return }
                    do {
                        try data.write(to: destination, options: .atomic)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
