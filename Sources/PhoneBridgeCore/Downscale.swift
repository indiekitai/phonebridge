import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks screenshots before they're saved or copied. Pasting a full-resolution
/// tablet screenshot into an AI chat costs several times the tokens of a ~1000 px one,
/// and the extra pixels rarely help.
public enum Downscale {
    /// Long-edge choices offered in Settings. 0 means keep the original.
    public static let choices = [0, 1568, 1280, 1000, 768]
    public static let defaultMaxEdge = 1000

    /// Pixel size of encoded image data, or nil if it can't be read.
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// PNG data as is; any other image format ImageIO can read (JPEG from hdc) re-encoded as PNG;
    /// nil for data that isn't a decodable image.
    public static func toPNG(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return pixelSize(data) == nil ? nil : data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// Returns PNG data whose long edge is at most `maxEdge` pixels, keeping the aspect ratio.
    /// Images already within the limit, `maxEdge <= 0`, or data that can't be decoded
    /// come back unchanged.
    public static func png(_ data: Data, maxEdge: Int) -> Data {
        guard maxEdge > 0,
              let size = pixelSize(data), max(size.width, size.height) > maxEdge,
              let src = CGImageSourceCreateWithData(data as CFData, nil)
        else { return data }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return data }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { return data }
        return out as Data
    }
}
