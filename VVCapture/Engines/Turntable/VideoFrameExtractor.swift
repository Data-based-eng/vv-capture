import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Outcome of the video processing pipeline.
struct VideoProcessResult: Sendable {
    var frameCount: Int
    var method: String
    var warning: String?
}

/// Outcome of one frame-extraction pass (turntable or orbit).
///
/// `skippedViews` counts target views that produced no usable frame — the
/// pipeline surfaces that as a coverage warning ("N of 48 angles yielded
/// frames") instead of silently handing a partial set to the solver.
struct FrameExtraction: Sendable {
    var count: Int
    var skippedViews: Int
}

/// Runs the whole video take pipeline off the main actor: measure the
/// rotation, then extract the sharpest frame around each target angle.
enum VideoPipeline {
    static func process(
        videoURL: URL,
        imagesURL: URL,
        manifest: YawManifest,
        nominalRevSeconds: Double,
        views: Int,
        /// 1-based index the first extracted frame takes in the shared
        /// `shot_` numbering. The turntable engine passes max(used still
        /// indices)+1 so video frames continue the still sequence instead of
        /// colliding with it; orbit passes 1 (no stills).
        firstShotIndex: Int,
        onProgress: @escaping @Sendable (VideoProcessingProgress) -> Void
    ) async throws -> VideoProcessResult {
        try await Task.detached {
            let analysis = try await YawEstimator().analyze(
                videoURL: videoURL,
                nominalRevSeconds: nominalRevSeconds
            ) { fraction in
                // Fresh value per report — no shared mutable state crosses
                // into the Sendable closure.
                onProgress(VideoProcessingProgress(
                    fraction: fraction * 0.3,
                    stage: String(localized: "Measuring rotation")
                ))
            }
            try Task.checkCancellation()
            let extraction = try await FrameExtractor().extract(
                videoURL: videoURL,
                analysis: analysis,
                views: views,
                imagesURL: imagesURL,
                manifest: manifest,
                firstShotIndex: firstShotIndex
            ) { fraction in
                onProgress(VideoProcessingProgress(
                    fraction: 0.3 + fraction * 0.7,
                    stage: String(localized: "Extracting frames")
                ))
            }
            // A view that yielded no frame is reported, not silently
            // dropped: partial coverage must not reach the solver untold.
            let coverageWarning: String? = extraction.skippedViews > 0
                ? "\(extraction.count) of \(views) angles yielded frames"
                : nil
            let warning: String?
            switch (analysis.warning, coverageWarning) {
            case let (estimatorWarning?, coverage?):
                warning = estimatorWarning + " " + coverage
            case let (estimatorWarning?, nil):
                warning = estimatorWarning
            case let (nil, coverage?):
                warning = coverage
            case (nil, nil):
                warning = nil
            }
            return VideoProcessResult(
                frameCount: extraction.count,
                method: analysis.method,
                warning: warning
            )
        }.value
    }
}

/// Pulls one sharp frame per target angle from a turntable video.
///
/// For each of `views` evenly spaced angles, several candidate frames are
/// requested around the target time via `AVAssetImageGenerator.images(for:)`;
/// each result's *actual* frame time is mapped to its true angle (never the
/// requested time) and only in-window candidates are scored. The sharpest
/// sharpest in-window frame is written as `shot_%06d.jpg` (continuing the
/// stills' numbering) straight into the
/// workspace's images directory, with its measured angle recorded in the yaw
/// manifest — so the reconstructor treats video frames exactly like stills.
///
/// Failure isolation is per-request and per-view: one bad frame or one bad
/// encode skips that view, never the whole run. A global seen-set keyed by
/// actual frame time stops adjacent windows from claiming the same physical
/// frame as two "views".
struct FrameExtractor: Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "frames")

    /// Candidates requested per target angle.
    private static let attemptsPerView = 5
    /// Floor for the measured/nominal angular velocity: below this a
    /// revolution takes two hours and the window math is meaningless.
    private static let minOmegaDegPerSec = 0.05

    /// Maps the estimator's internal method strings onto `YawEntry`'s
    /// documented vocabulary ("marker", "vision", "rpm", "timestamp").
    private static func manifestMethod(for internalMethod: String) -> String {
        switch internalMethod {
        case "video-marker": return "marker"
        case "video-rpm": return "rpm"
        case "solver": return "vision"
        default: return internalMethod
        }
    }

    func extract(
        videoURL: URL,
        analysis: VideoYawAnalysis,
        views: Int,
        imagesURL: URL,
        manifest: YawManifest,
        /// 1-based first index in the shared `shot_` sequence (see
        /// `VideoPipeline.process`). Frame `i` is written as
        /// `shot_%06d.jpg` with manifest `shot: firstShotIndex + i`.
        firstShotIndex: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> FrameExtraction {
        guard views > 0 else { return FrameExtraction(count: 0, skippedViews: 0) }

        let asset = AVURLAsset(url: videoURL)
        let baseDate = (try? FileManager.default.attributesOfItem(
            atPath: videoURL.path(percentEncoded: false)
        )[.creationDate] as? Date) ?? Date()

        let omega = analysis.omegaDegPerSec
        // Degenerate-omega guard: zero, negative, NaN or near-zero angular
        // velocity would collapse every window (and divide by zero below).
        guard omega.isFinite, omega > Self.minOmegaDegPerSec else {
            Self.logger.error("Degenerate omega \(omega, privacy: .public) deg/s — cannot place angle windows")
            throw YawError.noRotationDetected
        }

        let generator = AVAssetImageGenerator(asset: asset)
        // Applies the track's orientation so portrait video comes out upright.
        generator.appliesPreferredTrackTransform = true

        let step = 360.0 / Double(views)
        // Half the angular window, expressed in seconds. Kept wide per
        // WWDC22 guidance — the generator decodes the nearest iFrame and
        // reports the actual frame time, which is what gets mapped to an
        // angle. Zero tolerance would force dependent-frame decoding for no
        // gain, since actualTime is mapped anyway.
        let halfWindowTime = (step / 2) / omega
        generator.requestedTimeToleranceBefore = CMTime(seconds: halfWindowTime, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: halfWindowTime, preferredTimescale: 600)

        var written = 0
        var skipped = 0
        // Hoisted across all windows: keyed by actual frame time (ms), so
        // adjacent windows can never claim the same physical frame twice.
        var seen = Set<Int>()
        for i in 0..<views {
            try Task.checkCancellation()
            let targetTheta = Double(i) * step
            let targetT = analysis.t0 + targetTheta / omega

            var times: [CMTime] = []
            times.reserveCapacity(Self.attemptsPerView)
            for attempt in 0..<Self.attemptsPerView {
                let requestT = targetT + (Double(attempt) - 2.0) * (halfWindowTime / 2.5)
                guard requestT >= analysis.t0, requestT <= analysis.t1 else { continue }
                times.append(CMTime(seconds: requestT, preferredTimescale: 6000))
            }

            // The winning frame's *measured* angle, computed from its
            // actualTime — the manifest records this, never the target angle.
            var best: (score: Float, image: CGImage, t: Double, theta: Double)?
            // images(for:) is an AsyncSequence: per-request success/failure
            // isolation is built in, and it terminates on task cancellation,
            // so no continuation can dangle.
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                switch result {
                case .success(_, let image, let actualTime):
                    let at = CMTimeGetSeconds(actualTime)
                    guard at.isFinite else { continue }
                    guard seen.insert(Int((at * 1000).rounded())).inserted else { continue }
                    var theta = (omega * (at - analysis.t0)).truncatingRemainder(dividingBy: 360)
                    if theta < 0 { theta += 360 }
                    guard Self.angularDistance(theta, targetTheta) <= step / 2 else { continue }
                    let score = Self.sharpness(of: image)
                    if best == nil || score > best!.score {
                        best = (score, image, at, theta)
                    }
                case .failure(_, let error):
                    // One bad frame is a skipped candidate, not a failed run.
                    Self.logger.warning("Frame request failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            if let best {
                let url = imagesURL.appending(
                    path: String(format: "shot_%06d.jpg", firstShotIndex + i),
                    directoryHint: .notDirectory
                )
                do {
                    try Self.writeJPEG(best.image, to: url)
                    manifest.append(
                        shot: firstShotIndex + i,
                        file: url.lastPathComponent,
                        takenAt: baseDate.addingTimeInterval(best.t),
                        thetaDeg: best.theta,
                        method: Self.manifestMethod(for: analysis.method),
                        sharpness: best.score
                    )
                    written += 1
                } catch {
                    // One bad encode skips this view, not the whole run.
                    skipped += 1
                    Self.logger.error("JPEG encode failed for view \(i + 1, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } else {
                skipped += 1
                Self.logger.warning("View \(i + 1, privacy: .public)/\(views, privacy: .public): no in-window candidate frames")
            }
            onProgress(Double(i + 1) / Double(views))
        }
        return FrameExtraction(count: written, skippedViews: skipped)
    }

    // MARK: - Orbit mode: time-spread extraction (no yaw)

    /// Pulls one sharp frame per time window from a phone-orbit video.
    ///
    /// There is no turntable here, so no rotation to measure and no yaw to
    /// assign — the photogrammetry solver computes camera poses from the
    /// images themselves. Frames just need to be sharp and spread across the
    /// take: each of `views` evenly spaced time windows contributes its
    /// sharpest frame. Manifest entries carry no angle (`method: "vision"`).
    ///
    /// `onCoverageWarning` fires once when one or more windows yielded no
    /// frame (defaulted so existing call sites are unaffected).
    func extractTimeSpread(
        videoURL: URL,
        views: Int,
        imagesURL: URL,
        manifest: YawManifest,
        /// 1-based first index in the shared `shot_` sequence. Orbit passes 1.
        firstShotIndex: Int,
        onCoverageWarning: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        guard views > 0 else { return 0 }

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        guard total > 4 else { throw YawError.orbitVideoTooShort }
        let baseDate = (try? FileManager.default.attributesOfItem(
            atPath: videoURL.path(percentEncoded: false)
        )[.creationDate] as? Date) ?? Date()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Wide, symmetric tolerances per WWDC22 guidance (nearest-iFrame
        // default). The actual frame time is what gets recorded, so forcing
        // frame accuracy would only cost decoding work.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        // Trim a second off each end — the user is usually still settling the
        // framing there.
        let start = 1.0
        let end = total - 1.0
        let window = (end - start) / Double(views)

        var written = 0
        // Global dedup: adjacent windows can't both claim the same frame.
        var seen = Set<Int>()
        for i in 0..<views {
            try Task.checkCancellation()
            let windowStart = start + Double(i) * window

            var times: [CMTime] = []
            times.reserveCapacity(3)
            for attempt in 0..<3 {
                let requestT = windowStart + (Double(attempt) + 0.5) * (window / 3)
                times.append(CMTime(seconds: requestT, preferredTimescale: 6000))
            }

            var best: (score: Float, image: CGImage, t: Double)?
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                switch result {
                case .success(_, let image, let actualTime):
                    let at = CMTimeGetSeconds(actualTime)
                    guard at.isFinite else { continue }
                    guard seen.insert(Int((at * 1000).rounded())).inserted else { continue }
                    let score = Self.sharpness(of: image)
                    if best == nil || score > best!.score {
                        best = (score, image, at)
                    }
                case .failure(_, let error):
                    Self.logger.warning("Frame request failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            if let best {
                let url = imagesURL.appending(
                    path: String(format: "shot_%06d.jpg", firstShotIndex + i),
                    directoryHint: .notDirectory
                )
                do {
                    try Self.writeJPEG(best.image, to: url)
                    manifest.append(
                        shot: firstShotIndex + i,
                        file: url.lastPathComponent,
                        takenAt: baseDate.addingTimeInterval(best.t),
                        thetaDeg: nil,
                        method: Self.manifestMethod(for: "solver"),
                        sharpness: best.score
                    )
                    written += 1
                } catch {
                    Self.logger.error("JPEG encode failed for window \(i + 1, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Self.logger.warning("Window \(i + 1, privacy: .public)/\(views, privacy: .public): no candidate frames")
            }
            onProgress(Double(i + 1) / Double(views))
        }
        let skipped = views - written
        if skipped > 0 {
            onCoverageWarning("\(written) of \(views) windows yielded frames")
        }
        return written
    }

    // MARK: - Frame scoring and writing

    /// Gradient-energy sharpness on a downscaled copy — a relative ranking is
    /// all the window needs, and the full-res image is kept for the winner.
    ///
    /// Bitmap info must be `noneSkipFirst | byteOrder32Little` for true BGRA
    /// byte order; `noneSkipLast` silently yields X,B,G,R.
    private static func sharpness(of cgImage: CGImage) -> Float {
        let targetW = 960
        let targetH = max(1, cgImage.height * targetW / cgImage.width)
        var data = [UInt8](repeating: 0, count: targetW * targetH * 4)
        guard let ctx = CGContext(
            data: &data,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        var total = 0.0
        var n = 0
        for row in stride(from: 0, to: targetH, by: 2) {
            let base = row * targetW * 4
            for col in 0..<(targetW - 1) {
                let left = Int(data[base + col * 4 + 1])
                let right = Int(data[base + col * 4 + 5])
                let d = Double(right - left)
                total += d * d
                n += 1
            }
        }
        return n > 0 ? Float(total / Double(n)) : 0
    }

    private static func writeJPEG(_ cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw YawError.frameEncodingFailed
        }
        CGImageDestinationAddImage(
            dest,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else {
            throw YawError.frameEncodingFailed
        }
    }

    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}
