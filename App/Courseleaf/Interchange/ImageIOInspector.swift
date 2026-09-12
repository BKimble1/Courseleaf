import Foundation
import ImageIO
import UniformTypeIdentifiers
import DocumentCore

/// `ImageInspecting` backed by ImageIO. Only the container properties are
/// read (`CGImageSourceCopyPropertiesAtIndex`); no pixel data is decoded.
///
/// Dimensions are reported as the image will be *displayed*: when a JPEG
/// carries an EXIF orientation of 5–8 (rotated 90°/270°) the stored width and
/// height are swapped, because the app draws images with their orientation
/// applied and the image page's aspect ratio must match what is drawn.
/// PNGs from `Fixtures.MinimalPNGWriter` have no orientation and report their
/// header size exactly like `Fixtures.ImageHeaderInspector`.
struct ImageIOInspector: ImageInspecting {
    init() {}

    func inspect(data: Data) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImageInspectionError.unsupported }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier) else { throw ImageInspectionError.unsupported }
        let mediaType: AssetMediaType
        if type.conforms(to: .png) {
            mediaType = .png
        } else if type.conforms(to: .jpeg) {
            mediaType = .jpeg
        } else {
            throw ImageInspectionError.unsupported
        }
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw ImageInspectionError.corrupt
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swaps = (5...8).contains(orientation)
        return ImageInfo(pixelWidth: swaps ? height : width, pixelHeight: swaps ? width : height, mediaType: mediaType)
    }
}
