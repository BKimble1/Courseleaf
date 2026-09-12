import Foundation
import DocumentCore

/// Reads pixel dimensions from PNG (IHDR) and JPEG (SOF0/SOF1/SOF2) headers.
/// Anything else is `unsupported`; a recognised signature with a broken or
/// truncated header is `corrupt`.
public struct ImageHeaderInspector: ImageInspecting {
    public init() {}

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public func inspect(data: Data) throws -> ImageInfo {
        let b = [UInt8](data)
        if b.starts(with: Self.pngSignature) { return try png(b) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 { return try jpeg(b) }
        throw ImageInspectionError.unsupported
    }

    private func png(_ b: [UInt8]) throws -> ImageInfo {
        // Signature (8) + IHDR chunk: length(4) "IHDR"(4) width(4) height(4) ...
        guard b.count >= 24 else { throw ImageInspectionError.corrupt }
        guard be32(b, 8) == 13, Array(b[12..<16]) == Array("IHDR".utf8) else { throw ImageInspectionError.corrupt }
        let w = be32(b, 16), h = be32(b, 20)
        guard w > 0, h > 0, w < 1 << 31, h < 1 << 31 else { throw ImageInspectionError.corrupt }
        return ImageInfo(pixelWidth: Int(w), pixelHeight: Int(h), mediaType: .png)
    }

    private func jpeg(_ b: [UInt8]) throws -> ImageInfo {
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { throw ImageInspectionError.corrupt }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }            // fill byte
            if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 { i += 2; continue } // standalone
            if marker == 0xD9 || marker == 0xDA { break }      // EOI / SOS without a frame header
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { throw ImageInspectionError.corrupt }
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                guard i + 9 <= b.count, length >= 7 else { throw ImageInspectionError.corrupt }
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                guard w > 0, h > 0 else { throw ImageInspectionError.corrupt }
                return ImageInfo(pixelWidth: w, pixelHeight: h, mediaType: .jpeg)
            }
            i += 2 + length
        }
        throw ImageInspectionError.corrupt
    }

    private func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

/// Writes 8-bit RGBA PNGs using zlib *stored* (uncompressed) deflate blocks,
/// so tiny image fixtures need no compression library. Chunk CRCs use
/// `DocumentCore.CRC32`; the zlib trailer is Adler-32.
public enum MinimalPNGWriter {
    /// `rgba` holds `width * height * 4` bytes, rows top to bottom.
    public static func write(width: Int, height: Int, rgba: [UInt8]) -> Data {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4, "rgba must hold width*height*4 bytes")
        var out = ImageHeaderInspector.pngSignature
        var ihdr: [UInt8] = []
        ihdr += be32(UInt32(width)); ihdr += be32(UInt32(height))
        ihdr += [8, 6, 0, 0, 0] // bit depth 8, colour type 6 (RGBA), deflate, filter 0, no interlace
        out += chunk("IHDR", ihdr)

        var raw: [UInt8] = []
        raw.reserveCapacity(height * (width * 4 + 1))
        for row in 0..<height {
            raw.append(0) // filter type None
            raw += rgba[(row * width * 4)..<((row + 1) * width * 4)]
        }
        out += chunk("IDAT", zlibStored(raw))
        out += chunk("IEND", [])
        return Data(out)
    }

    /// A deterministic test image: horizontal red ramp, vertical green ramp, blue checker, full alpha.
    public static func sampleImage(width: Int, height: Int) -> Data {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                rgba.append(UInt8(width > 1 ? x * 255 / (width - 1) : 0))
                rgba.append(UInt8(height > 1 ? y * 255 / (height - 1) : 0))
                rgba.append(((x / 4 + y / 4) % 2 == 0) ? 200 : 40)
                rgba.append(255)
            }
        }
        return write(width: width, height: height, rgba: rgba)
    }

    static func zlibStored(_ raw: [UInt8]) -> [UInt8] {
        var z: [UInt8] = [0x78, 0x01] // CMF: deflate, 32K window; FLG: no dict, level 0, check bits ok (0x7801 % 31 == 0)
        var offset = 0
        repeat {
            let len = min(65535, raw.count - offset)
            let final: UInt8 = (offset + len >= raw.count) ? 1 : 0
            z.append(final) // BTYPE=00 stored
            z += [UInt8(len & 0xFF), UInt8(len >> 8), UInt8(~len & 0xFF), UInt8((~len >> 8) & 0xFF)]
            z += raw[offset..<offset + len]
            offset += len
        } while offset < raw.count
        z += be32(adler32(raw))
        return z
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }

    static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        var c = be32(UInt32(body.count))
        c += typeBytes
        c += body
        c += be32(CRC32.checksum(Data(typeBytes + body)))
        return c
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
