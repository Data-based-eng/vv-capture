import CoreVideo

/// Relative sharpness of a preview buffer.
///
/// Motion blur is the single most destructive input error in photogrammetry: a
/// soft frame does not merely contribute less, it contributes *wrong* feature
/// matches and can pull the whole alignment off. One bad frame is worse than a
/// missing angle, which is why blurred shots are dropped rather than kept.
///
/// The metric is gradient energy — mean squared difference between horizontally
/// adjacent pixels. It has no absolute meaning, only relative: the same scene shot
/// sharp scores several times higher than the same scene shot soft. That is enough
/// to compare frames within one session.
enum SharpnessMeter {

    static func score(_ buffer: CVPixelBuffer) -> Float? {
        let format = CVPixelBufferGetPixelFormatType(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 8, height > 8 else { return nil }

        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            return gradientEnergy(
                base: base,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                width: width,
                height: height,
                bytesPerPixel: 4,
                // Green carries most of the luminance in a Bayer-derived image and
                // needs no colour conversion.
                channelOffset: 1
            )

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            // Plane 0 is luma — exactly what a sharpness metric wants.
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            return gradientEnergy(
                base: base,
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                bytesPerPixel: 1,
                channelOffset: 0
            )

        default:
            return nil
        }
    }

    private static func gradientEnergy(
        base: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        channelOffset: Int
    ) -> Float {
        var total: Double = 0
        var samples = 0

        // Every other row is plenty for a relative score and halves the work.
        for row in stride(from: 0, to: height, by: 2) {
            let rowBase = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<(width - 1) {
                let left = Int(rowBase[column * bytesPerPixel + channelOffset])
                let right = Int(rowBase[(column + 1) * bytesPerPixel + channelOffset])
                let difference = Double(right - left)
                total += difference * difference
                samples += 1
            }
        }

        return samples > 0 ? Float(total / Double(samples)) : 0
    }
}
