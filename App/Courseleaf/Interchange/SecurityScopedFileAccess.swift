import Foundation
import Workspace

enum SecurityScopedFileAccessError: Error, LocalizedError, Equatable {
    /// `startAccessingSecurityScopedResource()` returned false for a URL that needs it.
    case accessDenied(URL)
    case copyFailed(URL, String)
    case notAFile(URL)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let url): return "\(url.lastPathComponent) could not be opened; the app was not granted access to it."
        case .copyFailed(let url, let reason): return "\(url.lastPathComponent) could not be copied: \(reason)"
        case .notAFile(let url): return "\(url.lastPathComponent) is not a file."
        }
    }
}

/// Security-scoped resource handling for URLs that come from the document
/// picker, drag and drop, or "Open in". The Workspace import path copies from
/// `ImportRequest.sourceURL` with plain file APIs, so the app stages the file
/// **while the scoped access is held** and hands Workspace a request that
/// points at the staged copy (`isSecurityScoped == false`). Access ends before
/// this type returns, so the caller never keeps a scoped URL alive.
enum SecurityScopedFileAccess {
    /// Runs `body` with security-scoped access to `url` started (when the URL
    /// requires it) and stopped afterwards, even when `body` throws. A URL that
    /// does not need scoped access (`isSecurityScoped == false`, or a file inside
    /// the app container) runs `body` directly.
    static func withAccess<T>(_ url: URL, isSecurityScoped: Bool = true, _ body: (URL) throws -> T) throws -> T {
        guard isSecurityScoped else { return try body(url) }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        if !started && !FileManager.default.isReadableFile(atPath: url.path) {
            throw SecurityScopedFileAccessError.accessDenied(url)
        }
        return try body(url)
    }

    /// Copies `url` into `stagingDirectory` under a unique name while access is
    /// held. Reads go through `NSFileCoordinator` so files that live in iCloud
    /// Drive (possibly not yet downloaded) are materialized first.
    static func stageCopy(of url: URL, into stagingDirectory: URL, isSecurityScoped: Bool = true) throws -> URL {
        try withAccess(url, isSecurityScoped: isSecurityScoped) { scoped in
            let fm = FileManager.default
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let name = scoped.lastPathComponent.isEmpty ? "import" : scoped.lastPathComponent
            let destination = stagingDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: scoped, options: [.withoutChanges], error: &coordinatorError) { readable in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: readable.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    copyError = SecurityScopedFileAccessError.notAFile(url); return
                }
                do { try fm.copyItem(at: readable, to: destination) }
                catch { copyError = SecurityScopedFileAccessError.copyFailed(url, error.localizedDescription) }
            }
            if let coordinatorError { throw SecurityScopedFileAccessError.copyFailed(url, coordinatorError.localizedDescription) }
            if let copyError { throw copyError }
            return destination
        }
    }

    /// Stages every request whose URL is security scoped and returns requests
    /// Workspace can copy from with plain file APIs. Requests that are already
    /// plain files (`isSecurityScoped == false`) pass through unchanged.
    static func stagedRequests(_ requests: [ImportRequest], stagingDirectory: URL) throws -> [ImportRequest] {
        try requests.map { request in
            guard request.isSecurityScoped else { return request }
            let staged = try stageCopy(of: request.sourceURL, into: stagingDirectory, isSecurityScoped: true)
            return ImportRequest(sourceURL: staged, kind: request.kind, isSecurityScoped: false)
        }
    }

    /// A fresh app-owned staging directory (inside the temporary directory, so
    /// the system may reclaim it). Remove it with `discardStaging` after the
    /// import finished or failed.
    static func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseleafImportStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func discardStaging(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A closure the app hands to its import flow: stages the picked URLs into a
    /// fresh directory and returns plain requests for `LibraryServicing.importFiles`.
    /// The returned staging directory must be discarded by the caller afterwards.
    static func prepareForImport(_ requests: [ImportRequest]) throws -> (requests: [ImportRequest], staging: URL) {
        let staging = try makeStagingDirectory()
        do {
            return (try stagedRequests(requests, stagingDirectory: staging), staging)
        } catch {
            discardStaging(staging)
            throw error
        }
    }
}
