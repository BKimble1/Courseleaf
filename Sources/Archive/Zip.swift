import Foundation
import DocumentCore

// A deliberately minimal ZIP implementation: stored (method 0) entries only,
// CRC-32 per entry, UTF-8 names, one central directory, no ZIP64, no
// encryption, no data descriptors. This is all the `.courseleaf` container
// needs (docs/FORMAT.md section 4) and it keeps the parser small enough to
// validate every offset before any byte of entry data is trusted.

enum ZipConstants {
    static let localHeaderSignature: UInt32 = 0x0403_4B50
    static let centralHeaderSignature: UInt32 = 0x0201_4B50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x0706_4B50
    static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    static let localHeaderSize = 30
    static let centralHeaderSize = 46
    static let endOfCentralDirectorySize = 22
    static let maxCommentLength = 0xFFFF
    /// Flag bit 11: file name and comment are UTF-8.
    static let utf8Flag: UInt16 = 0x0800
    static let encryptedFlag: UInt16 = 0x0001
    static let dataDescriptorFlag: UInt16 = 0x0008
    static let versionNeeded: UInt16 = 10   // 1.0: stored entries
    static let versionMadeBy: UInt16 = 0x031E  // UNIX, 3.0
    static let maxNonZip64: UInt64 = 0xFFFF_FFFF
    static let maxEntriesNonZip64 = 0xFFFF
}

// MARK: - Little-endian helpers

struct ByteWriter {
    private(set) var bytes: [UInt8] = []
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8(v >> 24))
    }
    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    var data: Data { Data(bytes) }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    var remaining: Int { bytes.count - offset }
    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ArchiveError.corruptZip("unexpected end of data") }
        let v = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        offset += 2; return v
    }
    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ArchiveError.corruptZip("unexpected end of data") }
        let v = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        offset += 4; return v
    }
    mutating func raw(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw ArchiveError.corruptZip("unexpected end of data") }
        let out = Array(bytes[offset..<offset + n]); offset += n; return out
    }
}

/// MS-DOS date/time pair used by ZIP headers (2-second resolution, UTC here).
struct DOSDateTime {
    let time: UInt16
    let date: UInt16
    init(_ date: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = min(max(c.year ?? 1980, 1980), 2107)
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let dateValue: Int = ((year - 1980) << 9) | (month << 5) | day
        let timeValue: Int = (hour << 11) | (minute << 5) | (second / 2)
        self.date = UInt16(dateValue)
        self.time = UInt16(timeValue)
    }
}

// MARK: - Writer

/// Writes a stored-only ZIP file entry by entry to a `FileHandle`. Entry
/// payloads are written as soon as they are supplied, so a caller that
/// fetches one asset at a time never holds two large assets in memory.
public final class ZipWriter {
    public struct WrittenEntry: Hashable, Sendable {
        public let name: String
        public let size: UInt64
        public let crc32: UInt32
        public let localHeaderOffset: UInt64
    }

    public let url: URL
    public private(set) var entries: [WrittenEntry] = []
    private var names = Set<String>()
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var finished = false
    private let dosTime: DOSDateTime
    /// Chunk size used when copying files into the archive.
    public var chunkSize = 1 << 20

    /// Creates (or truncates) the file at `url`. `modificationDate` is stamped
    /// on every entry so output is deterministic for a given input.
    public init(url: URL, modificationDate: Date = Date()) throws {
        self.url = url
        dosTime = DOSDateTime(modificationDate)
        let path = url.path
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw ArchiveError.io("cannot create \(path)")
        }
        do { handle = try FileHandle(forWritingTo: url) } catch { throw ArchiveError.io("cannot open \(path) for writing: \(error)") }
    }

    deinit { if !finished { try? handle.close() } }

    /// Adds one entry whose bytes are already in memory.
    @discardableResult
    public func addEntry(name: String, data: Data) throws -> WrittenEntry {
        try beginEntry(name: name, size: UInt64(data.count), crc32: CRC32.checksum(data))
        try write(data)
        return try endEntry(name: name)
    }

    /// Adds one entry by streaming a file in `chunkSize` pieces (two passes:
    /// one to compute size and CRC, one to copy).
    @discardableResult
    public func addEntry(name: String, fileURL: URL) throws -> WrittenEntry {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: fileURL) } catch { throw ArchiveError.io("cannot open \(fileURL.path): \(error)") }
        defer { try? input.close() }
        var size: UInt64 = 0
        var crc: UInt32 = 0
        while let chunk = try readChunk(input), !chunk.isEmpty {
            size += UInt64(chunk.count)
            crc = CRC32.checksum(chunk, seed: crc)
        }
        try beginEntry(name: name, size: size, crc32: crc)
        do { try input.seek(toOffset: 0) } catch { throw ArchiveError.io("cannot rewind \(fileURL.path): \(error)") }
        var copied: UInt64 = 0
        while let chunk = try readChunk(input), !chunk.isEmpty {
            copied += UInt64(chunk.count)
            guard copied <= size else { throw ArchiveError.io("\(fileURL.path) grew while being archived") }
            try write(chunk)
        }
        guard copied == size else { throw ArchiveError.io("\(fileURL.path) shrank while being archived") }
        return try endEntry(name: name)
    }

    private func readChunk(_ h: FileHandle) throws -> Data? {
        do { return try h.read(upToCount: chunkSize) } catch { throw ArchiveError.io("read failed: \(error)") }
    }

    private var pending: (name: String, size: UInt64, crc32: UInt32, offset: UInt64)?

    private func beginEntry(name: String, size: UInt64, crc32: UInt32) throws {
        guard !finished else { throw ArchiveError.io("archive already finished") }
        guard pending == nil else { throw ArchiveError.io("previous entry not finished") }
        try ArchivePath.validate(name)
        guard !names.contains(name) else { throw ArchiveError.duplicateEntry(name) }
        guard entries.count < ZipConstants.maxEntriesNonZip64 else { throw ArchiveError.zip64Unsupported }
        guard size < ZipConstants.maxNonZip64 else { throw ArchiveError.zip64Unsupported }
        let nameBytes = [UInt8](name.utf8)
        guard nameBytes.count <= 0xFFFF else { throw ArchiveError.invalidPath(name) }
        guard offset < ZipConstants.maxNonZip64 else { throw ArchiveError.zip64Unsupported }
        // The entry must end below 4 GiB as well, or the central directory offset would need ZIP64.
        let headerLength = UInt64(ZipConstants.localHeaderSize + nameBytes.count)
        guard offset + headerLength + size < ZipConstants.maxNonZip64 else { throw ArchiveError.zip64Unsupported }
        var w = ByteWriter()
        w.u32(ZipConstants.localHeaderSignature)
        w.u16(ZipConstants.versionNeeded)
        w.u16(ZipConstants.utf8Flag)
        w.u16(0)  // stored
        w.u16(dosTime.time); w.u16(dosTime.date)
        w.u32(crc32)
        w.u32(UInt32(size)); w.u32(UInt32(size))
        w.u16(UInt16(nameBytes.count)); w.u16(0)
        w.raw(nameBytes)
        pending = (name, size, crc32, offset)
        try write(w.data)
    }

    private func endEntry(name: String) throws -> WrittenEntry {
        guard let p = pending, p.name == name else { throw ArchiveError.io("entry bookkeeping mismatch") }
        pending = nil
        let entry = WrittenEntry(name: p.name, size: p.size, crc32: p.crc32, localHeaderOffset: p.offset)
        entries.append(entry)
        names.insert(name)
        return entry
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        do { try handle.write(contentsOf: data) } catch { throw ArchiveError.io("write failed: \(error)") }
        offset += UInt64(data.count)
    }

    /// Writes the central directory and end record, syncs and closes the file.
    public func finish() throws {
        guard !finished else { return }
        guard pending == nil else { throw ArchiveError.io("entry not finished") }
        let cdOffset = offset
        var w = ByteWriter()
        for e in entries {
            let nameBytes = [UInt8](e.name.utf8)
            w.u32(ZipConstants.centralHeaderSignature)
            w.u16(ZipConstants.versionMadeBy)
            w.u16(ZipConstants.versionNeeded)
            w.u16(ZipConstants.utf8Flag)
            w.u16(0)
            w.u16(dosTime.time); w.u16(dosTime.date)
            w.u32(e.crc32)
            w.u32(UInt32(e.size)); w.u32(UInt32(e.size))
            w.u16(UInt16(nameBytes.count)); w.u16(0); w.u16(0)
            w.u16(0); w.u16(0)
            w.u32(0o100644 << 16)  // regular file rw-r--r--
            w.u32(UInt32(e.localHeaderOffset))
            w.raw(nameBytes)
        }
        let cdSize = UInt64(w.bytes.count)
        guard cdOffset + cdSize < ZipConstants.maxNonZip64 else { throw ArchiveError.zip64Unsupported }
        w.u32(ZipConstants.endOfCentralDirectorySignature)
        w.u16(0); w.u16(0)
        w.u16(UInt16(entries.count)); w.u16(UInt16(entries.count))
        w.u32(UInt32(cdSize)); w.u32(UInt32(cdOffset))
        w.u16(0)
        try write(w.data)
        do { try handle.synchronize(); try handle.close() } catch { throw ArchiveError.io("close failed: \(error)") }
        finished = true
    }
}

// MARK: - Reader

/// Parses and validates the structure of a stored-only ZIP file. Entry data
/// is read on demand and CRC-checked; nothing is written to disk.
public final class ZipReader: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let crc32: UInt32
        public let size: UInt64
        public let localHeaderOffset: UInt64
        public let dataOffset: UInt64
        public var dataEnd: UInt64 { dataOffset + size }
    }

    public let url: URL
    public let fileSize: UInt64
    /// Entries in central-directory order. Names are unique.
    public let entries: [Entry]
    public let centralDirectoryOffset: UInt64
    private let handle: FileHandle
    private let lock = NSLock()
    private let byName: [String: Int]
    public var chunkSize = 1 << 20

    public init(url: URL) throws {
        self.url = url
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ArchiveError.io("cannot open \(url.path): \(error)") }
        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd() } catch { try? handle.close(); throw ArchiveError.io("cannot determine size of \(url.path): \(error)") }
        let parsed: (entries: [Entry], byName: [String: Int], centralDirectoryOffset: UInt64)
        do { parsed = try Self.parse(handle: handle, fileSize: fileSize) } catch { try? handle.close(); throw error }
        self.handle = handle
        self.fileSize = fileSize
        self.entries = parsed.entries
        self.byName = parsed.byName
        self.centralDirectoryOffset = parsed.centralDirectoryOffset
    }

    /// Parses and cross-checks the end record, central directory and every
    /// local header. Nothing is trusted until every offset has been bounded.
    private static func parse(handle: FileHandle, fileSize: UInt64) throws -> (entries: [Entry], byName: [String: Int], centralDirectoryOffset: UInt64) {
        // Locate the end-of-central-directory record in the tail.
        let tailLength = Int(min(fileSize, UInt64(ZipConstants.endOfCentralDirectorySize + ZipConstants.maxCommentLength)))
        guard tailLength >= ZipConstants.endOfCentralDirectorySize else {
            throw ArchiveError.corruptZip("file too small to be a ZIP archive")
        }
        let tailStart = fileSize - UInt64(tailLength)
        let tail = try Self.read(handle, at: tailStart, count: tailLength)
        let tailBytes = [UInt8](tail)
        var eocdPos: Int? = nil
        var i = tailBytes.count - ZipConstants.endOfCentralDirectorySize
        while i >= 0 {
            if tailBytes[i] == 0x50 && tailBytes[i + 1] == 0x4B && tailBytes[i + 2] == 0x05 && tailBytes[i + 3] == 0x06 {
                // Accept only if the comment length matches the remaining bytes.
                let commentLen = Int(tailBytes[i + 20]) | Int(tailBytes[i + 21]) << 8
                if i + ZipConstants.endOfCentralDirectorySize + commentLen == tailBytes.count { eocdPos = i; break }
            }
            i -= 1
        }
        guard let eocd = eocdPos else { throw ArchiveError.corruptZip("end of central directory record not found") }
        let eocdOffset = tailStart + UInt64(eocd)
        var r = ByteReader(Data(tailBytes[eocd..<eocd + ZipConstants.endOfCentralDirectorySize]))
        _ = try r.u32()
        let diskNumber = try r.u16(), cdDisk = try r.u16()
        let entriesOnDisk = try r.u16(), totalEntries = try r.u16()
        let cdSize = UInt64(try r.u32()), cdOffset = UInt64(try r.u32())
        if diskNumber == 0xFFFF || cdDisk == 0xFFFF || entriesOnDisk == 0xFFFF || totalEntries == 0xFFFF
            || cdSize == ZipConstants.maxNonZip64 || cdOffset == ZipConstants.maxNonZip64 {
            throw ArchiveError.zip64Unsupported
        }
        // A ZIP64 locator directly precedes the EOCD when present.
        if eocd >= 20 {
            let loc = ByteReader(Data(tailBytes[eocd - 20..<eocd - 16]))
            var l = loc
            if (try? l.u32()) == ZipConstants.zip64EndOfCentralDirectoryLocatorSignature { throw ArchiveError.zip64Unsupported }
        }
        guard diskNumber == 0, cdDisk == 0, entriesOnDisk == totalEntries else {
            throw ArchiveError.corruptZip("multi-disk archives are not supported")
        }
        guard cdOffset <= eocdOffset, cdSize <= eocdOffset - cdOffset else {
            throw ArchiveError.corruptZip("central directory out of bounds")
        }
        guard cdOffset + cdSize == eocdOffset else {
            throw ArchiveError.corruptZip("central directory does not end at the end record")
        }
        // Parse the central directory.
        let cd = try Self.read(handle, at: cdOffset, count: Int(cdSize))
        var cr = ByteReader(cd)
        var parsed: [Entry] = []
        var names: [String: Int] = [:]
        for _ in 0..<Int(totalEntries) {
            guard try cr.u32() == ZipConstants.centralHeaderSignature else { throw ArchiveError.corruptZip("bad central directory header") }
            _ = try cr.u16()  // version made by
            _ = try cr.u16()  // version needed
            let flags = try cr.u16()
            let method = try cr.u16()
            _ = try cr.u16(); _ = try cr.u16()
            let crc = try cr.u32()
            let csize = UInt64(try cr.u32()), usize = UInt64(try cr.u32())
            let nameLen = Int(try cr.u16()), extraLen = Int(try cr.u16()), commentLen = Int(try cr.u16())
            let disk = try cr.u16()
            _ = try cr.u16(); _ = try cr.u32()
            let localOffset = UInt64(try cr.u32())
            let nameBytes = try cr.raw(nameLen)
            let extra = try cr.raw(extraLen)
            _ = try cr.raw(commentLen)
            if csize == ZipConstants.maxNonZip64 || usize == ZipConstants.maxNonZip64 || localOffset == ZipConstants.maxNonZip64 || disk == 0xFFFF {
                throw ArchiveError.zip64Unsupported
            }
            if Self.hasZip64Extra(extra) { throw ArchiveError.zip64Unsupported }
            guard flags & ZipConstants.encryptedFlag == 0 else { throw ArchiveError.corruptZip("encrypted entries are not supported") }
            guard flags & ZipConstants.dataDescriptorFlag == 0 else { throw ArchiveError.corruptZip("data descriptors are not supported") }
            guard method == 0 else { throw ArchiveError.corruptZip("compressed entries are not supported") }
            guard csize == usize else { throw ArchiveError.corruptZip("stored entry with differing sizes") }
            guard disk == 0 else { throw ArchiveError.corruptZip("multi-disk archives are not supported") }
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw ArchiveError.corruptZip("entry name is not UTF-8") }
            guard names[name] == nil else { throw ArchiveError.duplicateEntry(name) }
            guard localOffset < cdOffset, cdOffset - localOffset >= UInt64(ZipConstants.localHeaderSize) else {
                throw ArchiveError.corruptZip("local header offset out of bounds for '\(name)'")
            }
            // Validate the local header against the central record.
            let lh = try Self.read(handle, at: localOffset, count: ZipConstants.localHeaderSize)
            var lr = ByteReader(lh)
            guard try lr.u32() == ZipConstants.localHeaderSignature else { throw ArchiveError.corruptZip("bad local header for '\(name)'") }
            _ = try lr.u16()
            let lflags = try lr.u16(), lmethod = try lr.u16()
            _ = try lr.u16(); _ = try lr.u16()
            let lcrc = try lr.u32()
            let lcsize = UInt64(try lr.u32()), lusize = UInt64(try lr.u32())
            let lnameLen = Int(try lr.u16()), lextraLen = Int(try lr.u16())
            guard lmethod == 0, lflags & (ZipConstants.encryptedFlag | ZipConstants.dataDescriptorFlag) == 0 else {
                throw ArchiveError.corruptZip("local header of '\(name)' uses unsupported features")
            }
            guard lcrc == crc, lcsize == usize, lusize == usize else {
                throw ArchiveError.corruptZip("local header of '\(name)' disagrees with the central directory")
            }
            let headerEnd = localOffset + UInt64(ZipConstants.localHeaderSize) + UInt64(lnameLen) + UInt64(lextraLen)
            guard headerEnd <= cdOffset, cdOffset - headerEnd >= usize else {
                throw ArchiveError.corruptZip("entry '\(name)' extends past the central directory")
            }
            let lname = try Self.read(handle, at: localOffset + UInt64(ZipConstants.localHeaderSize), count: lnameLen)
            guard [UInt8](lname) == nameBytes else { throw ArchiveError.corruptZip("local header name differs for '\(name)'") }
            if lextraLen > 0 {
                let lextra = try Self.read(handle, at: localOffset + UInt64(ZipConstants.localHeaderSize + lnameLen), count: lextraLen)
                if Self.hasZip64Extra([UInt8](lextra)) { throw ArchiveError.zip64Unsupported }
            }
            names[name] = parsed.count
            parsed.append(Entry(name: name, crc32: crc, size: usize, localHeaderOffset: localOffset, dataOffset: headerEnd))
        }
        guard cr.remaining == 0 else { throw ArchiveError.corruptZip("trailing bytes in the central directory") }
        // No two entries may overlap.
        let sorted = parsed.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.dataEnd > b.localHeaderOffset {
            throw ArchiveError.corruptZip("entries '\(a.name)' and '\(b.name)' overlap")
        }
        return (parsed, names, cdOffset)
    }

    deinit { try? handle.close() }

    private static func hasZip64Extra(_ extra: [UInt8]) -> Bool {
        var i = 0
        while i + 4 <= extra.count {
            let id = UInt16(extra[i]) | UInt16(extra[i + 1]) << 8
            let len = Int(extra[i + 2]) | Int(extra[i + 3]) << 8
            if id == 0x0001 { return true }
            i += 4 + len
        }
        return false
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw ArchiveError.corruptZip("negative read") }
        if count == 0 { return Data() }
        do {
            try handle.seek(toOffset: offset)
            guard let d = try handle.read(upToCount: count), d.count == count else { throw ArchiveError.corruptZip("truncated file") }
            return d
        } catch let e as ArchiveError { throw e } catch { throw ArchiveError.io("read failed: \(error)") }
    }

    public func entry(named name: String) -> Entry? { byName[name].map { entries[$0] } }

    /// Streams the entry's bytes in chunks; throws `checksumMismatch` if the
    /// CRC-32 of the delivered bytes differs from the recorded one. The whole
    /// entry is delivered before the CRC is known, so callers that must not
    /// act on unverified bytes should buffer or hash and decide afterwards.
    public func forEachChunk(of entry: Entry, _ body: (Data) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var remaining = entry.size
        var pos = entry.dataOffset
        var crc: UInt32 = 0
        while remaining > 0 {
            let n = Int(min(UInt64(chunkSize), remaining))
            let chunk = try Self.read(handle, at: pos, count: n)
            crc = CRC32.checksum(chunk, seed: crc)
            try body(chunk)
            pos += UInt64(n); remaining -= UInt64(n)
        }
        guard crc == entry.crc32 else { throw ArchiveError.checksumMismatch(entry.name) }
    }

    /// Reads one entry fully and verifies its CRC before returning.
    public func data(for entry: Entry) throws -> Data {
        var out = Data(); out.reserveCapacity(Int(entry.size))
        try forEachChunk(of: entry) { out.append($0) }
        return out
    }

    public func data(named name: String) throws -> Data {
        guard let e = entry(named: name) else { throw ArchiveError.missingEntry(name) }
        return try data(for: e)
    }
}
