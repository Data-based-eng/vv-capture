import CoreVideo
import Foundation

/// Builds the single-channel mask that tells `PhotogrammetrySession` which pixels
/// belong to the object.
///
/// This is the reliable way to exclude a background, and it is only practical in
/// turntable mode: the device does not move, so the object stays in the same part
/// of every frame and one rectangle covers the whole set. In orbit mode the object
/// moves across the frame constantly and a fixed rectangle would be meaningless —
/// which is why that mode relies on ARKit's bounding box instead.
///
/// Mask-space contract (C3 stamping side): the incoming rect is in NORMALIZED
/// UPRIGHT-PORTRAIT image space — origin top-left, 0…1 — the same space as the
/// EXIF-upright portrait buffers the samples decode to. The capture UI has
/// already derotated the drag rect out of the sensor-native landscape space, so
/// this stamps it with NO rotation. The old code assumed the rect was still in
/// sensor-native landscape coordinates (as `metadataOutputRectConverted` yields),
/// which rotated every mask 90° and silently masked the wrong pixels.
enum ObjectMaskBuilder {

    /// - Parameter normalizedRect: region to keep, in normalized upright-portrait
    ///   image coordinates, origin at the top-left.
    /// - Returns: a `kCVPixelFormatType_OneComponent8` buffer, 255 inside the region
    ///   and 0 outside.
    static func makeMask(width: Int, height: Int, normalizedRect: CGRect) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: false,
            kCVPixelBufferCGBitmapContextCompatibilityKey: false,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &buffer
        )

        guard status == kCVReturnSuccess, let mask = buffer else { return nil }

        CVPixelBufferLockBaseAddress(mask, [])
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }

        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)

        // Upright-portrait mapping: normalized minX → pixel columns, normalized
        // minY → pixel rows (row 0 is the top of the upright image). No rotation,
        // no axis swap — the rect is already in this space.
        //
        // Clamped so a rectangle dragged past the edge still produces a valid mask
        // rather than writing outside the buffer.
        let left = max(0, Int((normalizedRect.minX * CGFloat(width)).rounded()))
        let right = min(width, Int((normalizedRect.maxX * CGFloat(width)).rounded()))
        let top = max(0, Int((normalizedRect.minY * CGFloat(height)).rounded()))
        let bottom = min(height, Int((normalizedRect.maxY * CGFloat(height)).rounded()))

        let pointer = base.assumingMemoryBound(to: UInt8.self)

        for row in 0..<height {
            let rowStart = pointer.advanced(by: row * bytesPerRow)
            if row < top || row >= bottom {
                rowStart.update(repeating: 0, count: width)
            } else {
                rowStart.update(repeating: 0, count: width)
                if right > left {
                    rowStart.advanced(by: left).update(repeating: 255, count: right - left)
                }
            }
        }

        return mask
    }
}
