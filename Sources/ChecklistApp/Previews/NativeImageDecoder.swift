import Foundation
import ImageIO
import ChecklistCore

enum NativeImageDecoder {
    static func decode(url: URL, original: Bool, index: Int = 0, crop: CGRect? = nil) throws -> (CGImage, CGSize, NativeImageMetadata) {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              index >= 0, index < min(CGImageSourceGetCount(source), FilePreviewLimits.imageFrames),
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= FilePreviewLimits.imagePixels / height else { throw FilePreviewFailure("The image is unreadable or exceeds the 80 million pixel decode limit.") }
        let decoded: CGImage?
        if original { decoded = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
        else { decoded = CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) }
        try Task.checkCancellation()
        guard var decoded else { throw FilePreviewFailure("This image format is not supported by macOS Image I/O.") }
        var displaySize = CGSize(width: width, height: height)
        if let crop {
            guard crop.minX >= 0, crop.minY >= 0, crop.width > 0, crop.height > 0,
                  crop.maxX <= Double(width), crop.maxY <= Double(height) else { throw FilePreviewFailure("The sprite frame falls outside the original image.") }
            let factor = Double(decoded.width) / Double(width)
            guard let cropped = decoded.cropping(to: CGRect(x: crop.minX * factor, y: crop.minY * factor, width: crop.width * factor, height: crop.height * factor)) else { throw FilePreviewFailure("This sprite frame cannot be decoded.") }
            decoded = cropped; displaySize = crop.size
        }
        let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
        let delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        let metadata = NativeImageMetadata(size: CGSize(width: width, height: height), frameCount: CGImageSourceGetCount(source), frameDuration: delay.isFinite ? min(max(delay, 0.02), 10) : 0.1, orientation: props[kCGImagePropertyOrientation] as? Int ?? 1)
        return (decoded, displaySize, metadata)
    }
}
