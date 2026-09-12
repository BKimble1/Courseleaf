import Foundation
import DocumentCore

/// Errors raised by the catalog. SQLite failures carry the result code and
/// the engine's message; the remaining cases describe conditions the caller
/// can act on (the catalog is disposable, so Workspace may delete and rebuild
/// it on `schemaMismatch`).
public enum CatalogError: Error, Equatable, Sendable {
    /// A SQLite call failed. `code` is the primary or extended result code.
    case sqlite(code: Int32, message: String)
    /// The linked SQLite library has no FTS5 module; search cannot work.
    case fts5Unavailable
    /// The on-disk catalog was written by a different schema version.
    case schemaMismatch(found: Int, expected: Int)
    /// The database handle was closed.
    case closed
    /// An operation referred to a page the catalog does not know.
    case pageNotFound(PageID)
    /// A value could not be encoded or decoded for storage.
    case encoding(String)
}
