import Foundation
import DocumentCore

/// Errors raised by the Persistence module. Every failure that can leave the
/// caller with a decision (retry, export a copy, show "needs a newer app") has
/// its own case so the UI never has to parse a message.
public enum PersistenceError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The manifest declares a `formatVersion` this build cannot read. The
    /// document is never opened as empty; the library shows it read-only.
    case unsupportedSchema(version: Int)
    /// Neither `manifest.json` nor `manifest.lkg.json` could be parsed.
    case corruptManifest(reason: String)
    /// An asset referenced by the manifest has no file on disk (or the digest does not match).
    case missingAsset(id: AssetID)
    /// A live page has no readable page file and no earlier revision file to recover from.
    case missingPageFile(pageID: PageID)
    /// ENOSPC (or the platform equivalent) while writing.
    case diskFull
    /// Any other I/O failure; `underlying` is the OS error description.
    case writeFailed(path: String, underlying: String)
    /// The package (or library file) does not exist where expected.
    case packageNotFound(path: String)
    /// Creating something that already exists (package, folder id, trash entry...).
    case alreadyExists(path: String)
    /// A commit was interrupted (cancellation or a simulated crash); nothing was published.
    case interrupted
    /// The library root is missing, unreadable or its manifest is corrupt with no fallback.
    case invalidLibraryRoot(reason: String)
    /// The snapshot handed to `commit` failed `DocumentSnapshot.validate()`.
    case invalidSnapshot(issues: [String])
    /// A `PendingAsset` whose bytes do not hash to the recorded digest.
    case assetDigestMismatch(id: AssetID, expected: String, actual: String)
    /// The store has not been opened/created yet.
    case notOpen
    /// A library object (document, folder, trash entry) is unknown.
    case notFound(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let v): return "The document uses format version \(v), which needs a newer app."
        case .corruptManifest(let r): return "The document manifest is unreadable: \(r)"
        case .missingAsset(let id): return "Asset \(id) is missing from the package."
        case .missingPageFile(let id): return "Page \(id) has no readable page file."
        case .diskFull: return "There is not enough free space to save."
        case .writeFailed(let p, let u): return "Writing \(p) failed: \(u)"
        case .packageNotFound(let p): return "No document package at \(p)."
        case .alreadyExists(let p): return "\(p) already exists."
        case .interrupted: return "The save was interrupted before it completed."
        case .invalidLibraryRoot(let r): return "The library cannot be opened: \(r)"
        case .invalidSnapshot(let issues): return "The document is not consistent: \(issues.joined(separator: "; "))"
        case .assetDigestMismatch(let id, let e, let a): return "Asset \(id) bytes hash to \(a), expected \(e)."
        case .notOpen: return "The store has not been opened."
        case .notFound(let what): return "\(what) was not found."
        }
    }

    /// Whether retrying the same operation later can succeed (disk full, transient I/O).
    public var isRetryable: Bool {
        switch self {
        case .diskFull, .writeFailed, .interrupted: return true
        default: return false
        }
    }

    /// Maps an errno value to the matching case.
    public static func fromErrno(_ code: Int32, path: String) -> PersistenceError {
        if code == ENOSPC || code == EDQUOT { return .diskFull }
        if code == ENOENT { return .packageNotFound(path: path) }
        if code == EEXIST { return .alreadyExists(path: path) }
        return .writeFailed(path: path, underlying: String(cString: strerror(code)) + " (errno \(code))")
    }
}

/// Thrown by `FaultInjectingFileSystem` for every mutating operation after the
/// simulated crash point. Distinct from `PersistenceError` so tests can tell a
/// crash from an injected I/O error.
public struct SimulatedCrash: Error, Equatable, Sendable {
    public var step: Int
    public init(step: Int) { self.step = step }
}
