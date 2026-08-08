import ARKit
import AVFoundation
import CoreVideo
import simd

/// Turns one `AVDepthData` frame into world-space points.
///
/// Pure computation, no state — so it can run on whatever queue ARKit delivers
/// frames on without synchronisation.
struct DepthFrameProcessor: Sendable {

    struct Options: Sendable, Equatable {
        /// TrueDepth's structured-light pattern stops resolving below ~20 cm and
        /// gets too sparse past ~1 m.
        var minimumDepth: Float = 0.20
        var maximumDepth: Float = 1.00

        /// Maximum allowed depth difference to a neighbouring pixel, in metres.
        ///
        /// This is the substitute for a confidence map, which `AVDepthData` does
        /// not provide for TrueDepth (unlike LiDAR's `ARDepthData.confidenceMap`).
        /// Depth discontinuities produce "flying pixels" — samples interpolated
        /// across a silhouette edge that land in empty space — and they are the
        /// dominant artefact in a raw structured-light cloud.
        var maximumNeighbourDelta: Float = 0.02

        /// Sample every Nth pixel. 2 keeps roughly a quarter of the map, which is
        /// still far denser than the voxel grid can represent.
        var pixelStride: Int = 2

        /// Flips the depth map left-to-right before unprojecting.
        ///
        /// Kept as an escape hatch, not a guess: with `ARCamera`'s own intrinsics
        /// the frames already agree, so this should stay off. If a cloud ever comes
        /// out as the object's mirror image, this is the knob.
        var mirrorHorizontally = false
    }

    /// An axis-aligned world-space box to keep points inside.
    ///
    /// This is the practical answer to "the object is small in the frame": the
    /// sensor's angular resolution is fixed, so nothing adds samples — but throwing
    /// away the table and the far wall means the voxel grid, the live view and the
    /// reported dimensions all describe the object instead of the room.
    struct Region: Sendable, Equatable {
        var center: SIMD3<Float>
        var halfExtent: Float

        func contains(_ point: SIMD3<Float>) -> Bool {
            all(abs(point - center) .<= SIMD3<Float>(repeating: halfExtent))
        }
    }

    var options = Options()
    var region: Region?

    struct Output: Sendable {
        var points: [SIMD3<Float>] = []
        /// World position of the depth map's centre pixel — where the user is aiming.
        /// Used to place the region of interest without extra UI.
        var centerWorldPoint: SIMD3<Float>?
        /// Median accepted depth, for distance coaching.
        var medianDepth: Float?
    }

    /// Unprojects one depth frame into world space.
    ///
    /// Takes the whole `ARCamera` rather than just its transform, and uses
    /// `camera.intrinsics` rather than `AVDepthData.cameraCalibrationData`. That is
    /// the important part: an earlier version mixed the two, opening the depth map
    /// with the depth sensor's own calibration while placing the result with ARKit's
    /// pose. Those are different reference frames — any rotation or handedness
    /// difference between them puts every point in the wrong place and makes the
    /// cloud slide as the device moves. `camera.intrinsics` and `camera.transform`
    /// are by definition the same frame, so they cannot disagree.
    /// - Parameters:
    ///   - camera: supplies intrinsics and image resolution.
    ///   - transform: the pose to place points with — interpolated back to the depth
    ///     sample's own timestamp, so it is *not* `camera.transform`.
    func process(depthData: AVDepthData, camera: ARCamera, transform: simd_float4x4) -> Output {
        // The sensor may hand back disparity; the unprojection below needs metres.
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        let buffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Output() }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // ARKit publishes intrinsics against the colour image resolution; the depth
        // map is smaller. Scaling x and y independently also covers the case where
        // the two differ slightly in aspect.
        let reference = camera.imageResolution
        let scaleX = Float(width) / Float(reference.width)
        let scaleY = Float(height) / Float(reference.height)

        let intrinsics = camera.intrinsics
        let focalX = intrinsics[0][0] * scaleX
        let focalY = intrinsics[1][1] * scaleY
        let centerX = intrinsics[2][0] * scaleX
        let centerY = intrinsics[2][1] * scaleY

        guard focalX > 0, focalY > 0 else { return Output() }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity((width / options.pixelStride) * (height / options.pixelStride) / 2)

        // Collected so the caller can coach distance without a second pass over the
        // buffer. Depths are gathered unsorted and the median taken at the end.
        var acceptedDepths: [Float] = []
        acceptedDepths.reserveCapacity(points.capacity)
        var centerWorldPoint: SIMD3<Float>?

        let stride = options.pixelStride
        let centerRow = height / 2
        let centerColumn = width / 2

        for row in stride..<(height - stride) where row % stride == 0 {
            let rowPointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            let nextRowPointer = base.advanced(by: (row + stride) * bytesPerRow).assumingMemoryBound(to: Float32.self)

            for column in stride..<(width - stride) where column % stride == 0 {
                let depth = rowPointer[column]

                guard depth.isFinite,
                      depth >= options.minimumDepth,
                      depth <= options.maximumDepth
                else { continue }

                // Flying-pixel rejection: compare against the right and lower
                // neighbours. A sample straddling a silhouette edge disagrees
                // sharply with at least one of them.
                let right = rowPointer[column + stride]
                let below = nextRowPointer[column]
                if right.isFinite, abs(right - depth) > options.maximumNeighbourDelta { continue }
                if below.isFinite, abs(below - depth) > options.maximumNeighbourDelta { continue }

                let pixelX = options.mirrorHorizontally ? Float(width - 1 - column) : Float(column)
                let pixelY = Float(row)

                // Pinhole unprojection gives +X right, +Y down, +Z into the scene.
                // ARKit camera space is +X right, +Y up, −Z forward, hence the two
                // sign flips.
                let cameraSpace = SIMD4<Float>(
                    (pixelX - centerX) * depth / focalX,
                    -(pixelY - centerY) * depth / focalY,
                    -depth,
                    1
                )

                let world = transform * cameraSpace
                let worldPoint = SIMD3<Float>(world.x, world.y, world.z)

                // Captured before the region test: the aim point has to be reachable
                // even when nothing is inside the region yet, otherwise the region
                // could never be placed.
                if centerWorldPoint == nil,
                   abs(row - centerRow) <= stride,
                   abs(column - centerColumn) <= stride {
                    centerWorldPoint = worldPoint
                }

                if let region, !region.contains(worldPoint) { continue }

                acceptedDepths.append(depth)
                points.append(worldPoint)
            }
        }

        return Output(
            points: points,
            centerWorldPoint: centerWorldPoint,
            medianDepth: acceptedDepths.isEmpty
                ? nil
                : acceptedDepths.sorted()[acceptedDepths.count / 2]
        )
    }
}
