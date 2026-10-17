import AVFoundation
import CoreGraphics
import Foundation
import os

/// What the video analysis measured about the turntable's rotation.
struct VideoYawAnalysis: Sendable {
    /// Seconds into the video where rotation starts.
    var t0: Double
    /// Seconds where rotation ends.
    var t1: Double
    /// Angular velocity in degrees per second — measured from the marker when
    /// possible, otherwise the nominal speed the turntable was set to.
    var omegaDegPerSec: Double
    /// "video-marker" (measured) or "video-rpm" (nominal fallback).
    var method: String
    /// Sine-fit quality 0…1; 0 when the nominal speed was used.
    var confidence: Double
    /// Human-readable caveat for the capture log, if any.
    var warning: String?
}

enum YawError: LocalizedError {
    case noVideoTrack
    case videoTooShort
    case noRotationDetected
    case frameEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The recorded file has no video track."
        case .videoTooShort:
            "The video is too short to measure rotation."
        case .noRotationDetected:
            "No turntable rotation was detected in the video. Make sure the table is turning while recording, with a few seconds of still footage before and after."
        case .frameEncodingFailed:
            "A video frame could not be saved."
        }
    }
}

/// Grabs one frame from the generator, awaiting its completion handler.
func generatedCGImage(
    at time: CMTime,
    using generator: AVAssetImageGenerator
) async throws -> (CGImage, CMTime) {
    try await withCheckedThrowingContinuation { continuation in
        generator.generateCGImageAsynchronously(for: time) { image, actualTime, error in
            if let image {
                continuation.resume(returning: (image, actualTime))
            } else {
                continuation.resume(throwing: error ?? YawError.frameEncodingFailed)
            }
        }
    }
}

/// Recovers per-frame yaw from a turntable video.
///
/// The phone never moves, so the turntable's spin is the only motion in the
/// frame. Rotation onset/offset come from frame-to-frame luma differences;
/// angular velocity comes from tracking a red/pink marker stuck on the plate
/// rim — its horizontal position follows a sine wave whose period is one
/// revolution. When the marker can't be measured, the nominal speed the
/// turntable was set to is used instead, clearly labelled "video-rpm".
struct YawEstimator: Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "yaw")

    /// - Parameter nominalRevSeconds: seconds per revolution the turntable was
    ///   set to in its app. Only used when the marker can't be measured.
    /// - Parameter onProgress: 0…1 over the analysis pass.
    func analyze(
        videoURL: URL,
        nominalRevSeconds: Double,
        onProgress: (Double) -> Void
    ) async throws -> VideoYawAnalysis {
        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration >= 10 else { throw YawError.videoTooShort }

        // Sample ~4 fps, downscaled. The generator reports the actual frame
        // time for each grab, so the series stays truthful even when the
        // decoder hands back a nearby frame.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        var times: [Double] = []
        var diffs: [Double] = []
        var markerX: [(t: Double, x: Double)] = []
        var prevBytes: [UInt8] = []
        var markerHits = 0
        var samples = 0

        var t = 0.0
        let step = 0.25
        while t < duration {
            try Task.checkCancellation()
            guard let (cg, actual) = try? await generatedCGImage(
                at: CMTime(seconds: t, preferredTimescale: 600),
                using: generator
            ), let pixels = Self.pixels(of: cg) else {
                t += step
                continue
            }
            let at = CMTimeGetSeconds(actual)
            if let last = times.last, at <= last + 0.01 {
                t += step
                continue // Decoder returned a frame we already have.
            }
            samples += 1

            // Mean absolute difference across all three channels — motion in
            // any color registers. (Green-only differencing nearly missed a
            // pure-red marker.)
            let bytes = pixels.bytes
            if prevBytes.count == bytes.count, !prevBytes.isEmpty {
                var sum = 0.0
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    sum += Double(abs(Int(bytes[i]) - Int(prevBytes[i])))
                    sum += Double(abs(Int(bytes[i + 1]) - Int(prevBytes[i + 1])))
                    sum += Double(abs(Int(bytes[i + 2]) - Int(prevBytes[i + 2])))
                }
                diffs.append(sum / Double(3 * (bytes.count / 4)))
                times.append(at)
            } else if !prevBytes.isEmpty {
                // Size changed mid-stream; restart the difference baseline.
                diffs.append(0)
                times.append(at)
            }
            prevBytes = bytes

            if let centroid = Self.markerCentroid(pixels: pixels) {
                markerX.append((at, centroid.x))
                markerHits += 1
            }

            if samples % 16 == 0 {
                onProgress(min(0.95, t / duration))
            }
            t += step
        }
        onProgress(1.0)

        // Motion onset/offset: the only thing moving is the turntable, so a
        // sustained rise above the video's own noise floor means rotation.
        // The floor is measured from the ends of the video, where the protocol
        // calls for still footage. If neither end is still, the floor lands at
        // motion level, nothing exceeds it, and the error below correctly asks
        // for still lead-in/tail.
        guard times.count >= 20 else { throw YawError.noRotationDetected }
        func median(_ xs: [Double]) -> Double {
            guard !xs.isEmpty else { return .infinity }
            let s = xs.sorted()
            return s[s.count / 2]
        }
        let headNoise = median(zip(times, diffs).filter { $0.0 < 2.5 }.map(\.1))
        let tailNoise = median(zip(times, diffs).filter { $0.0 > duration - 2.5 }.map(\.1))
        let noiseFloor = min(headNoise, tailNoise)
        guard noiseFloor.isFinite else { throw YawError.noRotationDetected }
        let threshold = max(noiseFloor * 4, 0.05)
        let t0: Double
        let t1: Double
        do {
            guard let strictOnset = Self.firstSustainedIndex(diffs, above: threshold, run: 5),
                  let strictOffset = Self.lastSustainedIndex(diffs, above: threshold, run: 5),
                  strictOffset > strictOnset
            else {
                throw YawError.noRotationDetected
            }
            // The strict run starts late (it needs 5 consecutive hits). Walk
            // back/forward over the lenient threshold to find the true edges —
            // a constant t0 offset would otherwise rotate every recorded yaw.
            var onsetIdx = strictOnset
            while onsetIdx > 0, diffs[onsetIdx - 1] > noiseFloor * 1.5 { onsetIdx -= 1 }
            var offsetIdx = strictOffset
            while offsetIdx < diffs.count - 1, diffs[offsetIdx + 1] > noiseFloor * 1.5 { offsetIdx += 1 }
            t0 = times[onsetIdx]
            t1 = times[offsetIdx]
        }
        guard t1 - t0 > 8 else { throw YawError.noRotationDetected }

        // Marker → angular velocity via sine fit on its horizontal position.
        let nominalOmega = 360 / max(nominalRevSeconds, 1)
        var omega = nominalOmega
        var method = "video-rpm"
        var confidence = 0.0
        var warning: String? = "The rim marker wasn't found, so angles use the rotation speed setting. For measured angles, stick a 2 cm square of bright red or pink tape on the turntable's rim."

        let coverage = Double(markerHits) / Double(max(samples, 1))
        // Fit only on the motion window: the marker sits still in the lead-in
        // and tail, and those flat segments would bias the period.
        let motionMarkers = markerX.filter { $0.t >= t0 - 0.5 && $0.t <= t1 + 0.5 }
        if motionMarkers.count >= 30, coverage >= 0.4 {
            let xs = motionMarkers.map(\.x)
            let ts = motionMarkers.map(\.t)
            if let (period, r2) = Self.bestPeriod(times: ts, values: xs),
               r2 >= 0.9, period > 5 {
                omega = 360 / period
                method = "video-marker"
                confidence = r2
                warning = nil
                Self.logger.info("Measured rotation: \(period, privacy: .public)s/rev, R²=\(r2, privacy: .public)")
            } else {
                Self.logger.info("Marker fit too weak (R² below 0.9); falling back to nominal speed.")
            }
        } else {
            Self.logger.info("Marker seen in only \(markerHits, privacy: .public)/\(samples, privacy: .public) samples; falling back to nominal speed.")
        }

        let coverageDeg = omega * (t1 - t0)
        if coverageDeg < 324 {
            let note = "The video covers only \(Int(coverageDeg))° of rotation — record at least one full turn."
            warning = [warning, note].compactMap { $0 }.joined(separator: " ")
        }

        return VideoYawAnalysis(
            t0: t0,
            t1: t1,
            omegaDegPerSec: omega,
            method: method,
            confidence: confidence,
            warning: warning
        )
    }

    // MARK: - Pixel helpers

    private struct SmallPixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]  // BGRA
    }

    /// Draws the image into a caller-owned BGRA buffer so channel order is known.
    ///
    /// The bitmap info matters: `noneSkipFirst | byteOrder32Little` lays bytes
    /// out as B,G,R,X in memory. (`noneSkipLast` would give X,B,G,R — a real
    /// bug that once made every red pixel test read the green channel.)
    private static func pixels(of cg: CGImage) -> SmallPixels? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return SmallPixels(width: w, height: h, bytes: data)
    }

    /// Centroid of the largest red/pink blob — the rim marker. Returns nil
    /// when no plausible blob is present.
    private static func markerCentroid(pixels: SmallPixels) -> CGPoint? {
        var sumX = 0.0, sumY = 0.0, count = 0
        let bytes = pixels.bytes
        let n = pixels.width * pixels.height
        for i in 0..<n {
            let b = Int(bytes[i * 4])
            let g = Int(bytes[i * 4 + 1])
            let r = Int(bytes[i * 4 + 2])
            if r > 140, g < 110, r - max(g, b) > 50 {
                sumX += Double(i % pixels.width)
                sumY += Double(i / pixels.width)
                count += 1
            }
        }
        guard count >= 10, count <= 30_000 else { return nil }
        return CGPoint(x: sumX / Double(count), y: sumY / Double(count))
    }

    // MARK: - Motion onset/offset

    private static func firstSustainedIndex(_ diffs: [Double], above threshold: Double, run: Int) -> Int? {
        guard diffs.count > run else { return nil }
        for i in 0...(diffs.count - run) {
            if diffs[i..<(i + run)].allSatisfy({ $0 > threshold }) { return i }
        }
        return nil
    }

    private static func lastSustainedIndex(_ diffs: [Double], above threshold: Double, run: Int) -> Int? {
        guard diffs.count > run else { return nil }
        for i in stride(from: diffs.count - run, through: 0, by: -1) {
            if diffs[i..<(i + run)].allSatisfy({ $0 > threshold }) { return i + run - 1 }
        }
        return nil
    }

    // MARK: - Sine-fit angular velocity

    /// Finds the revolution period by fitting x(t) = A·sin(2πt/T) + B·cos(2πt/T) + C
    /// over candidate periods, then refining the best with golden-section
    /// search (the grid alone is ~12% spaced, which can leave several percent
    /// of period error). Returns the best (period, R²).
    private static func bestPeriod(times: [Double], values: [Double]) -> (Double, Double)? {
        var best: (Double, Double)?
        for k in 0..<40 {
            let period = 12 * pow(900.0 / 12.0, Double(k) / 39.0)
            let (a, b, _, r2) = fitSine(times: times, values: values, period: period)
            // A real marker swings several pixels; a near-zero amplitude is noise.
            guard hypot(a, b) > 2 else { continue }
            if r2 > (best?.1 ?? 0) {
                best = (period, r2)
            }
        }
        guard let (p0, _) = best else { return nil }
        var lo = p0 / 1.15, hi = p0 * 1.15
        let gr = (sqrt(5) - 1) / 2
        var c = hi - gr * (hi - lo), d = lo + gr * (hi - lo)
        var rc = fitSine(times: times, values: values, period: c).3
        var rd = fitSine(times: times, values: values, period: d).3
        for _ in 0..<24 {
            if rc > rd {
                hi = d; d = c; rd = rc
                c = hi - gr * (hi - lo)
                rc = fitSine(times: times, values: values, period: c).3
            } else {
                lo = c; c = d; rc = rd
                d = lo + gr * (hi - lo)
                rd = fitSine(times: times, values: values, period: d).3
            }
        }
        let period = (lo + hi) / 2
        let r2 = fitSine(times: times, values: values, period: period).3
        return (period, r2)
    }

    private static func fitSine(times: [Double], values: [Double], period: Double) -> (Double, Double, Double, Double) {
        let w = 2 * Double.pi / period
        var sSS = 0.0, sCC = 0.0, sSC = 0.0, sS = 0.0, sC = 0.0
        var sSX = 0.0, sCX = 0.0, sX = 0.0
        let n = Double(times.count)
        var mean = 0.0
        for i in 0..<times.count {
            let s = sin(w * times[i]), c = cos(w * times[i]), x = values[i]
            sSS += s * s; sCC += c * c; sSC += s * c; sS += s; sC += c
            sSX += s * x; sCX += c * x; sX += x
            mean += x
        }
        mean /= n

        // Solve the 3×3 normal equations by Gaussian elimination.
        var m = [
            [sSS, sSC, sS, sSX],
            [sSC, sCC, sC, sCX],
            [sS, sC, n, sX]
        ]
        for col in 0..<3 {
            var piv = col
            for row in (col + 1)..<3 where abs(m[row][col]) > abs(m[piv][col]) {
                piv = row
            }
            m.swapAt(col, piv)
            let div = m[col][col]
            guard abs(div) > 1e-12 else { return (0, 0, 0, 0) }
            for row in 0..<3 where row != col {
                let factor = m[row][col] / div
                for k in col..<4 { m[row][k] -= factor * m[col][k] }
            }
        }
        let a = m[0][3] / m[0][0], b = m[1][3] / m[1][1], c = m[2][3] / m[2][2]

        var ssRes = 0.0, ssTot = 0.0
        for i in 0..<times.count {
            let pred = a * sin(w * times[i]) + b * cos(w * times[i]) + c
            ssRes += (values[i] - pred) * (values[i] - pred)
            ssTot += (values[i] - mean) * (values[i] - mean)
        }
        let r2 = ssTot > 1e-9 ? max(0, 1 - ssRes / ssTot) : 0
        return (a, b, c, r2)
    }
}
