import CoreVideo

/// Relative sharpness of an image buffer, measured as the variance of the
/// Laplacian — the metric Apple's own sample ("Finding the sharpest image in a
/// sequence") uses via vImage/vDSP, and the best single focus measure in
/// OpenCV's comparative study.
///
/// Motion blur is the single most destructive input error in photogrammetry: a
/// soft frame does not merely contribute less, it contributes *wrong* feature
/// matches and can pull the whole alignment off. One bad frame is worse than a
/// missing angle, which is why blurred shots are dropped rather than kept.
///
/// Two deliberate departures from the old gradient-energy metric:
/// - Gradient energy (Tenengrad) measures *texture*, not blur: a sharp frame of
///   a smooth surface scores below a blurry frame of a textured one, so a fixed
///   global floor systematically rejects smooth sides and leaves coverage
///   holes. The Laplacian's second derivative responds to blur itself rather
///   than edge density.
/// - Laplacian variance is noise-sensitive at full resolution (Apple's sample
///   scores at 720p for exactly this reason), so large buffers are
///   box-averaged down to a 720px long side before scoring. Small buffers are
///   used as-is, never upscaled.
///
/// A score has no absolute meaning — only relative, within one scene. Do not
/// compare scores across sessions; rank them with `percentileRanks(_:)` and
/// reject the low end of *that* sequence instead of applying a global floor.
enum SharpnessMeter {

    /// Longest side of the working image. The 3×3 Laplacian is noise-noisy at
    /// full resolution; box-averaging to this size is Apple's documented noise
    /// mitigation for the metric.
    private static let maxScoringDimension = 720

    /// Variance of the Laplacian of the luma channel. Higher is sharper.
    /// Returns nil for unreadable, too-small, or unsupported-format buffers.
    ///
    /// Size caveat: this scores whatever buffer it is given. Scoring a tiny
    /// preview buffer is cheap but inherently noisy — prefer the captured
    /// pixels (e.g. the saved shot's pixel buffer) when they are available.
    /// Whatever size arrives, the metric downsamples large inputs so full-res
    /// noise cannot inflate the score.
    static func score(_ buffer: CVPixelBuffer) -> Float? {
        guard let luma = extractLuma(buffer) else { return nil }
        let working = downsample(luma, maxDimension: maxScoringDimension)
        return laplacianVariance(working)
    }

    /// Relative rank of each score within one capture sequence, 0…1
    /// (0 = softest, 1 = sharpest). Ties keep their sorted position; a
    /// single-element sequence ranks 1.
    ///
    /// Use this instead of a global floor: per-angle or per-sequence ranking is
    /// what both Apple's sample ("order[s] the images by their relative
    /// sharpness") and OpenCV's study (argmax/rank within a set, never an
    /// absolute threshold) recommend. A sharp smooth side legitimately scores
    /// below a blurry textured one, so a fixed threshold can only be wrong
    /// somewhere.
    static func percentileRanks(scores: [Float]) -> [Double] {
        let order = scores.indices.sorted { scores[$0] < scores[$1] }
        var ranks = [Double](repeating: 0, count: scores.count)
        for (position, index) in order.enumerated() {
            ranks[index] = scores.count > 1 ? Double(position) / Double(scores.count - 1) : 1
        }
        return ranks
    }

    // MARK: - Luma extraction

    private struct LumaPlane {
        var data: [UInt8]
        let width: Int
        let height: Int
    }

    private static func extractLuma(_ buffer: CVPixelBuffer) -> LumaPlane? {
        let format = CVPixelBufferGetPixelFormatType(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        switch format {
        case kCVPixelFormatType_32BGRA:
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard width > 8, height > 8,
                  let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let src = base.assumingMemoryBound(to: UInt8.self)
            var out = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                let rowPtr = src.advanced(by: row * bytesPerRow)
                for column in 0..<width {
                    // Green carries most of the luminance in a Bayer-derived
                    // image and needs no colour conversion.
                    out[row * width + column] = rowPtr[column * 4 + 1]
                }
            }
            return LumaPlane(data: out, width: width, height: height)

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            // Plane 0 is luma — exactly what a sharpness metric wants.
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            guard width > 8, height > 8,
                  let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let src = base.assumingMemoryBound(to: UInt8.self)
            var out = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                let rowPtr = src.advanced(by: row * bytesPerRow)
                for column in 0..<width {
                    out[row * width + column] = rowPtr[column]
                }
            }
            return LumaPlane(data: out, width: width, height: height)

        default:
            return nil
        }
    }

    // MARK: - Downsampling (noise control)

    private static func downsample(_ plane: LumaPlane, maxDimension: Int) -> LumaPlane {
        let longSide = max(plane.width, plane.height)
        guard longSide > maxDimension else { return plane }

        let factor = (longSide + maxDimension - 1) / maxDimension
        let newWidth = plane.width / factor
        let newHeight = plane.height / factor
        guard newWidth > 8, newHeight > 8 else { return plane }

        var out = [UInt8](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                var sum = 0
                var count = 0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let sx = x * factor + dx
                        let sy = y * factor + dy
                        guard sx < plane.width, sy < plane.height else { continue }
                        sum += Int(plane.data[sy * plane.width + sx])
                        count += 1
                    }
                }
                out[y * newWidth + x] = UInt8(sum / max(count, 1))
            }
        }
        return LumaPlane(data: out, width: newWidth, height: newHeight)
    }

    // MARK: - Variance of the Laplacian

    private static func laplacianVariance(_ plane: LumaPlane) -> Float {
        let data = plane.data
        let width = plane.width
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0

        // 3×3 Laplacian: [0 1 0; 1 -4 1; 0 1 0]. Signed values — variance
        // handles the sign; the 1px border is skipped.
        for y in 1..<(plane.height - 1) {
            for x in 1..<(plane.width - 1) {
                let center = Int(data[y * width + x])
                let laplacian = -4 * center
                    + Int(data[(y - 1) * width + x])
                    + Int(data[(y + 1) * width + x])
                    + Int(data[y * width + x - 1])
                    + Int(data[y * width + x + 1])
                let value = Double(laplacian)
                sum += value
                sumOfSquares += value * value
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        return Float(sumOfSquares / count - mean * mean)
    }
}
