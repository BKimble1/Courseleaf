import Foundation
import DocumentCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The narrow file-system surface Persistence needs. Exists so commits can be
/// exercised with injected faults and simulated crashes (A07/A08); the app
/// uses `LocalFileSystem`.
public protocol FileSystem: Sendable {
    /// Creates the directory and every missing parent. Succeeds if it already exists.
    func createDirectory(at url: URL) throws
    func read(at url: URL) throws -> Data
    /// Creates or truncates the file and writes `data` (not atomic on its own).
    func write(_ data: Data, to url: URL) throws
    /// Atomically replaces `destination` with `source` (POSIX rename). `source` no longer exists afterwards.
    func replaceItem(at destination: URL, withItemAt source: URL) throws
    /// Removes a file or a directory tree. Missing items are not an error.
    func removeItem(at url: URL) throws
    /// Moves a file or directory; fails if `destination` exists.
    func moveItem(at source: URL, to destination: URL) throws
    /// Direct children (files and directories), sorted by name. Missing directory -> empty.
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileExists(at url: URL) -> Bool
    func directoryExists(at url: URL) -> Bool
    func fileSize(at url: URL) throws -> Int
    /// Hard-links `source` to `destination` when the volume supports it, otherwise copies. `destination` must not exist.
    func copyOrLink(from source: URL, to destination: URL) throws
    /// fsync of a regular file.
    func syncFile(at url: URL) throws
    /// fsync of a directory so renames inside it are durable.
    func syncDirectory(at url: URL) throws
    /// Bytes available to the current user on the volume holding `url`; nil when unknown.
    func freeSpace(at url: URL) -> Int?
}

// MARK: - Local implementation

/// FileManager for tree operations plus POSIX open/write/fsync/rename for the
/// durability-critical steps. Works on Linux and Apple platforms.
public struct LocalFileSystem: FileSystem {
    public init() {}

    private var fm: FileManager { FileManager.default }

    public func createDirectory(at url: URL) throws {
        do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw Self.map(error, path: url.path) }
    }

    public func read(at url: URL) throws -> Data {
        do { return try Data(contentsOf: url) }
        catch { throw Self.map(error, path: url.path) }
    }

    public func write(_ data: Data, to url: URL) throws {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw PersistenceError.fromErrno(errno, path: path) }
        defer { close(fd) }
        var offset = 0
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                let n = Foundation.write(fd, base.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PersistenceError.fromErrno(errno, path: path)
                }
                offset += n
            }
        }
    }

    public func replaceItem(at destination: URL, withItemAt source: URL) throws {
        if rename(source.path, destination.path) != 0 {
            throw PersistenceError.fromErrno(errno, path: destination.path)
        }
    }

    public func removeItem(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        do { try fm.removeItem(at: url) } catch { throw Self.map(error, path: url.path) }
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        if fm.fileExists(atPath: destination.path) { throw PersistenceError.alreadyExists(path: destination.path) }
        do { try fm.moveItem(at: source, to: destination) } catch { throw Self.map(error, path: destination.path) }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        guard directoryExists(at: url) else { return [] }
        do {
            let names = try fm.contentsOfDirectory(atPath: url.path)
            return names.sorted().map { url.appendingPathComponent($0) }
        } catch { throw Self.map(error, path: url.path) }
    }

    public func fileExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    public func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fileSize(at url: URL) throws -> Int {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw PersistenceError.fromErrno(errno, path: url.path) }
        return Int(st.st_size)
    }

    public func copyOrLink(from source: URL, to destination: URL) throws {
        if fm.fileExists(atPath: destination.path) { throw PersistenceError.alreadyExists(path: destination.path) }
        if link(source.path, destination.path) == 0 { return }
        let code = errno
        if code == ENOSPC || code == EDQUOT { throw PersistenceError.diskFull }
        if code == ENOENT { throw PersistenceError.packageNotFound(path: source.path) }
        // Cross-device, unsupported or forbidden: fall back to a copy.
        do { try fm.copyItem(at: source, to: destination) } catch { throw Self.map(error, path: destination.path) }
    }

    public func syncFile(at url: URL) throws { try Self.fsync(path: url.path) }
    public func syncDirectory(at url: URL) throws { try Self.fsync(path: url.path) }

    public func freeSpace(at url: URL) -> Int? {
        var s = statvfs()
        guard statvfs(url.path, &s) == 0 else { return nil }
        return Int(s.f_bavail) * Int(s.f_frsize)
    }

    private static func fsync(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw PersistenceError.fromErrno(errno, path: path) }
        defer { close(fd) }
        if Foundation.fsync(fd) != 0 {
            let code = errno
            // Some file systems refuse fsync on directories; that is not a data-loss condition we can act on.
            if code == EINVAL || code == EROFS || code == ENOTSUP { return }
            throw PersistenceError.fromErrno(code, path: path)
        }
    }

    static func map(_ error: Error, path: String) -> PersistenceError {
        if let p = error as? PersistenceError { return p }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return PersistenceError.fromErrno(Int32(ns.code), path: path) }
        if ns.domain == NSCocoaErrorDomain {
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return PersistenceError.fromErrno(Int32(underlying.code), path: path)
            }
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return .diskFull
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .packageNotFound(path: path)
            case NSFileWriteFileExistsError: return .alreadyExists(path: path)
            default: break
            }
        }
        return .writeFailed(path: path, underlying: ns.localizedDescription)
    }
}

// MARK: - Fault injection

/// Wraps another file system, logs every operation and can fail or "crash"
/// at a chosen mutating step. Mutating operations are numbered from 0 in the
/// order they are attempted (`createDirectory`, `write`, `replaceItem`,
/// `removeItem`, `moveItem`, `copyOrLink`, `syncFile`, `syncDirectory`).
///
/// - `failStep(n, with:)`: the n-th mutating operation throws `error` and is
///   not applied; later operations proceed normally.
/// - `crash(atStep: n)`: the n-th and every later mutating operation throw
///   `SimulatedCrash` and are not applied, as if the process died.
public final class FaultInjectingFileSystem: FileSystem, @unchecked Sendable {
    public enum Kind: String, Sendable {
        case createDirectory, read, write, replaceItem, removeItem, moveItem, contentsOfDirectory,
             fileExists, directoryExists, fileSize, copyOrLink, syncFile, syncDirectory, freeSpace
        public var isMutating: Bool {
            switch self {
            case .createDirectory, .write, .replaceItem, .removeItem, .moveItem, .copyOrLink, .syncFile, .syncDirectory: return true
            default: return false
            }
        }
    }

    public struct Operation: Hashable, Sendable, CustomStringConvertible {
        public var kind: Kind
        public var path: String
        public var secondaryPath: String?
        /// Index among mutating operations; nil for reads.
        public var mutatingIndex: Int?
        /// True when the operation was applied to the wrapped file system.
        public var applied: Bool
        public var description: String {
            "\(mutatingIndex.map { "#\($0) " } ?? "")\(kind.rawValue) \(path)\(secondaryPath.map { " <- \($0)" } ?? "")\(applied ? "" : " (blocked)")"
        }
    }

    public let base: any FileSystem
    private let lock = NSLock()
    private var _log: [Operation] = []
    private var mutatingCount = 0
    private var failure: (step: Int, error: Error)?
    private var crashStep: Int?
    /// Only log mutating operations (default) or every call.
    public var logsReads: Bool

    public init(base: any FileSystem = LocalFileSystem(), logsReads: Bool = false) {
        self.base = base; self.logsReads = logsReads
    }

    // Configuration
    public func failStep(_ step: Int, with error: Error) { lock.lock(); failure = (step, error); lock.unlock() }
    public func crash(atStep step: Int) { lock.lock(); crashStep = step; lock.unlock() }
    public func clearFaults() { lock.lock(); failure = nil; crashStep = nil; lock.unlock() }
    public func resetCounters() { lock.lock(); mutatingCount = 0; _log.removeAll(); lock.unlock() }

    public var log: [Operation] { lock.lock(); defer { lock.unlock() }; return _log }
    public var mutatingOperations: [Operation] { log.filter { $0.mutatingIndex != nil } }
    public var mutatingOperationCount: Int { lock.lock(); defer { lock.unlock() }; return mutatingCount }
    public var hasCrashed: Bool { lock.lock(); defer { lock.unlock() }; return crashStep.map { mutatingCount > $0 } ?? false }

    private func gate(_ kind: Kind, _ path: String, _ secondary: String? = nil) throws {
        lock.lock()
        let index = mutatingCount
        mutatingCount += 1
        var op = Operation(kind: kind, path: path, secondaryPath: secondary, mutatingIndex: index, applied: true)
        var thrown: Error?
        if let crashStep, index >= crashStep {
            thrown = SimulatedCrash(step: index)
        } else if let failure, failure.step == index {
            thrown = failure.error
        }
        if thrown != nil { op.applied = false }
        _log.append(op)
        lock.unlock()
        if let thrown { throw thrown }
    }

    private func note(_ kind: Kind, _ path: String) {
        guard logsReads else { return }
        lock.lock(); _log.append(Operation(kind: kind, path: path, secondaryPath: nil, mutatingIndex: nil, applied: true)); lock.unlock()
    }

    public func createDirectory(at url: URL) throws { try gate(.createDirectory, url.path); try base.createDirectory(at: url) }
    public func read(at url: URL) throws -> Data { note(.read, url.path); return try base.read(at: url) }
    public func write(_ data: Data, to url: URL) throws { try gate(.write, url.path); try base.write(data, to: url) }
    public func replaceItem(at destination: URL, withItemAt source: URL) throws {
        try gate(.replaceItem, destination.path, source.path); try base.replaceItem(at: destination, withItemAt: source)
    }
    public func removeItem(at url: URL) throws { try gate(.removeItem, url.path); try base.removeItem(at: url) }
    public func moveItem(at source: URL, to destination: URL) throws {
        try gate(.moveItem, destination.path, source.path); try base.moveItem(at: source, to: destination)
    }
    public func contentsOfDirectory(at url: URL) throws -> [URL] { note(.contentsOfDirectory, url.path); return try base.contentsOfDirectory(at: url) }
    public func fileExists(at url: URL) -> Bool { note(.fileExists, url.path); return base.fileExists(at: url) }
    public func directoryExists(at url: URL) -> Bool { note(.directoryExists, url.path); return base.directoryExists(at: url) }
    public func fileSize(at url: URL) throws -> Int { note(.fileSize, url.path); return try base.fileSize(at: url) }
    public func copyOrLink(from source: URL, to destination: URL) throws {
        try gate(.copyOrLink, destination.path, source.path); try base.copyOrLink(from: source, to: destination)
    }
    public func syncFile(at url: URL) throws { try gate(.syncFile, url.path); try base.syncFile(at: url) }
    public func syncDirectory(at url: URL) throws { try gate(.syncDirectory, url.path); try base.syncDirectory(at: url) }
    public func freeSpace(at url: URL) -> Int? { note(.freeSpace, url.path); return base.freeSpace(at: url) }
}

// MARK: - Shared atomic-write helper

extension FileSystem {
    /// Writes `data` to `tmpURL`, fsyncs it and renames it over `destination`.
    /// Returns the byte count written.
    @discardableResult
    func writeAtomically(_ data: Data, to destination: URL, via tmpURL: URL) throws -> Int {
        try write(data, to: tmpURL)
        try syncFile(at: tmpURL)
        try replaceItem(at: destination, withItemAt: tmpURL)
        return data.count
    }

    func ensureDirectory(_ url: URL) throws {
        if !directoryExists(at: url) { try createDirectory(at: url) }
    }

    /// Recursive byte total of a file or directory tree (0 when missing).
    func totalSize(at url: URL) -> Int {
        if fileExists(at: url) { return (try? fileSize(at: url)) ?? 0 }
        guard directoryExists(at: url), let children = try? contentsOfDirectory(at: url) else { return 0 }
        return children.reduce(0) { $0 + totalSize(at: $1) }
    }
}
