import Foundation
import CryptoKit
import UIKit
import DocumentCore

// Asset creation for the editor. Hashing uses CryptoKit (hardware SHA-256)
// because ink blobs are registered right after a stroke ends; the digest is
// the same standard SHA-256 that `DocumentCore.SHA256` and Persistence verify.

enum EditorAssets {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pendingAsset(data: Data, mediaType: AssetMediaType, originalFileName: String? = nil, now: Date) -> PendingAsset {
        let asset = SourceAsset(sha256: sha256Hex(data), mediaType: mediaType, byteCount: data.count,
                                originalFileName: originalFileName, pageCount: nil, importedAt: now)
        return PendingAsset(asset: asset, data: data)
    }

    /// PNG or JPEG by magic number; nil for anything else.
    static func imageMediaType(of data: Data) -> AssetMediaType? {
        guard data.count >= 4 else { return nil }
        let head = [UInt8](data.prefix(4))
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return .png }
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        return nil
    }

    /// Bytes to store for an inserted image: the original PNG/JPEG when it is
    /// reasonably sized, otherwise a re-encoded, downscaled JPEG.
    static func storableImage(from data: Data?, image: UIImage?, maxBytes: Int = 12 * 1024 * 1024, maxPixels: CGFloat = 4096) -> (Data, AssetMediaType, CGSize)? {
        if let data, data.count <= maxBytes, let type = imageMediaType(of: data), let decoded = image ?? UIImage(data: data),
           max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale) <= maxPixels {
            return (data, type, CGSize(width: decoded.size.width * decoded.scale, height: decoded.size.height * decoded.scale))
        }
        guard let source = image ?? data.flatMap(UIImage.init(data:)) else { return nil }
        let pixelSize = CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
        let factor = min(1, maxPixels / max(pixelSize.width, pixelSize.height, 1))
        let target = CGSize(width: floor(pixelSize.width * factor), height: floor(pixelSize.height * factor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        if let png = rendered.pngData(), png.count <= maxBytes { return (png, .png, target) }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.85) else { return nil }
        return (jpeg, .jpeg, target)
    }
}
