import Foundation
import DocumentCore

/// Every failure the archive module reports. Cases are specific so the
/// workspace layer can explain to the student *why* an archive was refused
/// without exposing internals. All associated values are unlabeled.
public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    /// The ZIP container is structurally invalid (bad signature, truncated,
    /// out-of-bounds offsets, overlapping entries, compression, encryption…).
    case corruptZip(String)
    /// ZIP64 structures or sizes/offsets/counts that would need ZIP64.
    case zip64Unsupported
    /// The same entry name was added or found twice.
    case duplicateEntry(String)
    /// The path could escape the extraction root: `..`, leading `/`, drive
    /// letter, backslash, or NUL.
    case pathTraversal(String)
    /// The path is empty, not normalized (`.`/empty components, trailing `/`),
    /// or contains control characters.
    case invalidPath(String)
    /// A ZIP entry that `archive.json` does not list.
    case unlistedEntry(String)
    /// A listed entry that does not belong to the documented layout.
    case unexpectedEntry(String)
    /// A listed or referenced entry is absent from the ZIP.
    case missingEntry(String)
    /// Declared size (archive.json, manifest, asset record) differs from the ZIP entry size.
    case sizeMismatch(String)
    case totalSizeExceeded
    case expansionRatioExceeded
    case tooManyEntries
    case entryTooLarge(String)
    /// CRC-32 or SHA-256 of an entry does not match what was recorded.
    case checksumMismatch(String)
    /// An asset file name is not the SHA-256 of its contents.
    case assetNameMismatch(String)
    case unsupportedSchema(Int)
    /// `archive.json` is undecodable or self-inconsistent.
    case invalidManifest(String)
    /// A document inside the archive is undecodable or fails `DocumentSnapshot.validate()`.
    case invalidDocument([String])
    case documentNotFound(DocumentID)
    /// Underlying file I/O failure.
    case io(String)

    public var description: String {
        switch self {
        case .corruptZip(let r): return "corrupt archive: \(r)"
        case .zip64Unsupported: return "ZIP64 archives are not supported"
        case .duplicateEntry(let p): return "duplicate entry '\(p)'"
        case .pathTraversal(let p): return "entry path '\(p)' could escape the archive root"
        case .invalidPath(let p): return "entry path '\(p)' is not a normalized relative path"
        case .unlistedEntry(let p): return "entry '\(p)' is not listed in archive.json"
        case .unexpectedEntry(let p): return "entry '\(p)' does not belong to the archive layout"
        case .missingEntry(let p): return "entry '\(p)' is missing"
        case .sizeMismatch(let p): return "declared size of '\(p)' does not match"
        case .totalSizeExceeded: return "archive exceeds the total size limit"
        case .expansionRatioExceeded: return "archive exceeds the expansion ratio limit"
        case .tooManyEntries: return "archive has too many entries"
        case .entryTooLarge(let p): return "entry '\(p)' exceeds the single entry size limit"
        case .checksumMismatch(let p): return "checksum of '\(p)' does not match"
        case .assetNameMismatch(let p): return "asset '\(p)' is not named after its content digest"
        case .unsupportedSchema(let v): return "unsupported format version \(v)"
        case .invalidManifest(let r): return "invalid archive.json: \(r)"
        case .invalidDocument(let issues): return "invalid document: " + issues.joined(separator: "; ")
        case .documentNotFound(let id): return "document \(id) is not in the archive"
        case .io(let r): return "I/O error: \(r)"
        }
    }
}
