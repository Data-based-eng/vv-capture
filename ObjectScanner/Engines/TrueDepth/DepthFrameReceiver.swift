import ARKit
import simd

/// ARKit delegate that owns the accumulating cloud.
///
/// Deliberately not the engine itself. Unprojecting a depth map is far too heavy
/// for the main actor at 15 Hz, so ARKit delivers frames on a private serial
/// queue and the cloud is mutated only there — single-threaded ownership instead
/// of locks or an actor hop per frame. Snapshots are pushed to the main actor on
/// a timer for the UI.
/// `@unchecked Sendable` is sound by confinement, not by locking: every member is
/// touched only from the `ARSession.delegateQueue` this object is installed on —
/// the delegate callbacks arrive there, and `setRegion`/`finalise` are dispatched
/// onto the same serial queue by the engine.
final class DepthFrameReceiver: NSObject, ARSessionDelegate, @unchecked Sendable {

    struct Snapshot: Sendable {
        var pointCount = 0
        var framesUsed = 0
        var framesDropped = 0
        var dimensions: SIMD3<Float>?
        /// Milliseconds between the depth sample and the pose it was matched to,
        /// after interpolation. Surfaced because a large value here is the
        /// difference between a crisp cloud and a smeared one.
        var poseLagMilliseconds = 0.0
        /// Median distance to the surfaces being accepted, for distance coaching.
        var medianDepth: Float?
        /// Where the user is aiming, in world space. The region of interest is
        /// placed here when they lock it.
        var aimPoint: SIMD3<Float>?
        var isRegionLocked = false
        /// Locked region in world space, for drawing it on the camera feed.
        var regionCenter: SIMD3<Float>?
        var regionHalfExtent: Float = 0
        /// Bounded subsample for live rendering.
        var renderPoints: [SIMD3<Float>] = []
    }

    /// Mutated from `setRegion`, which the engine funnels onto the frame queue —
    /// the same queue this is read on, so no locking is needed.
    private var processor: DepthFrameProcessor
    private let onSnapshot: @Sendable (Snapshot) -> Void
    private let onTrackingChange: @Sendable (ARCamera.TrackingState) -> Void

    private var cloud: DepthPointCloud
    private var framesUsed = 0
    private var framesDropped = 0
    private var lastPoseLag = 0.0
    private var lastMedianDepth: Float?
    private var lastAimPoint: SIMD3<Float>?
    private var lastPublishTimestamp: TimeInterval = 0
    private var lastDepthTimestamp: TimeInterval = -1

    /// Recent device poses, newest last.
    ///
    /// TrueDepth depth lands on an `ARFrame` whose own timestamp is later than the
    /// depth capture — `capturedDepthDataTimestamp` says by how much. Pairing the
    /// depth with the frame's current pose therefore places every sample where the
    /// device was *after* the measurement, which is invisible while standing still
    /// and smears the cloud in proportion to how fast you move. Keeping a short
    /// history lets the pose be interpolated back to the moment the depth was
    /// actually captured.
    private var poseHistory: [(time: TimeInterval, transform: simd_float4x4)] = []
    private let poseHistoryLimit = 90

    /// Beyond this the interpolation has nothing to work with and the frame is
    /// dropped rather than integrated at the wrong place.
    private let maximumPoseExtrapolation: TimeInterval = 0.05

    /// How often a snapshot reaches the UI. Publishing every frame would rebuild
    /// the render geometry 15 times a second for no perceptible gain.
    private let publishInterval: TimeInterval = 0.3

    init(
        processor: DepthFrameProcessor,
        voxelSize: Float,
        onSnapshot: @escaping @Sendable (Snapshot) -> Void,
        onTrackingChange: @escaping @Sendable (ARCamera.TrackingState) -> Void
    ) {
        self.processor = processor
        self.cloud = DepthPointCloud(voxelSize: voxelSize)
        self.onSnapshot = onSnapshot
        self.onTrackingChange = onTrackingChange
        super.init()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let isTracking: Bool
        if case .normal = frame.camera.trackingState { isTracking = true } else { isTracking = false }

        // Every frame contributes a pose, depth or not — that is what makes the
        // history dense enough to interpolate against.
        if isTracking {
            poseHistory.append((frame.timestamp, frame.camera.transform))
            if poseHistory.count > poseHistoryLimit { poseHistory.removeFirst() }
        } else {
            // A gap in tracking makes older poses unusable for interpolation.
            poseHistory.removeAll()
        }

        // Depth arrives at roughly a quarter of the colour frame rate, so most
        // frames legitimately carry none.
        guard let depthData = frame.capturedDepthData else { return }

        // The same depth buffer is attached to several consecutive frames; adding
        // it more than once inflates the per-voxel counts and defeats
        // `pruneSingleObservations`.
        let depthTime = frame.capturedDepthDataTimestamp
        guard depthTime != lastDepthTimestamp else { return }
        lastDepthTimestamp = depthTime

        // Pose is only meaningful while tracking is normal; integrating during
        // relocalisation smears the cloud.
        guard isTracking else {
            framesDropped += 1
            return
        }

        guard let (transform, lag) = pose(at: depthTime) else {
            framesDropped += 1
            return
        }
        lastPoseLag = lag * 1000

        let output = processor.process(depthData: depthData, camera: frame.camera, transform: transform)
        lastMedianDepth = output.medianDepth
        if let aim = output.centerWorldPoint { lastAimPoint = aim }

        guard !output.points.isEmpty else { return }

        cloud.insert(output.points)
        framesUsed += 1

        if frame.timestamp - lastPublishTimestamp >= publishInterval {
            lastPublishTimestamp = frame.timestamp
            onSnapshot(makeSnapshot())
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        onTrackingChange(camera.trackingState)
    }

    // MARK: - Pose interpolation

    /// - Returns: the device pose at `time`, plus the residual error in seconds
    ///   between the requested time and the samples used.
    private func pose(at time: TimeInterval) -> (transform: simd_float4x4, lag: TimeInterval)? {
        guard let newest = poseHistory.last, let oldest = poseHistory.first else { return nil }

        // Depth stamped after the newest pose: only usable if it is very close,
        // otherwise we would be extrapolating.
        if time >= newest.time {
            let lag = time - newest.time
            return lag <= maximumPoseExtrapolation ? (newest.transform, lag) : nil
        }

        // Older than anything retained — the history has already rolled past it.
        if time < oldest.time {
            let lag = oldest.time - time
            return lag <= maximumPoseExtrapolation ? (oldest.transform, lag) : nil
        }

        for index in 1..<poseHistory.count {
            let earlier = poseHistory[index - 1]
            let later = poseHistory[index]
            guard time >= earlier.time, time <= later.time else { continue }

            let span = later.time - earlier.time
            guard span > 0 else { return (earlier.transform, 0) }

            let fraction = Float((time - earlier.time) / span)
            return (blend(earlier.transform, later.transform, fraction), 0)
        }

        return nil
    }

    /// Rigid-body interpolation: slerp the rotation, lerp the translation.
    /// Interpolating the matrices element-wise would shear the result.
    private func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ fraction: Float) -> simd_float4x4 {
        let rotation = simd_slerp(simd_quatf(a), simd_quatf(b), fraction)

        let positionA = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let positionB = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let position = positionA + (positionB - positionA) * fraction

        var result = simd_float4x4(rotation)
        result.columns.3 = SIMD4<Float>(position, 1)
        return result
    }

    // MARK: - Results

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            pointCount: cloud.pointCount,
            framesUsed: framesUsed,
            framesDropped: framesDropped,
            dimensions: cloud.dimensions,
            poseLagMilliseconds: lastPoseLag,
            medianDepth: lastMedianDepth,
            aimPoint: lastAimPoint,
            isRegionLocked: processor.region != nil,
            regionCenter: processor.region?.center,
            regionHalfExtent: processor.region?.halfExtent ?? 0,
            renderPoints: cloud.sampledPoints(limit: 30_000)
        )
    }

    /// Sets or clears the region of interest.
    ///
    /// The cloud is reset with it: points already accumulated outside the new region
    /// would otherwise survive and the reported dimensions would still describe the
    /// room. Must be called on the delegate queue.
    func setRegion(_ region: DepthFrameProcessor.Region?) {
        processor.region = region
        cloud = DepthPointCloud(voxelSize: cloud.voxelSize)
        framesUsed = 0
        framesDropped = 0
    }

    /// Final cloud, with single-observation noise removed.
    /// Must be called on the delegate queue.
    func finalise() -> DepthPointCloud {
        cloud.pruneSingleObservations()
        return cloud
    }
}
