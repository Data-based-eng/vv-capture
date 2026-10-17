import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Outcome of the video processing pipeline.
struct VideoProcessResult: Sendable {
    var frameCount: Int
    var method: String
    var warning: String?
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
        onProgress: @escaping @Sendable (VideoProcessingProgress) -> Void
    ) async throws -> VideoProcessResult {
        try await Task.detached {
            var progress = VideoProcessingProgress(stage: "Measuring rotation")
            let analysis = try await YawEstimator().analyze(
                videoURL: videoURL,
                nominalRevSeconds: nominalRevSeconds
            ) { fraction in
                progress.fraction = fraction * 0.3
                onProgress(progress)
            }
            try Task.checkCancellation()
            let count = try await FrameExtractor().extract(
                videoURL: videoURL,
                analysis: analysis,
                views: views,
                imagesURL: imagesURL,
                manifest: manifest
            ) { fraction in
                progress.fraction = 0.3 + fraction * 0.7
                progress.stage = "Extracting frames"
                onProgress(progress)
            }
            return VideoProcessResult(
                frameCount: count,
                method: analysis.method,
                warning: analysis.warning
            )
        }.value
    }
}

/// Pulls one sharp frame per target angle from a turntable video.
///
/// For each of `views` evenly spaced angles, several candidate frames are
/// grabbed around the target time; each candidate's *true* angle is computed
/// from the measured rotation and only in-window candidates are scored. The
/// sharpest in-window frame is written as `frame_%04d.jpg` straight into the
/// workspace's images directory, with its angle recorded in the yaw manifest —
/// so the reconstructor treats video frames exactly like stills.
struct FrameExtractor: Sendable {
    /// Candidates grabbed per target angle.
    private static let attemptsPerView = 5

    func extract(
        videoURL: URL,
        analysis: VideoYawAnalysis,
        views: Int,
        imagesURL: URL,
        manifest: YawManifest,
        onProgress: (Double) -> Void
    ) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        let baseDate = (try? FileManager.default.attributesOfItem(
            atPath: videoURL.path(percentEncoded: false)
        )[.creationDate] as? Date) ?? Date()

        let generator = AVAssetImageGenerator(asset: asset)
        // Applies the track's orientation so portrait video comes out upright.
        generator.appliesPreferredTrackTransform = true

        let step = 360.0 / Double(views)
        let omega = analysis.omegaDegPerSec
        // Half the angular window, expressed in seconds.
        let halfWindowTime = (step / 2) / omega
        generator.requestedTimeToleranceBefore = CMTime(seconds: halfWindowTime, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: halfWindowTime, preferredTimescale: 600)

        var written = 0
        for i in 0..<views {
            try Task.checkCancellation()
            let targetTheta = Double(i) * step
            let targetT = analysis.t0 + targetTheta / omega

            var best: (score: Float, image: CGImage, t: Double)?
            var seen = Set<Int>()
            for attempt in 0..<Self.attemptsPerView {
                let requestT = targetT + (Double(attempt) - 2.0) * (halfWindowTime / 2.5)
                guard requestT >= analysis.t0, requestT <= analysis.t1 else { continue }
                guard let (cg, actual) = try? await generatedCGImage(
                    at: CMTime(seconds: requestT, preferredTimescale: 6000),
                    using: generator
                ) else { continue }
                let at = CMTimeGetSeconds(actual)
                guard seen.insert(Int((at * 1000).rounded())).inserted else { continue }

                var theta = (omega * (at - analysis.t0)).truncatingRemainder(dividingBy: 360)
                if theta < 0 { theta += 360 }
                guard Self.angularDistance(theta, targetTheta) <= step / 2 else { continue }

                let score = Self.sharpness(of: cg)
                if best == nil || score > best!.score {
                    best = (score, cg, at)
                }
            }

            if let best {
                let url = imagesURL.appending(
                    path: String(format: "frame_%04d.jpg", i + 1),
                    directoryHint: .notDirectory
                )
                try Self.writeJPEG(best.image, to: url)
                manifest.append(
                    shot: i + 1,
                    file: url.lastPathComponent,
                    takenAt: baseDate.addingTimeInterval(best.t),
                    thetaDeg: targetTheta,
                    method: analysis.method,
                    sharpness: best.score
                )
                written += 1
            }
            onProgress(Double(i + 1) / Double(views))
        }
        return written
    }

    // MARK: - Orbit mode: time-spread extraction (no yaw)

    /// Pulls one sharp frame per time window from a phone-orbit video.
    ///
    /// There is no turntable here, so no rotation to measure and no yaw to
    /// assign — the photogrammetry solver computes camera poses from the
    /// images themselves. Frames just need to be sharp and spread across the
    /// take: each of `views` evenly spaced time windows contributes its
    /// sharpest frame. Manifest entries carry no angle (`method: "solver"`).
    func extractTimeSpread(
        videoURL: URL,
        views: Int,
        imagesURL: URL,
        manifest: YawManifest,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        guard total > 4 else { throw YawError.orbitVideoTooShort }
        let baseDate = (try? FileManager.default.attributesOfItem(
            atPath: videoURL.path(percentEncoded: false)
        )[.creationDate] as? Date) ?? Date()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        // Trim a second off each end — the user is usually still settling the
        // framing there.
        let start = 1.0
        let end = total - 1.0
        let window = (end - start) / Double(views)

        var written = 0
        for i in 0..<views {
            try Task.checkCancellation()
            let windowStart = start + Double(i) * window

            var best: (score: Float, image: CGImage, t: Double)?
            var seen = Set<Int>()
            for attempt in 0..<3 {
                let requestT = windowStart + (Double(attempt) + 0.5) * (window / 3)
                guard let (cg, actual) = try? await generatedCGImage(
                    at: CMTime(seconds: requestT, preferredTimescale: 6000),
                    using: generator
                ) else { continue }
                let at = CMTimeGetSeconds(actual)
                guard seen.insert(Int((at * 1000).rounded())).inserted else { continue }
                let score = Self.sharpness(of: cg)
                if best == nil || score > best!.score {
                    best = (score, cg, at)
                }
            }

            if let best {
                let url = imagesURL.appending(
                    path: String(format: "frame_%04d.jpg", i + 1),
                    directoryHint: .notDirectory
                )
                try Self.writeJPEG(best.image, to: url)
                manifest.append(
                    shot: i + 1,
                    file: url.lastPathComponent,
                    takenAt: baseDate.addingTimeInterval(best.t),
                    thetaDeg: nil,
                    method: "solver",
                    sharpness: best.score
                )
                written += 1
            }
            onProgress(Double(i + 1) / Double(views))
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
