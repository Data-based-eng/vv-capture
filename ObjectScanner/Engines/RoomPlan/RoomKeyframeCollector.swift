import ARKit
import CoreImage
import Foundation
import ImageIO
import Observation
import os
import simd

/// Saves camera stills during a room walk so photogrammetry can produce a
/// *photographic* model of the same room.
///
/// RoomPlan itself never emits colour — its output is geometry, by design. The
/// only source of real appearance is the camera, and the camera frames are already
/// flowing through the AR session RoomPlan runs on. This picks keyframes out of
/// that stream.
///
/// Frames are polled from `arSession.currentFrame` rather than taken from a
/// delegate: `RoomCaptureView` needs to stay the session's delegate, because that
/// is what draws the live wireframe.
@MainActor
@Observable
final class RoomKeyframeCollector {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "keyframes")

    /// Below this the solver has nothing to work with, so the attempt is skipped
    /// rather than run and failed.
    static let minimumFrames = 20

    /// Ceiling on frames.
    ///
    /// Raised from 160 after measuring a 75-frame walk: the solver skipped 20 of
    /// them and the resulting shell was torn. A room is roughly fifty times the
    /// surface area of a hand-held object, and guided Object Capture spends 100+
    /// frames on the object — so 75 for a whole room was never going to close.
    /// Disk is the cost, and it is the cheap resource here.
    static let maximumFrames = 300

    /// A keyframe is only worth keeping if the camera actually moved — standing
    /// still produces near-identical images that add cost and no parallax.
    ///
    /// Tightened along with the frame ceiling: denser sampling means more overlap
    /// between neighbouring views, which is exactly what stops the solver dropping
    /// frames it cannot tie to anything.
    private static let minimumTranslation: Float = 0.10
    private static let minimumRotation: Float = 0.17 // ~10°

    /// Compass sectors coverage is reported in. Sixteen is fine enough to show a
    /// missed wall and coarse enough that one frame fills a sector.
    static let sectorCount = 16

    /// Below this the camera is looking down rather than at a wall — `sin(-20°)`.
    /// The two are tracked apart because they photograph different surfaces, and a
    /// full wall pass says nothing about whether the floor was ever seen.
    private static let downwardThreshold: Float = -0.34

    /// Sectors that have a frame taken looking roughly level — the walls.
    private(set) var wallSectors: Set<Int> = []

    /// Sectors that have a frame taken looking downward — the floor and the fronts
    /// of furniture.
    private(set) var floorSectors: Set<Int> = []

    /// Where the camera is pointing right now, in radians, for the live needle.
    /// Nil until tracking settles.
    private(set) var heading: Double?

    private(set) var savedCount = 0

    /// Longest edge of the saved frames, once one has been written. Worth surfacing
    /// because it is the difference between a usable texture and a blurry one.
    private(set) var frameResolution: Int?

    private let directory: URL
    private let context = CIContext()
    private var arSession: ARSession?
    private var pollTask: Task<Void, Never>?
    private var lastTransform: simd_float4x4?

    /// True while a high-resolution capture is in flight, so the poll loop does not
    /// queue several at once.
    private var isCapturingStill = false

    init(directory: URL) {
        self.directory = directory
    }

    func start(arSession: ARSession) {
        guard pollTask == nil else { return }
        self.arSession = arSession
        logVideoFormat(of: arSession)

        // ~7 Hz. Faster than the capture logic needs, but the coverage needle is
        // driven from the same tick and at 4 Hz it visibly stuttered while turning.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                considerCurrentFrame()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        arSession = nil
    }

    // MARK: - Private

    /// Records what the camera is actually configured for.
    ///
    /// Measured because the first attempt at higher-resolution stills barely moved
    /// the numbers, and the reason matters: `captureHighResolutionFrame` can only
    /// give what the *running video format* supports, and RoomPlan chooses that
    /// format — this app never gets to. If the recommended high-resolution format
    /// is much larger than the running one, there is headroom worth chasing; if it
    /// is not, resolution is a dead end and coverage is the lever.
    private func logVideoFormat(of session: ARSession) {
        let running = session.configuration?.videoFormat
        let recommended = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing

        Self.logger.info("""
            Çalışan format: \(running.map { "\(Int($0.imageResolution.width))×\(Int($0.imageResolution.height))" } ?? "bilinmiyor", privacy: .public) \
            · yüksek çözünürlük için uygun: \(running?.isRecommendedForHighResolutionFrameCapturing == true ? "evet" : "hayır", privacy: .public) \
            · önerilen format: \(recommended.map { "\(Int($0.imageResolution.width))×\(Int($0.imageResolution.height))" } ?? "yok", privacy: .public)
            """)
    }

    private func considerCurrentFrame() {
        guard let session = arSession, let frame = session.currentFrame else { return }

        // A frame captured while tracking is degraded is still a fine *photo*, but
        // its pose is what tells us whether the camera moved, so it is skipped.
        guard case .normal = frame.camera.trackingState else { return }

        let transform = frame.camera.transform
        // Updated even when no frame is taken: the needle has to follow the phone,
        // not the capture.
        heading = Double(Self.yaw(of: Self.forward(of: transform)))

        guard !isCapturingStill, savedCount < Self.maximumFrames else { return }
        if let lastTransform, !hasMoved(from: lastTransform, to: transform) { return }

        // Committed before the capture returns: the gate is what stops the poll loop
        // from firing again at the same spot while this one is still in flight.
        lastTransform = transform
        isCapturingStill = true

        // The live `capturedImage` is only ~2.8 MP — ARKit streams it for tracking,
        // not for reconstruction. `captureHighResolutionFrame` pulls a full-resolution
        // still from the same camera without interrupting the session, which is
        // roughly four times the pixels and shows up directly in texture detail.
        session.captureHighResolutionFrame { [weak self] highResolutionFrame, error in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturingStill = false

                if let highResolutionFrame {
                    self.save(highResolutionFrame.capturedImage, transform: highResolutionFrame.camera.transform)
                } else {
                    // Not every video format offers a higher still resolution. Falling
                    // back keeps the walk productive instead of silently collecting
                    // nothing.
                    Self.logger.error("Yüksek çözünürlüklü kare alınamadı: \(error?.localizedDescription ?? "bilinmeyen", privacy: .public)")
                    if let live = self.arSession?.currentFrame {
                        self.save(live.capturedImage, transform: live.camera.transform)
                    }
                }
            }
        }
    }

    private func save(_ pixelBuffer: CVPixelBuffer, transform: simd_float4x4) {
        guard let data = jpegData(from: pixelBuffer) else {
            Self.logger.error("Kare JPEG'e çevrilemedi")
            return
        }

        // Zero-padded so directory order matches walk order — which is exactly what
        // `sampleOrdering = .sequential` promises the solver.
        let url = directory.appending(path: String(format: "kf-%04d.jpg", savedCount), directoryHint: .notDirectory)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Kare yazılamadı: \(error.localizedDescription, privacy: .public)")
            return
        }

        if frameResolution == nil {
            frameResolution = max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }
        savedCount += 1

        // Coverage is recorded from the direction the camera was *looking*, not from
        // where it stood: what got photographed is the wall in front of the lens.
        let forward = Self.forward(of: transform)
        let sector = Self.sector(of: forward)
        if forward.y <= Self.downwardThreshold {
            floorSectors.insert(sector)
        } else {
            wallSectors.insert(sector)
        }
    }

    // MARK: - Geometry helpers

    /// Camera forward is -Z in ARKit's convention.
    private static func forward(of transform: simd_float4x4) -> SIMD3<Float> {
        -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    }

    /// Heading in 0…2π, ignoring tilt.
    private static func yaw(of forward: SIMD3<Float>) -> Float {
        let angle = atan2(forward.x, -forward.z)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    private static func sector(of forward: SIMD3<Float>) -> Int {
        let normalised = yaw(of: forward) / (2 * .pi)
        return min(sectorCount - 1, Int(normalised * Float(sectorCount)))
    }

    private func hasMoved(from previous: simd_float4x4, to current: simd_float4x4) -> Bool {
        let previousPosition = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let currentPosition = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        if simd_distance(previousPosition, currentPosition) >= Self.minimumTranslation { return true }

        // Camera forward is -Z in ARKit's convention. Comparing forward vectors is
        // enough here and avoids assuming the matrix is cleanly decomposable.
        let previousForward = -SIMD3<Float>(previous.columns.2.x, previous.columns.2.y, previous.columns.2.z)
        let currentForward = -SIMD3<Float>(current.columns.2.x, current.columns.2.y, current.columns.2.z)
        let cosine = max(-1, min(1, simd_dot(simd_normalize(previousForward), simd_normalize(currentForward))))
        return acos(cosine) >= Self.minimumRotation
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        // ARKit hands back the sensor's native landscape orientation. `.right`
        // stands it up for a portrait grip; what actually matters is that every
        // frame gets the *same* rotation, since the solver recovers orientation
        // itself and a uniform rotation only turns the finished model.
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let quality = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        return context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            // Photogrammetry reads compression artefacts as surface detail, so this
            // sits higher than a normal photo export would.
            options: [quality: 0.95]
        )
    }
}
